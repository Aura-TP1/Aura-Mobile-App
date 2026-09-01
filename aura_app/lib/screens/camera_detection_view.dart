import 'dart:async';
import 'dart:io' show ProcessInfo;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:vibration/vibration.dart';

import '../services/camera_frame_converter.dart';
import '../services/object_detector.dart';
import '../services/ocr_service.dart';
import '../services/voice_input_service.dart';
import '../services/tts.dart';
import '../services/voice_commands.dart';
import '../services/app_settings.dart';
import '../services/metrics_logger.dart';
import '../widgets/voice_text_fallback_sheet.dart';

/// Modo de la pantalla de cámara: detección de objetos (YOLO) o lectura de
/// texto (OCR). Solo uno está activo a la vez; al cambiar, el otro se pausa.
enum CamMode { yolo, ocr }

/// Vista de cámara con detección de objetos en vivo y lectura de texto (OCR).
///
/// YOLO usa [startImageStream] en Android/iOS para evitar el sonido de
/// obturador. En Web/Desktop (sin soporte) cae a [takePicture] automáticamente.
/// OCR siempre usa [takePicture] (solo 1.5 s de intervalo).
class CameraDetectionView extends StatefulWidget {
  const CameraDetectionView({super.key});

  @override
  State<CameraDetectionView> createState() => _CameraDetectionViewState();
}

class _CameraDetectionViewState extends State<CameraDetectionView>
    with WidgetsBindingObserver {
  // ── Estado ────────────────────────────────────────────────────────────
  CameraController? _controller;
  List<CameraDescription> _cameras = [];
  int _selectedCameraIdx = 0;

  final ObjectDetector _detector =
      ObjectDetector(useInt8: AppSettings.instance.useYoloInt8);
  final OcrService _ocr = OcrService();
  final AudioFeedback _audio = AudioFeedback();
  late final VoiceInputService _voice = VoiceInputService(_audio);

  bool _isInitialized = false;
  bool _isDetecting = false;
  bool _streamActive = false;
  bool _modelLoaded = false;
  bool _voiceListening = false;
  bool _handledArgs = false;

  /// true cuando YOLO corre con startImageStream (sin sonido de obturador).
  bool _usingStream = false;

  /// Modo activo. Default YOLO; puede arrancar en OCR vía argumento de ruta.
  CamMode _mode = CamMode.yolo;

  List<Detection> _detections = [];
  List<String> _lastDetectedLabels = const [];
  DateTime _lastHapticAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastStreamFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  // ── Métricas de rendimiento en vivo ──────────────────────────────────
  int _lastFrameMs = 0;
  double _avgFrameMs = 0;
  int _ramMb = 0;
  final List<int> _frameTimes = [];

  String _ocrText = '';
  String _statusMessage = 'Inicializando...';
  String? _errorMessage;

  // ── BUG 1: Throttle adaptativo ────────────────────────────────────────
  /// Intervalo base del stream YOLO. Se aumenta automáticamente si el
  /// dispositivo tarda >200 ms en inferencia (hasta 500 ms).
  static const Duration _minFrameInterval = Duration(milliseconds: 300);
  Duration _adaptiveFrameInterval = const Duration(milliseconds: 300);
  int _slowFrameCount = 0;

  /// Intervalo entre capturas OCR (usa takePicture solo 1.5 s, menos molesto).
  static const Duration _ocrInterval = Duration(milliseconds: 1500);

  // ── BUG 2: Anti-repetición OCR/TTS ───────────────────────────────────
  /// Texto de la última lectura TTS completada.
  String _lastReadText = '';
  /// Momento en que terminó la última lectura TTS.
  DateTime _lastReadAt = DateTime.fromMillisecondsSinceEpoch(0);
  /// true mientras TTS está leyendo un texto OCR.
  bool _ocrSpeaking = false;
  /// Timer de debounce: espera 800 ms de estabilidad antes de leer.
  Timer? _ocrDebounce;

  /// Ajustables en Ajustes > Tiempos y accesibilidad (WCAG 2.2.1).
  Duration get _ocrDebounceDelay => AppSettings.instance.ocrDebounce;
  Duration get _ocrReadCooldown => AppSettings.instance.ocrCooldown;

  /// Pausa entre chequeos mientras se espera a que termine la lectura TTS
  /// en curso (no se toman fotos nuevas durante ese tiempo).
  static const Duration _ocrSpeakingPoll = Duration(milliseconds: 300);

  // ── Lifecycle ─────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  Future<void> _init() async {
    await _audio.init();
    await _initCamera();
    // En modo OCR no hace falta YOLO; lo cargamos igual para que el usuario
    // pueda pedir objetos por voz, pero no bloqueamos el arranque por ello.
    await _loadModel();
    if (!mounted) return;
    // Arranque automático: el usuario eligió "Encontrar objeto" o "Leer texto"
    // desde el menú, así que empezamos a detectar/leer sin que toque ▶.
    await _audio.speak(_mode == CamMode.ocr
        ? 'Lectura de texto. Apunta la cámara al texto.'
        : 'Detección de objetos. Apunta la cámara y te diré qué veo.');
    if (!mounted) return;
    _startDetection();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Argumento de ruta 'ocr' (comando "Aura lee") arranca en modo lectura.
    if (_handledArgs) return;
    _handledArgs = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args == 'ocr') {
      _mode = CamMode.ocr;
      _statusMessage = 'Modo lectura de texto.';
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _stopDetection();
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _streamActive = false;
    _ocrDebounce?.cancel();
    if (_usingStream) {
      try { _controller?.stopImageStream(); } catch (_) {}
      _usingStream = false;
    }
    _controller?.dispose();
    _detector.dispose();
    _ocr.dispose();
    _voice.stop();
    _audio.stop();
    _audio.dispose();
    super.dispose();
  }

  // ── Cámara ────────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() => _errorMessage = 'No se encontró ninguna cámara.');
        }
        return;
      }
      await _startCamera(_cameras[_selectedCameraIdx]);
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Error al acceder a la cámara: $e');
      }
    }
  }

  Future<void> _startCamera(CameraDescription camera) async {
    final prev = _controller;
    if (prev != null) {
      await prev.dispose();
    }

    // ResolutionPreset.medium da buen balance rendimiento/latencia en laptop.
    final controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    _controller = controller;

    try {
      await controller.initialize();
      // Sin esto, algunos dispositivos Android activan el flash automático
      // de la cámara nativa en poca luz al usar takePicture() (modo OCR) —
      // el plugin no fija FlashMode explícitamente por defecto.
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (e) {
        debugPrint('No se pudo forzar flash apagado: $e');
      }
      if (!mounted) return;
      setState(() {
        _isInitialized = true;
        _errorMessage = null;
        _statusMessage = _modelLoaded
            ? 'Listo. Presiona ▶ para detectar.'
            : 'Cargando modelo...';
      });
    } catch (e) {
      if (mounted) {
        setState(() => _errorMessage = 'Error inicializando cámara: $e');
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras.length < 2) return;
    final wasActive = _streamActive;
    _stopDetection();
    _selectedCameraIdx = (_selectedCameraIdx + 1) % _cameras.length;
    await _startCamera(_cameras[_selectedCameraIdx]);
    if (wasActive) _startDetection();
  }

  // ── Modelo ────────────────────────────────────────────────────────────
  Future<void> _loadModel() async {
    if (mounted) {
      setState(() => _statusMessage = 'Cargando modelo YOLOv8...');
    }
    await _detector.loadModel();
    if (!mounted) return;
    setState(() {
      _modelLoaded = _detector.isLoaded;
      _statusMessage = _modelLoaded
          ? 'Modelo listo. Presiona ▶ para detectar.'
          : (kIsWeb
              ? 'Deteccion no disponible en Web. Usa Windows o Android.'
              : 'Error al cargar el modelo.');
    });
  }

  // ── Detección ─────────────────────────────────────────────────────────
  void _startDetection() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    // OCR (lectura de texto) usa ML Kit, no necesita el modelo YOLO.
    if (_mode == CamMode.yolo && !_modelLoaded) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('El modelo aún no está cargado.')),
      );
      return;
    }
    if (_streamActive) return;

    setState(() {
      _streamActive = true;
      _statusMessage = 'Detectando...';
    });

    // YOLO en native → startImageStream (sin sonido de obturador).
    // OCR o web/desktop → bucle con takePicture.
    if (_mode == CamMode.yolo && !kIsWeb) {
      _startStreamMode();
    } else {
      _detectionLoop();
    }
  }

  void _stopDetection() {
    if (_usingStream) {
      try { _controller?.stopImageStream(); } catch (_) {}
      _usingStream = false;
    }
    setState(() {
      _streamActive = false;
      _detections = [];
      _statusMessage = 'Detenido. Presiona ▶ para detectar.';
    });
  }

  // ── Stream YOLO (sin sonido de obturador) ────────────────────────────
  void _startStreamMode() {
    try {
      _controller!.startImageStream(_onCameraFrame);
      _usingStream = true;
    } catch (e) {
      // startImageStream no soportado (Windows/macOS) → fallback con takePicture.
      debugPrint('startImageStream no disponible, usando takePicture: $e');
      _usingStream = false;
      _detectionLoop();
    }
  }

  /// Callback del stream — se invoca en el main isolate por el plugin.
  void _onCameraFrame(CameraImage frame) {
    if (!_streamActive || _mode != CamMode.yolo || _isDetecting) return;

    final now = DateTime.now();
    if (now.difference(_lastStreamFrameAt) < _adaptiveFrameInterval) return;
    _lastStreamFrameAt = now;

    _isDetecting = true;
    final frameStart = DateTime.now(); // incluye conversión + inferencia
    CameraFrameConverter.toImage(frame).then((image) {
      if (image == null) { _isDetecting = false; return; }
      _handleConvertedFrame(image, frameStart);
    }).catchError((e) {
      // Si el usuario sale de la pantalla mientras un frame está a mitad
      // de conversión (isolate en vuelo), esa conversión puede fallar al
      // resolver contra un controller/estado ya descartado. Sin este
      // catchError, esa excepción no manejada crasheaba la app al salir.
      debugPrint('Error convirtiendo frame: $e');
      _isDetecting = false;
    });
  }

  void _handleConvertedFrame(img.Image image, DateTime frameStart) {
    _detector.detect(image).then((dets) {
      final frameMs = DateTime.now().difference(frameStart).inMilliseconds;
      _updateAdaptiveInterval(frameMs);
      _updatePerfMetrics(frameMs);

      // Solo para métricas (instrumentación pura, no afecta el flujo).
      // Fire-and-forget: MetricsLogger nunca lanza excepciones ni bloquea
      // el bucle de frames.
      if (_mode == CamMode.yolo) {
        // ignore: discarded_futures
        MetricsLogger.instance.logDetectionFrame(
          frameLatencyMs: frameMs,
          detections: dets,
        );
      }

      _isDetecting = false;
      if (!mounted || !_streamActive) return;

      final newLabels = dets.map((d) => d.label).toList();

      // Vibración suave (80 ms) solo cuando aparece un objeto que no estaba.
      if (dets.isNotEmpty && _hasNewLabel(newLabels, _lastDetectedLabels)) {
        final elapsed = DateTime.now().difference(_lastHapticAt);
        if (elapsed > const Duration(seconds: 2)) {
          _lastHapticAt = DateTime.now();
          Vibration.hasVibrator().then((has) {
            if (has == true) Vibration.vibrate(duration: 80);
          });
        }
      }
      _lastDetectedLabels = newLabels;

      setState(() => _detections = dets);
      if (dets.isNotEmpty) {
        _audio.announceScene(newLabels);
        setState(() => _statusMessage =
            '${dets.first.label} (${(dets.first.confidence * 100).toStringAsFixed(0)}%)');
      } else if (mounted) {
        setState(() => _statusMessage = 'Detectando...');
      }
    }).catchError((e) {
      _isDetecting = false;
      debugPrint('Error en detección stream: $e');
    });
  }

  /// Ajusta automáticamente el intervalo entre frames según la velocidad de
  /// inferencia. >200 ms por 3 frames consecutivos → aumenta hasta 500 ms.
  void _updateAdaptiveInterval(int inferenceMs) {
    if (inferenceMs > 200) {
      _slowFrameCount++;
      if (_slowFrameCount >= 3) {
        final newMs = (_adaptiveFrameInterval.inMilliseconds + 100).clamp(
          _minFrameInterval.inMilliseconds, 500,
        ).toInt();
        _adaptiveFrameInterval = Duration(milliseconds: newMs);
        _slowFrameCount = 0;
      }
    } else {
      _slowFrameCount = 0;
      // Recuperar intervalo base cuando el dispositivo vuelve a ser rápido.
      if (_adaptiveFrameInterval > _minFrameInterval) {
        final newMs = (_adaptiveFrameInterval.inMilliseconds - 50).clamp(
          _minFrameInterval.inMilliseconds, 500,
        ).toInt();
        _adaptiveFrameInterval = Duration(milliseconds: newMs);
      }
    }
  }

  void _updatePerfMetrics(int frameMs) {
    _frameTimes.add(frameMs);
    if (_frameTimes.length > 50) _frameTimes.removeAt(0);
    _lastFrameMs = frameMs;
    _avgFrameMs = _frameTimes.reduce((a, b) => a + b) / _frameTimes.length;
    try {
      _ramMb = ProcessInfo.currentRss ~/ (1024 * 1024);
    } catch (_) {}
    // El setState que ya existe en el .then() de detect() actualiza la UI.
  }

  bool _hasNewLabel(List<String> newLabels, List<String> oldLabels) {
    for (final l in newLabels) {
      if (!oldLabels.contains(l)) return true;
    }
    return false;
  }


  // ── Bucle OCR / fallback web (takePicture) ───────────────────────────
  Future<void> _detectionLoop() async {
    while (mounted && _streamActive) {
      final c = _controller;
      if (c == null || !c.value.isInitialized) break;
      if (_isDetecting) {
        await Future.delayed(_ocrInterval);
        continue;
      }
      // Mientras se está leyendo el texto en voz alta, no tomamos fotos
      // nuevas: dejamos que termine de leer antes de volver a mirar la
      // cámara (evita relecturas por movimientos de la cámara).
      if (_mode == CamMode.ocr && _ocrSpeaking) {
        await Future.delayed(_ocrSpeakingPoll);
        continue;
      }
      _isDetecting = true;
      try {
        final xfile = await c.takePicture();
        if (_mode == CamMode.ocr) {
          await _processOcr(xfile);
        } else {
          // Fallback web/desktop: YOLO con takePicture (sin stream disponible).
          final bytes = await xfile.readAsBytes();
          final image = img.decodeImage(bytes);
          if (image != null) {
            final dets = await _detector.detect(image);
            if (!mounted) break;
            setState(() => _detections = dets);
            if (dets.isNotEmpty) {
              _audio.announceScene(dets.map((d) => d.label).toList());
              setState(() => _statusMessage =
                  '${dets.first.label} (${(dets.first.confidence * 100).toStringAsFixed(0)}%)');
            } else if (mounted) {
              setState(() => _statusMessage = 'Detectando...');
            }
          }
        }
      } catch (e) {
        debugPrint('Error en detección: $e');
      } finally {
        _isDetecting = false;
      }
      await Future.delayed(_mode == CamMode.ocr ? _ocrInterval : _adaptiveFrameInterval);
    }
  }

  /// Procesa un frame en modo lectura de texto (OCR).
  /// Aplica debounce (800 ms) para esperar estabilidad del dispositivo
  /// antes de intentar una lectura TTS.
  Future<void> _processOcr(XFile xfile) async {
    final text = await _ocr.recognize(xfile.path);
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() => _statusMessage = 'Acerca la cámara al texto...');
      return;
    }

    // Actualizar texto mostrado en pantalla de inmediato.
    setState(() => _ocrText = text);

    // Reiniciar debounce: solo proceder si el texto no cambia en 800 ms.
    _ocrDebounce?.cancel();
    _ocrDebounce = Timer(_ocrDebounceDelay, () => _tryReadOcrText(text));
  }

  /// Intenta leer el texto en voz alta con todos los guards activos:
  /// - No interrumpir lectura en curso (_ocrSpeaking)
  /// - Solo si el texto es diferente al último leído (_lastReadText)
  /// - Cooldown de 3 s tras finalizar una lectura (_ocrReadCooldown)
  void _tryReadOcrText(String text) {
    if (!mounted || !_streamActive) return;
    if (_ocrSpeaking) return;
    // Comparación normalizada: pequeñas variaciones de OCR por el movimiento
    // de la cámara (espacios, mayúsculas) no deben disparar una relectura.
    final normalized = _normalizeOcr(text);
    if (normalized == _lastReadText) return;
    if (DateTime.now().difference(_lastReadAt) < _ocrReadCooldown) return;

    _ocrSpeaking = true;
    _lastReadText = normalized;
    setState(() => _statusMessage = 'Leyendo texto...');

    // Timeout de seguridad: si el motor TTS se cuelga (no resuelve el
    // Future de speak(), algo que pasa en algunos dispositivos/versiones
    // de Android), _ocrSpeaking se quedaba en true para siempre y el
    // bucle de OCR dejaba de tomar fotos nuevas indefinidamente — la
    // app parecía "trabada" mostrando el último texto leído sin importar
    // a dónde se apuntara la cámara después.
    _audio.speak(text).timeout(
      const Duration(seconds: 12),
      onTimeout: () => debugPrint('OCR: speak() no resolvió a tiempo, liberando.'),
    ).then((_) {
      _ocrSpeaking = false;
      _lastReadAt = DateTime.now();
      if (mounted) setState(() => _statusMessage = 'Modo lectura de texto.');
    });
  }

  String _normalizeOcr(String text) =>
      text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Cambia entre modo YOLO y OCR. Detiene el mecanismo anterior (stream o
  /// bucle), actualiza el estado y reinicia si estaba activo.
  void _setMode(CamMode mode) {
    if (_mode == mode) return;
    final wasActive = _streamActive;

    // Para limpiamente el modo anterior antes de cambiar.
    if (wasActive) _stopDetection();

    _ocrDebounce?.cancel();
    setState(() {
      _mode = mode;
      _detections = [];
      _ocrText = '';
      _lastDetectedLabels = const [];
      _ocrSpeaking = false;
      _lastReadText = '';
      _lastReadAt = DateTime.fromMillisecondsSinceEpoch(0);
      _statusMessage = mode == CamMode.ocr
          ? 'Modo lectura de texto.'
          : 'Modo detección de objetos.';
    });
    _audio.resetScene();
    _audio.haptic(200);
    _audio.speak(mode == CamMode.ocr
        ? 'Modo lectura de texto activado.'
        : 'Modo detección de objetos activado.');

    if (wasActive) _startDetection();
  }

  // ── Voz dentro de la cámara ─────────────────────────────────────────────
  // Fallback de 3 niveles: Google/on-device STT → Vosk offline → campo de
  // texto (solo si ambos niveles de voz fallan).
  Future<void> _handleVoiceTap() async {
    if (_voiceListening) {
      await _voice.stop();
      if (mounted) setState(() => _voiceListening = false);
      return;
    }
    setState(() => _voiceListening = true);
    await _audio.speak('Te escucho.');
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    final text = await _voice.listen();
    if (!mounted) return;
    setState(() => _voiceListening = false);

    if (text != null) {
      _routeCameraVoiceCommand(text);
      return;
    }
    if (_voice.permanentlyDenied) {
      await _audio.speak('Necesito permiso del micrófono. Te llevo a ajustes.');
      await _voice.openSettings();
      return;
    }
    // Tier 3: ambos niveles de voz fallaron, dicta el comando por teclado.
    await _audio.speak('Escribe tu comando.');
    if (!mounted) return;
    final typed = await showVoiceTextFallbackSheet(context, hint: 'Escribe tu comando');
    if (typed != null && typed.isNotEmpty) {
      _routeCameraVoiceCommand(typed);
    }
  }

  void _routeCameraVoiceCommand(String text) {
    final cmd = VoiceCommandParser.parse(text);
    switch (cmd.type) {
      case AuraCommandType.readText:
        _setMode(CamMode.ocr);
        if (!_streamActive) _startDetection();
        break;
      case AuraCommandType.describe:
        _setMode(CamMode.yolo);
        if (!_streamActive) _startDetection();
        break;
      case AuraCommandType.stop:
        _stopDetection();
        _audio.stop();
        break;
      default:
        _audio.speak('No entendí, intenta de nuevo.');
    }
  }

  // ── UI ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            if (_isInitialized && _errorMessage == null)
              _buildCameraPreview()
            else
              _buildPlaceholder(),
            // Los bounding boxes se quitaron: aparecían desalineados sobre
            // la imagen real y no aportaban a un usuario con baja visión —
            // la detección se sigue anunciando por voz y en el badge.
            if (_streamActive && _mode == CamMode.yolo && _lastFrameMs > 0)
              _buildPerfOverlay(),
            _buildTopBar(),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomControls(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCameraPreview() {
    final controller = _controller!;
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: CameraPreview(controller),
      ),
    );
  }

  Widget _buildPlaceholder() {
    final isLoading = _errorMessage == null;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (isLoading)
            const SizedBox(
              width: 48,
              height: 48,
              child: CircularProgressIndicator(
                color: Colors.white38,
                strokeWidth: 3,
              ),
            )
          else
            const Icon(Icons.videocam_off, color: Colors.white38, size: 64),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _errorMessage ?? _statusMessage,
              style: const TextStyle(color: Colors.white54, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPerfOverlay() {
    final fps = _lastFrameMs > 0 ? 1000 / _lastFrameMs : 0.0;
    final avgFps = _avgFrameMs > 0 ? 1000 / _avgFrameMs : 0.0;
    return Positioned(
      top: 72,
      left: 12,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.65),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DefaultTextStyle(
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 11,
              fontFamily: 'monospace',
              height: 1.6,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Frame  ${_lastFrameMs} ms  ${fps.toStringAsFixed(1)} fps'),
                Text('Avg50  ${_avgFrameMs.toStringAsFixed(1)} ms  ${avgFps.toStringAsFixed(1)} fps'),
                Text('RAM    ${_ramMb} MB'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withOpacity(0.7), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Volver',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
              // Detener el stream/loop de detección ANTES de salir: si queda
              // un frame en vuelo (conversión/inferencia async) cuando el
              // widget se dispone, puede fallar contra un controller ya
              // liberado. Parar primero reduce esa ventana.
              onPressed: () {
                _stopDetection();
                Navigator.of(context).maybePop();
              },
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _mode == CamMode.ocr ? 'LEER TEXTO' : 'ENCONTRAR OBJETO',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Antes decía "EN VIVO"/"PAUSADO" en texto; ahora es solo un
            // punto de color (verde = detectando, rojo = en pausa), oculto
            // del todo si la cámara ni siquiera está lista todavía.
            if (_isInitialized)
              Semantics(
                label: _streamActive ? 'Detectando' : 'En pausa',
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _streamActive ? Colors.green : Colors.red,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.85), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_mode == CamMode.ocr && _ocrText.isNotEmpty)
            _buildOcrCard()
          else if (_mode == CamMode.yolo && _detections.isNotEmpty)
            _buildDetectionBadge(_detections.first),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _IconButton(
                icon: Icons.flip_camera_ios,
                label: 'Cambiar',
                onTap: _cameras.length > 1 ? _switchCamera : null,
              ),
              _IconButton(
                icon: _voiceListening ? Icons.mic : Icons.mic_none,
                label: 'Voz',
                onTap: _handleVoiceTap,
              ),
              Semantics(
                button: true,
                label: _streamActive ? 'Detener detección' : 'Iniciar detección',
                onTap: _streamActive ? _stopDetection : _startDetection,
                child: GestureDetector(
                  onTap: _streamActive ? _stopDetection : _startDetection,
                  // Sin esto el botón queda con dos acciones de tap en el
                  // árbol de accesibilidad y el doble toque de TalkBack las
                  // dispara a las dos: la detección arrancaba y se detenía
                  // en el mismo gesto.
                  excludeFromSemantics: true,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 104,
                    height: 104,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _streamActive ? Colors.red : Colors.white,
                      boxShadow: [
                        BoxShadow(
                          color: (_streamActive ? Colors.red : Colors.white)
                              .withOpacity(0.4),
                          blurRadius: 20,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    // ExcludeSemantics: sin esto, este Icon puede generar su
                    // propio nodo de accesibilidad (sin texto) que compite
                    // con el label del Semantics padre — TalkBack terminaba
                    // sin leer nada útil en este botón.
                    child: ExcludeSemantics(
                      child: Icon(
                        _streamActive ? Icons.stop_rounded : Icons.play_arrow_rounded,
                        color: _streamActive ? Colors.white : Colors.black,
                        size: 56,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Antes mostraba SIEMPRE el estado ("Modelo listo. Presiona ▶
          // para detectar.", "Detectando...", etc.) — puro ruido visual,
          // repite lo que ya se anuncia por voz. Solo vale la pena
          // mostrarlo cuando es un error real (algo que el usuario
          // necesita saber y que no tiene otro aviso).
          if (_statusMessage.toLowerCase().contains('error'))
            Text(
              _statusMessage,
              style: TextStyle(
                color: Colors.white.withOpacity(0.6),
                fontSize: 12,
              ),
              textAlign: TextAlign.center,
            ),
        ],
      ),
    );
  }

  /// Tarjeta que muestra el texto leído por OCR (modo lectura).
  Widget _buildOcrCard() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 140),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.2)),
      ),
      child: SingleChildScrollView(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.text_fields, color: Colors.white70, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _ocrText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetectionBadge(Detection d) {
    final pct = (d.confidence * 100).toStringAsFixed(0);
    return Semantics(
      // Sin el porcentaje: TalkBack lo anunciaba cada vez que cambiaba la
      // detección ("... confianza 45%"), que no aporta al usuario y se
      // sentía como que "el micrófono" hablaba solo de porcentajes.
      label: 'Detectado: ${d.label}',
      liveRegion: true,
      // ExcludeSemantics: aunque el label de arriba ya no menciona el
      // porcentaje, los Text hijos (ej. "45%") generan su propio nodo de
      // accesibilidad y Flutter los fusiona con el del padre — TalkBack
      // seguía leyendo el porcentaje pese al cambio de label. Sin esto,
      // solo se anuncia el label explícito.
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.2)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.visibility, color: Colors.white70, size: 18),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  d.label.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$pct%',
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Botón de icono auxiliar
// ─────────────────────────────────────────────────────────────────────────
class _IconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _IconButton({
    required this.icon,
    required this.label,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    return Semantics(
      button: true,
      label: label,
      enabled: active,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        // El ExcludeSemantics de abajo tapa los nodos del Icon y el Text,
        // pero el GestureDetector publica además su propia acción de tap: con
        // eso el botón quedaba con dos acciones y el doble toque de TalkBack
        // disparaba `onTap` dos veces.
        excludeFromSemantics: true,
        // El label ya está en el Semantics padre — sin ExcludeSemantics,
        // el Icon y el Text de abajo generan sus propios nodos y pueden
        // hacer que TalkBack no lea el label correcto o lo repita.
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 80,
                height: 80,
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: active
                      ? Colors.white.withOpacity(0.15)
                      : Colors.white.withOpacity(0.05),
                ),
                child: Icon(icon,
                    color: active ? Colors.white : Colors.white30, size: 36),
              ),
              const SizedBox(height: 4),
              Text(label,
                  style: TextStyle(
                    color: active ? Colors.white60 : Colors.white24,
                    fontSize: 10,
                  )),
            ],
          ),
        ),
      ),
    );
  }
}
