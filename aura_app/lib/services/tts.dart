import 'package:flutter_tts/flutter_tts.dart';

/// Envoltorio simple sobre flutter_tts con cola anti‑repetición.
class AudioFeedback {
  final FlutterTts _tts = FlutterTts();
  String _lastSpoken = '';
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Tiempo mínimo entre repeticiones de la misma etiqueta.
  static const Duration repeatCooldown = Duration(seconds: 3);

  Future<void> init() async {
    await _tts.setLanguage('es-PE');
    await _tts.setSpeechRate(0.45); // más lento para adultos mayores
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  /// Habla un texto arbitrario sin prefijo y sin cooldown.
  /// Útil para instrucciones y mensajes de estado.
  Future<void> speak(String text) async {
    await _tts.stop();
    await _tts.speak(text);
  }

  Future<void> announce(String label) async {
    final now = DateTime.now();
    if (label == _lastSpoken && now.difference(_lastSpokenAt) < repeatCooldown) {
      return;
    }
    _lastSpoken = label;
    _lastSpokenAt = now;
    await _tts.stop();
    await _tts.speak('Detectado: $label');
  }

  Future<void> stop() => _tts.stop();
}
