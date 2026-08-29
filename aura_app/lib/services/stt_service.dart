import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app_settings.dart';

/// Wrapper reutilizable sobre `speech_to_text`.
///
/// Diseñado para ser usado desde cualquier pantalla que necesite capturar
/// texto por voz.
///
/// Decisiones clave para robustez (antes fallaba en ~1 s en dispositivos
/// reales):
///   - El locale NO se fija a 'es-PE': se elige el mejor disponible en el
///     dispositivo (es-PE → cualquier es-* → null). Forzar un locale no
///     instalado hacía que el motor abortara al instante.
///   - `cancelOnError: false` + `partialResults: true`: errores transitorios
///     (p. ej. el usuario aún no habla) ya no cierran la sesión.
///   - Se distingue `permanentlyDenied` para poder mandar al usuario a Ajustes.
///   - `onDevice: true` en el listen: la app debe funcionar sin conexión, así
///     que preferimos el reconocedor offline de Android. Solo funciona si el
///     equipo ya tiene descargado el paquete de voz español (Ajustes app de
///     Google > Voz > Reconocimiento de voz sin conexión); si no lo tiene,
///     el propio SO sigue devolviendo `error_language_unavailable`.
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
  bool _localeFallbackDone = false;
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
    // Android e iOS dejan que speech_to_text gestione el permiso nativo.
    // Así evitamos duplicar el diálogo de micrófono con otra capa y nos
    // alineamos con el motor de reconocimiento del sistema.
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      // Algunos dispositivos necesitan un pequeño respiro tras volver del
      // diálogo de permisos antes de inicializar el reconocedor.
      await Future.delayed(const Duration(milliseconds: 150));
    }
    try {
      _available = await _speech.initialize(
        onStatus: _onStatus,
        onError: _onError,
        debugLogging: kDebugMode,
      );
    } catch (e) {
      // El plugin nativo puede lanzar una excepción (MethodChannel roto,
      // servicio de reconocimiento ausente en el fabricante, etc.) en vez
      // de simplemente devolver `false` — sin este catch, eso tumbaba toda
      // la app al tocar cualquier botón de micrófono.
      debugPrint('SttService.init error: $e');
      _available = false;
    }
    if (_available) {
      _permanentlyDenied = false;
      _localeId = await _pickLocale();
    } else {
      try {
        _permanentlyDenied = !(await _speech.hasPermission);
      } catch (e) {
        debugPrint('SttService.hasPermission error: $e');
        _permanentlyDenied = false;
      }
    }
    return _available;
  }

  /// Abre los Ajustes del sistema para habilitar el micrófono manualmente.
  Future<void> openSettings() => openAppSettings();

  /// Elige el mejor locale de español disponible en el dispositivo.
  ///
  /// Si no hay un locale de español instalado, devuelve `null` para que el
  /// motor use su configuración por defecto en lugar de un id dudoso.
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
      return null; // null → el motor usa su propio default
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
      var ok = await init();
      if (!ok && !kIsWeb && defaultTargetPlatform == TargetPlatform.android &&
          !_permanentlyDenied) {
        // Reintento corto para Android: a veces el servicio aún no queda
        // listo en el primer frame después de conceder permisos.
        await Future.delayed(const Duration(milliseconds: 250));
        ok = await init();
      }
      if (!ok) {
        onResult(null);
        return;
      }
    }
    _pendingOnResult = onResult;
    _gotResult = false;
    _lastPartial = '';
    _localeFallbackDone = false;
    _isListening = true;
    try {
      await _listen();
    } catch (e) {
      // Igual que en init(): el plugin nativo puede lanzar en vez de
      // reportar el error por onError/onStatus. Sin este catch, la
      // excepción se propagaba sin capturar y crasheaba la app.
      debugPrint('SttService.startListening error: $e');
      _isListening = false;
      _pendingOnResult = null;
      onResult(null);
    }
  }

  Future<void> _listen() => _speech.listen(
        onResult: _onSpeechResult,
        localeId: _localeId,
        // Ajustables en Ajustes > Tiempos y accesibilidad (WCAG 2.2.1);
        // 30 s / 4 s por defecto.
        listenFor: AppSettings.instance.sttListenFor,
        pauseFor: AppSettings.instance.sttPauseFor,
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
          // La app debe funcionar sin datos/wifi: preferimos el reconocedor
          // on-device de Android (requiere el paquete de voz offline
          // descargado en el equipo) en vez del motor en la nube por defecto.
          onDevice: true,
        ),
      );

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
    // Algunos dispositivos listan un locale como "instalado" (_pickLocale)
    // pero el servicio de reconocimiento no puede usarlo en vivo. En ese
    // caso reintentamos una vez con el locale por defecto del motor antes
    // de rendirnos.
    final isLocaleIssue = error.errorMsg == 'error_language_unavailable' ||
        error.errorMsg == 'error_language_not_supported';
    if (isLocaleIssue && _localeId != null && !_localeFallbackDone) {
      _localeFallbackDone = true;
      _localeId = null;
      _listen();
      return;
    }
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
