import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wrapper reutilizable sobre `speech_to_text`.
///
/// Diseñado para ser usado desde cualquier pantalla nueva que necesite
/// capturar texto por voz (ej. save_object_screen). `search_screen`
/// mantiene su propia implementación inline y NO depende de este servicio
/// para evitar tocar código ya funcional.
///
/// Idioma: `es-PE`. Timeout: 5 s de escucha y 5 s de silencio.
///
/// En Chrome delega a Web Speech API (el permiso lo pide el navegador).
/// En Android usa el `SpeechRecognizer` nativo y pide `RECORD_AUDIO`.
class SttService {
  final SpeechToText _speech = SpeechToText();
  bool _available = false;
  bool _isListening = false;
  bool _gotResult = false;
  void Function(String?)? _pendingOnResult;

  bool get available => _available;
  bool get isListening => _isListening;

  /// Inicializa el motor STT. Idempotente — si ya está listo, es no-op.
  /// Retorna `true` si el motor quedó disponible.
  Future<bool> init() async {
    if (_available) return true;
    if (!kIsWeb) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) return false;
    }
    _available = await _speech.initialize(
      onStatus: _onStatus,
      onError: _onError,
    );
    return _available;
  }

  /// Arranca una sesión de escucha.
  ///
  /// - [onResult] se invoca exactamente UNA vez por sesión, con el texto
  ///   reconocido (trim) o `null` si hubo timeout, error o silencio.
  /// - La sesión se cancela automáticamente tras 5 s de silencio o 5 s
  ///   totales de escucha.
  Future<void> startListening({
    required void Function(String?) onResult,
  }) async {
    if (_isListening) return;
    if (!_available) {
      final ok = await init();
      if (!ok) {
        onResult(null);
        return;
      }
    }
    _pendingOnResult = onResult;
    _gotResult = false;
    _isListening = true;
    await _speech.listen(
      onResult: _onSpeechResult,
      localeId: 'es-PE',
      listenFor: const Duration(seconds: 5),
      pauseFor: const Duration(seconds: 5),
      partialResults: false,
      cancelOnError: true,
    );
  }

  Future<void> stop() async {
    if (!_isListening) return;
    await _speech.stop();
    _isListening = false;
  }

  // ── Callbacks internos ──────────────────────────────────────────────────

  void _onSpeechResult(SpeechRecognitionResult result) {
    if (!result.finalResult) return;
    final text = result.recognizedWords.trim();
    _gotResult = true;
    _isListening = false;
    _deliver(text.isEmpty ? null : text);
  }

  void _onStatus(String status) {
    // 'notListening' y 'done' significan fin de la sesión. Si no hubo
    // resultado final, entregamos null una sola vez.
    if (status == 'notListening' || status == 'done') {
      if (_isListening && !_gotResult) {
        _isListening = false;
        _deliver(null);
      }
    }
  }

  void _onError(SpeechRecognitionError error) {
    if (_isListening) {
      _isListening = false;
      _deliver(null);
    }
  }

  void _deliver(String? text) {
    final cb = _pendingOnResult;
    _pendingOnResult = null;
    cb?.call(text);
  }
}
