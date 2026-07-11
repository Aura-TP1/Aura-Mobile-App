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
  static const _kSyncEnabledKey = 'sync_enabled';
  static const _kScanIntervalMsKey = 'scan_interval_ms';
  static const _kOcrDebounceMsKey = 'ocr_debounce_ms';
  static const _kOcrCooldownMsKey = 'ocr_cooldown_ms';
  static const _kTtsRepeatCooldownMsKey = 'tts_repeat_cooldown_ms';
  static const _kSttListenForMsKey = 'stt_listen_for_ms';
  static const _kSttPauseForMsKey = 'stt_pause_for_ms';
  static const _kTestConditionKey = 'test_condition';
  static const _kTestRunLabelKey = 'test_run_label';

  /// Velocidad de habla base usada antes de aplicar [voiceSpeed].
  static const double _baseRate = 0.45;

  /// Multiplicador 0.5x–2.0x elegido por el usuario en Ajustes.
  double voiceSpeed = 1.0;

  /// Volumen 0.0–1.0.
  double volume = 0.8;

  /// Escala de texto global (1.0 = normal).
  double fontScale = 1.0;

  /// Sincronización en la nube habilitada.
  bool syncEnabled = false;

  /// Intervalo entre cuadros analizados en la búsqueda por cámara (ms).
  /// WCAG 2.2.1: tiempo ajustable en lugar de fijo (300ms por defecto).
  double scanIntervalMs = 300;

  /// Retraso de debounce antes de leer texto con OCR (ms).
  double ocrDebounceMs = 800;

  /// Tiempo mínimo entre lecturas repetidas de OCR (ms).
  double ocrCooldownMs = 4000;

  /// Tiempo mínimo entre repeticiones habladas del mismo mensaje TTS (ms).
  double ttsRepeatCooldownMs = 3000;

  /// Tiempo máximo que el reconocimiento de voz espera una frase (ms).
  double sttListenForMs = 30000;

  /// Silencio máximo tolerado antes de cerrar la sesión de voz (ms).
  double sttPauseForMs = 4000;

  /// Etiqueta de condición de prueba manual (para métricas), ej.
  /// "same_background", "different_background", "similar_item_test".
  /// Se guarda en cada intento de búsqueda (`search_metrics.jsonl`) para
  /// poder filtrar los resultados después.
  String testCondition = 'default';

  /// Identificador de sesión/lote de pruebas elegido por el usuario antes
  /// de empezar un conjunto de búsquedas (para métricas).
  String testRunLabel = '';

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
    syncEnabled = prefs.getBool(_kSyncEnabledKey) ?? syncEnabled;
    scanIntervalMs = prefs.getDouble(_kScanIntervalMsKey) ?? scanIntervalMs;
    ocrDebounceMs = prefs.getDouble(_kOcrDebounceMsKey) ?? ocrDebounceMs;
    ocrCooldownMs = prefs.getDouble(_kOcrCooldownMsKey) ?? ocrCooldownMs;
    ttsRepeatCooldownMs =
        prefs.getDouble(_kTtsRepeatCooldownMsKey) ?? ttsRepeatCooldownMs;
    sttListenForMs = prefs.getDouble(_kSttListenForMsKey) ?? sttListenForMs;
    sttPauseForMs = prefs.getDouble(_kSttPauseForMsKey) ?? sttPauseForMs;
    testCondition = prefs.getString(_kTestConditionKey) ?? testCondition;
    testRunLabel = prefs.getString(_kTestRunLabelKey) ?? testRunLabel;
  }

  /// Duración efectiva de escucha STT, con piso de seguridad.
  Duration get sttListenFor =>
      Duration(milliseconds: sttListenForMs.clamp(5000, 60000).round());

  /// Duración efectiva de pausa STT, con piso de seguridad.
  Duration get sttPauseFor =>
      Duration(milliseconds: sttPauseForMs.clamp(1000, 15000).round());

  /// Duración efectiva del intervalo de escaneo, con piso de seguridad.
  Duration get scanInterval =>
      Duration(milliseconds: scanIntervalMs.clamp(150, 2000).round());

  /// Duración efectiva del debounce de OCR, con piso de seguridad.
  Duration get ocrDebounce =>
      Duration(milliseconds: ocrDebounceMs.clamp(200, 3000).round());

  /// Duración efectiva del cooldown de lectura OCR, con piso de seguridad.
  Duration get ocrCooldown =>
      Duration(milliseconds: ocrCooldownMs.clamp(1000, 10000).round());

  /// Duración efectiva del cooldown de repetición TTS, con piso de seguridad.
  Duration get ttsRepeatCooldown =>
      Duration(milliseconds: ttsRepeatCooldownMs.clamp(500, 10000).round());

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

  Future<void> setSyncEnabled(bool value) async {
    syncEnabled = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kSyncEnabledKey, value);
  }

  Future<void> setScanIntervalMs(double value) async {
    scanIntervalMs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kScanIntervalMsKey, value);
  }

  Future<void> setOcrDebounceMs(double value) async {
    ocrDebounceMs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kOcrDebounceMsKey, value);
  }

  Future<void> setOcrCooldownMs(double value) async {
    ocrCooldownMs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kOcrCooldownMsKey, value);
  }

  Future<void> setTtsRepeatCooldownMs(double value) async {
    ttsRepeatCooldownMs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTtsRepeatCooldownMsKey, value);
  }

  Future<void> setSttListenForMs(double value) async {
    sttListenForMs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kSttListenForMsKey, value);
  }

  Future<void> setSttPauseForMs(double value) async {
    sttPauseForMs = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kSttPauseForMsKey, value);
  }

  Future<void> setTestCondition(String value) async {
    testCondition = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTestConditionKey, value);
  }

  Future<void> setTestRunLabel(String value) async {
    testRunLabel = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTestRunLabelKey, value);
  }
}
