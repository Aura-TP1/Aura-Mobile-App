import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'stt_service.dart';
import 'tts.dart';
import 'vosk_stt_service.dart';

/// Orquesta el fallback de voz en 3 niveles:
///
///   1. Google/on-device STT ([SttService], ya existente) si hay internet.
///   2. Vosk offline ([VoskSttService]) si no hay internet, o si el nivel 1
///      falló igual habiendo internet (p. ej. bug de locale/engine del
///      equipo — no tiene sentido rendirse si Tier 2 puede resolverlo).
///   3. Si ambos fallan: [listen] devuelve `null` y quien llama debe mostrar
///      el campo de texto de respaldo (Tier 3 es UI, no vive acá).
///
/// El cambio entre niveles 1 y 2 es silencioso (sin avisos de error); solo
/// se anuncia por voz la preparación única del modelo Vosk la primera vez
/// que se usa.
class VoiceInputService {
  VoiceInputService(this._audio);

  final AudioFeedback _audio;
  final SttService google = SttService();
  final VoskSttService _vosk = VoskSttService();

  bool get isListening => google.isListening;
  bool get permanentlyDenied => google.permanentlyDenied;
  Future<void> openSettings() => google.openSettings();

  Future<void> stop() async {
    await google.stop();
    await _vosk.stop();
  }

  /// Intenta Tier 1 y, si no da resultado, Tier 2. Devuelve el texto
  /// reconocido (trim, no vacío) o `null` si ambos niveles fallaron —en
  /// cuyo caso quien llama debe activar el Tier 3 (campo de texto).
  Future<String?> listen() async {
    await google.init(); // idempotente: asegura que `permanentlyDenied` esté al día
    if (google.permanentlyDenied) {
      debugPrint('VoiceInput: permiso de micrófono denegado permanentemente.');
      return null;
    }

    final hasInternet = await _hasInternet();
    debugPrint('VoiceInput: ¿internet disponible?: $hasInternet');
    if (hasInternet) {
      final text = await _listenGoogle();
      debugPrint('VoiceInput: Tier 1 (Google) devolvió: ${text == null ? 'null' : '"$text"'}');
      if (text != null && text.isNotEmpty) return text;
    }

    debugPrint('VoiceInput: pasando a Tier 2 (Vosk)...');
    if (await _vosk.needsFirstTimeSetup()) {
      await _audio.speak('Preparando reconocimiento de voz sin conexión, un momento.');
    }
    final voskText = await _vosk.listen();
    debugPrint('VoiceInput: Tier 2 (Vosk) devolvió: ${voskText == null ? 'null' : '"$voskText"'}');
    return (voskText != null && voskText.isNotEmpty) ? voskText : null;
  }

  Future<String?> _listenGoogle() {
    final completer = Completer<String?>();
    google.startListening(onResult: (text) {
      if (!completer.isCompleted) completer.complete(text);
    });
    return completer.future;
  }

  Future<bool> _hasInternet() async {
    if (kIsWeb) return true;
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 3));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
