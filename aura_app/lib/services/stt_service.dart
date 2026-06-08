import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Wrapper reutilizable sobre `speech_to_text`.
///
/// Diseñado para ser usado desde cualquier pantalla que necesite capturar
/// texto por voz.
///
/// Decisiones clave para robustez (antes fallaba en ~1 s en dispositivos
/// reales):
///   - El locale NO se fija a 'es-PE': se elige el mejor disponible en el
///     dispositivo (es-PE → cualquier es-* → locale del sistema). Forzar un
///     locale no instalado hacía que el motor abortara al instante.
///   - `cancelOnError: false` + `partialResults: true`: errores transitorios
///     (p. ej. el usuario aún no habla) ya no cierran la sesión.
///   - Se distingue `permanentlyDenied` para poder mandar al usuario a Ajustes.
///
/// En Chrome delega a Web Speech API (el permiso lo pide el navegador).
/// En Android usa el `SpeechRecognizer` nativo y pide `RECORD_AUDIO`.
class SttService {
  final SpeechToText _speech = SpeechToText();
  bool _available = false;
  bool _isListening = false;
  bool _gotResult = false;
  bool _permanentlyDenied = false;
  String _lastPartial = '';
  String? _localeId;
  void Function(String?)? _pendingOnResult;

  bool get available => _available;
  bool get isListening => _isListening;

  /// `true` si el usuario denegó el micrófono de forma permanente. La UI
  /// debería ofrecer abrir Ajustes ([openSettings]).
  bool get permanentlyDenied => _permanentlyDenied;

  /// Inicializa el motor STT. Idempotente — si ya está listo, es no-op.
  /// Retorna `true` si el motor quedó disponible.
  Future<bool> init() async {
    if (_available) return true;
    // Android: pedimos RECORD_AUDIO con permission_handler.
    // iOS: NO usamos permission_handler aquí. speech_to_text pide micrófono +
    // reconocimiento de voz por sí mismo (usando las descripciones del
    // Info.plist) al llamar initialize(). Así el diálogo aparece aunque los
    // macros del Podfile no estén, y evitamos bloquear antes de mostrarlo.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      var status = await Permission.microphone.status;
      if (!status.isGranted) {
        status = await Permission.microphone.request();
      }
      if (status.isPermanentlyDenied || status.isRestricted) {
        _permanentlyDenied = true;
        return false;
      }
      if (!status.isGranted) return false;
      _permanentlyDenied = false;
    }
    _available = await _speech.initialize(
      onStatus: _onStatus,
      onError: _onError,
      debugLogging: kDebugMode,
    );
    if (_available) {
      _permanentlyDenied = false;
      _localeId = await _pickLocale();
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      // En iOS, si initialize falla suele ser por permiso denegado: en iOS la
      // negación es permanente (hay que ir a Ajustes).
      _permanentlyDenied = !(await _speech.hasPermission);
    }
    return _available;
  }

  /// Abre los Ajustes del sistema para habilitar el micrófono manualmente.
  Future<void> openSettings() => openAppSettings();

  /// Elige el mejor locale de español disponible en el dispositivo, con
  /// fallback al locale del sistema y, en último caso, `null` (motor default).
  Future<String?> _pickLocale() async {
    try {
      final locales = await _speech.locales();
      String norm(String id) => id.replaceAll('_', '-').toLowerCase();
      LocaleName? exact;
      LocaleName? anyEs;
      for (final l in locales) {
        final id = norm(l.localeId);
        if (id == 'es-pe') exact = l;
        if (anyEs == null && id.startsWith('es')) anyEs = l;
      }
      if (exact != null) return exact.localeId;
      if (anyEs != null) return anyEs.localeId;
      final sys = await _speech.systemLocale();
      return sys?.localeId; // null → el motor usa su propio default
    } catch (_) {
      return null;
    }
  }

  /// Arranca una sesión de escucha.
  ///
  /// - [onResult] se invoca exactamente UNA vez por sesión, con el texto
  ///   reconocido (trim) o `null` si hubo timeout, error permanente o silencio.
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
    _lastPartial = '';
    _isListening = true;
    await _speech.listen(
      onResult: _onSpeechResult,
      localeId: _localeId,
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 4),
      listenOptions: SpeechListenOptions(
        partialResults: true,
        cancelOnError: false,
        listenMode: ListenMode.dictation,
      ),
    );
  }

  Future<void> stop() async {
    if (!_isListening) return;
    await _speech.stop();
    _isListening = false;
  }

  // ── Callbacks internos ──────────────────────────────────────────────────

  void _onSpeechResult(SpeechRecognitionResult result) {
    final text = result.recognizedWords.trim();
    if (text.isNotEmpty) _lastPartial = text;
    if (!result.finalResult) return; // seguimos acumulando parciales
    _gotResult = true;
    _isListening = false;
    _deliver(text.isEmpty ? null : text);
  }

  void _onStatus(String status) {
    // 'notListening' / 'done' = fin de sesión. Si no llegó un resultado final
    // pero sí algún parcial, lo entregamos en vez de descartarlo.
    if (status == 'notListening' || status == 'done') {
      if (_isListening && !_gotResult) {
        _isListening = false;
        _deliver(_lastPartial.isEmpty ? null : _lastPartial);
      }
    }
  }

  void _onError(SpeechRecognitionError error) {
    debugPrint('STT error: ${error.errorMsg} (permanent: ${error.permanent})');
    // Errores transitorios (el usuario todavía no habla) no cierran la sesión.
    if (!error.permanent) return;
    if (_isListening && !_gotResult) {
      _isListening = false;
      _deliver(_lastPartial.isEmpty ? null : _lastPartial);
    }
  }

  void _deliver(String? text) {
    final cb = _pendingOnResult;
    _pendingOnResult = null;
    cb?.call(text);
  }
}
