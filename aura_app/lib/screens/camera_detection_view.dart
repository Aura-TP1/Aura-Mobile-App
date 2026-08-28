import 'dart:async';
import 'dart:io' show ProcessInfo;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:vibration/vibration.dart';

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
    _convertCameraImageAsync(frame).then((image) {
      if (image == null) { _isDetecting = false; return; }
      _handleConvertedFrame(image, frameStart);
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
        );
        _adaptiveFrameInterval = Duration(milliseconds: newMs);
        _slowFrameCount = 0;
      }
    } else {
      _slowFrameCount = 0;
      // Recuperar intervalo base cuando el dispositivo vuelve a ser rápido.
      if (_adaptiveFrameInterval > _minFrameInterval) {
        final newMs = (_adaptiveFrameInterval.inMilliseconds - 50).clamp(
          _minFrameInterval.inMilliseconds, 500,
        );
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

  // ── Conversión CameraImage → img.Image ───────────────────────────────
  //
  // La conversión YUV420→RGB (el bottleneck de FPS confirmado en el audit:
  // un loop pixel-a-pixel en Dart) se movió a un isolate en background con
  // `Isolate.run`, para no bloquear el hilo principal (UI + gestos + stream
  // callback siguiente) mientras se procesa el frame.
  //
  // Trade-offs vs. la versión anterior (buffer reutilizado en el hilo
  // principal):
  //  - Ya no se puede reutilizar `_rgbBuffer` entre frames: cada llamada a
  //    Isolate.run copia los datos de entrada al nuevo isolate y copia el
  //    resultado de vuelta, así que se asigna un buffer RGB nuevo por frame
  //    (~1 MB para una cámara 640x480). Esto aumenta la presión sobre el GC
  //    comparado con el buffer reutilizado anterior.
  //  - `Isolate.run` crea y destruye un isolate por llamada (~1-5 ms de
  //    overhead típico en dispositivos móviles, más el costo de copiar los
  //    planes Y/U/V, que también se copian explícitamente antes de cruzar
  //    el límite del isolate). Para frames de cámara (cientos de KB) esto
  //    es aceptable y muy inferior al tiempo que el loop bloqueaba la UI.
  //  - BGRA8888 (usado en iOS) no pasa por el loop pixel-a-pixel — ya usa
  //    `img.Image.fromBytes` directo sobre los bytes nativos — así que se
  //    mantiene síncrono, no necesita isolate.
  Future<img.Image?> _convertCameraImageAsync(CameraImage frame) async {
    try {
      if (frame.format.group == ImageFormatGroup.yuv420) {
        return await _convertYUV420Isolate(frame);
      } else if (frame.format.group == ImageFormatGroup.bgra8888) {
        return _convertBGRA8888(frame);
      }
      return null;
    } catch (e) {
      debugPrint('Error convirtiendo frame: $e');
      return null;
    }
  }

  Future<img.Image> _convertYUV420Isolate(CameraImage frame) async {
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];

    final args = _YuvConversionArgs(
      width: frame.width,
      height: frame.height,
      yStride: yPlane.bytesPerRow,
      uvStride: uPlane.bytesPerRow,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
      // Copias explícitas: los bytes de los planes viven en memoria nativa
      // gestionada por el plugin `camera` y no son seguros de compartir
      // directamente entre isolates.
      yBytes: Uint8List.fromList(yPlane.bytes),
      uBytes: Uint8List.fromList(uPlane.bytes),
      vBytes: Uint8List.fromList(vPlane.bytes),
    );

    final rgb = await Isolate.run(() => _yuv420ToRgb(args));
    return img.Image.fromBytes(
      width: args.width, height: args.height, bytes: rgb.buffer, numChannels: 3,
    );
  }

  img.Image _convertBGRA8888(CameraImage frame) {
    return img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.planes[0].bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
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

    _audio.speak(text).then((_) {
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
            if (_isInitialized && _detections.isNotEmpty) _buildDetectionOverlay(),
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

  Widget _buildDetectionOverlay() {
    return LayoutBuilder(
      builder: (context, constraints) {
        return IgnorePointer(
          child: CustomPaint(
            size: Size(constraints.maxWidth, constraints.maxHeight),
            painter: _DetectionPainter(detections: _detections),
          ),
        );
      },
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
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.of(context).maybePop(),
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
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: _streamActive
                    ? Colors.green.withOpacity(0.85)
                    : Colors.white.withOpacity(0.15),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_streamActive)
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: const BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                      ),
                    ),
                  Text(
                    _streamActive ? 'EN VIVO' : 'PAUSADO',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
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
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 72,
                    height: 72,
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
                    child: Icon(
                      _streamActive ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      color: _streamActive ? Colors.white : Colors.black,
                      size: 36,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
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
      label: 'Detectado: ${d.label}, confianza $pct%',
      liveRegion: true,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 50,
              height: 50,
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? Colors.white.withOpacity(0.15)
                    : Colors.white.withOpacity(0.05),
              ),
              child: Icon(icon,
                  color: active ? Colors.white : Colors.white30, size: 22),
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Painter: dibuja bounding boxes sobre el preview.
// ─────────────────────────────────────────────────────────────────────────
class _DetectionPainter extends CustomPainter {
  final List<Detection> detections;

  _DetectionPainter({required this.detections});

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.greenAccent;

    final bgPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.greenAccent.withOpacity(0.15);

    for (final d in detections) {
      // d.rect está en coordenadas normalizadas [0..1].
      final rect = Rect.fromLTWH(
        d.rect.left * size.width,
        d.rect.top * size.height,
        d.rect.width * size.width,
        d.rect.height * size.height,
      );

      canvas.drawRect(rect, bgPaint);
      canvas.drawRect(rect, boxPaint);

      final tp = TextPainter(
        text: TextSpan(
          text: ' ${d.label} ${(d.confidence * 100).toStringAsFixed(0)}% ',
          style: const TextStyle(
            color: Colors.black,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            backgroundColor: Colors.greenAccent,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      tp.paint(canvas, Offset(rect.left, rect.top - 18));
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionPainter old) =>
      old.detections != detections;
}

/// Datos de entrada para la conversión YUV420→RGB en isolate. Todos los
/// campos son tipos "sendable" (primitivos + Uint8List) para poder cruzar
/// el límite del isolate sin copias implícitas costosas.
class _YuvConversionArgs {
  final int width;
  final int height;
  final int yStride;
  final int uvStride;
  final int uvPixelStride;
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;

  _YuvConversionArgs({
    required this.width,
    required this.height,
    required this.yStride,
    required this.uvStride,
    required this.uvPixelStride,
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
  });
}

/// Función top-level ejecutada dentro del isolate de background vía
/// `Isolate.run`. Misma lógica de conversión YUV420 (BT.601) que antes,
/// solo que ahora corre fuera del hilo principal.
Uint8List _yuv420ToRgb(_YuvConversionArgs a) {
  final rgb = Uint8List(a.width * a.height * 3);
  int idx = 0;
  for (int y = 0; y < a.height; y++) {
    for (int x = 0; x < a.width; x++) {
      final yy = a.yBytes[y * a.yStride + x] - 16;
      final uvIdx = (y >> 1) * a.uvStride + (x >> 1) * a.uvPixelStride;
      final uu = a.uBytes[uvIdx] - 128;
      final vv = a.vBytes[uvIdx] - 128;
      rgb[idx++] = ((298 * yy + 409 * vv + 128) >> 8).clamp(0, 255);
      rgb[idx++] = ((298 * yy - 100 * uu - 208 * vv + 128) >> 8).clamp(0, 255);
      rgb[idx++] = ((298 * yy + 516 * uu + 128) >> 8).clamp(0, 255);
    }
  }
  return rgb;
}
