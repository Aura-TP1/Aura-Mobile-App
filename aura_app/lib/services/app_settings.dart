import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Configuración global de la app (voz, volumen, tamaño de letra),
/// persistida con `shared_preferences` y compartida por toda la app.
///
/// Es un singleton + [ChangeNotifier]: las pantallas que ya tienen un
/// [AudioFeedback] vivo se actualizan al instante (vía listener), y
/// `AuraApp` reconstruye el árbol cuando cambia el tamaño de letra.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const _kVoiceSpeedKey = 'voice_speed';
  static const _kVolumeKey = 'volume';
  static const _kFontScaleKey = 'font_scale';

  /// Velocidad de habla base usada antes de aplicar [voiceSpeed].
  static const double _baseRate = 0.45;

  /// Multiplicador 0.5x–2.0x elegido por el usuario en Ajustes.
  double voiceSpeed = 1.0;

  /// Volumen 0.0–1.0.
  double volume = 0.8;

  /// Escala de texto global (1.0 = normal).
  double fontScale = 1.0;

  bool _loaded = false;

  /// Carga los valores guardados. Debe llamarse una vez al inicio (en
  /// `main()`), antes de `runApp`. Es seguro llamarla varias veces.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final prefs = await SharedPreferences.getInstance();
    voiceSpeed = prefs.getDouble(_kVoiceSpeedKey) ?? voiceSpeed;
    volume = prefs.getDouble(_kVolumeKey) ?? volume;
    fontScale = prefs.getDouble(_kFontScaleKey) ?? fontScale;
  }

  /// Velocidad efectiva para `flutter_tts`, derivada de [voiceSpeed].
  double get ttsRate => (_baseRate * voiceSpeed).clamp(0.2, 1.0);

  Future<void> setVoiceSpeed(double value) async {
    voiceSpeed = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kVoiceSpeedKey, value);
  }

  Future<void> setVolume(double value) async {
    volume = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kVolumeKey, value);
  }

  Future<void> setFontScale(double value) async {
    fontScale = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kFontScaleKey, value);
  }
}
