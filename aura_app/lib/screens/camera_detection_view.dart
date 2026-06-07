import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:vibration/vibration.dart';

import '../services/object_detector.dart';
import '../services/ocr_service.dart';
import '../services/stt_service.dart';
import '../services/tts.dart';
import '../services/voice_commands.dart';

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

  final ObjectDetector _detector = ObjectDetector();
  final OcrService _ocr = OcrService();
  final SttService _stt = SttService();
  final AudioFeedback _audio = AudioFeedback();

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

  String _ocrText = '';
  String _statusMessage = 'Inicializando...';
  String? _errorMessage;

  /// Throttle del stream YOLO (≈ 3–4 fps sin sonido de obturador).
  static const Duration _frameInterval = Duration(milliseconds: 250);

  /// Intervalo entre capturas OCR (usa takePicture solo 1.5 s, menos molesto).
  static const Duration _ocrInterval = Duration(milliseconds: 1500);

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
    if (_usingStream) {
      try { _controller?.stopImageStream(); } catch (_) {}
      _usingStream = false;
    }
    _controller?.dispose();
    _detector.dispose();
    _ocr.dispose();
    _stt.stop();
    _audio.stop();
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
    if (now.difference(_lastStreamFrameAt) < _frameInterval) return;
    _lastStreamFrameAt = now;

    _isDetecting = true;
    final image = _convertCameraImage(frame);
    if (image == null) { _isDetecting = false; return; }

    _detector.detect(image).then((dets) {
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

  bool _hasNewLabel(List<String> newLabels, List<String> oldLabels) {
    for (final l in newLabels) {
      if (!oldLabels.contains(l)) return true;
    }
    return false;
  }

  // ── Conversión CameraImage → img.Image ───────────────────────────────
  img.Image? _convertCameraImage(CameraImage frame) {
    try {
      if (frame.format.group == ImageFormatGroup.yuv420) {
        return _convertYUV420(frame);
      } else if (frame.format.group == ImageFormatGroup.bgra8888) {
        return _convertBGRA8888(frame);
      }
      return null;
    } catch (e) {
      debugPrint('Error convirtiendo frame: $e');
      return null;
    }
  }

  img.Image _convertYUV420(CameraImage frame) {
    final w = frame.width;
    final h = frame.height;
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];
    final yStride = yPlane.bytesPerRow;
    final uvStride = uPlane.bytesPerRow;
    final uvPixel = uPlane.bytesPerPixel ?? 1;

    final rgb = Uint8List(w * h * 3);
    int idx = 0;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final yy = yPlane.bytes[y * yStride + x] - 16;
        final uvIdx = (y >> 1) * uvStride + (x >> 1) * uvPixel;
        final uu = uPlane.bytes[uvIdx] - 128;
        final vv = vPlane.bytes[uvIdx] - 128;
        rgb[idx++] = ((298 * yy + 409 * vv + 128) >> 8).clamp(0, 255);
        rgb[idx++] = ((298 * yy - 100 * uu - 208 * vv + 128) >> 8).clamp(0, 255);
        rgb[idx++] = ((298 * yy + 516 * uu + 128) >> 8).clamp(0, 255);
      }
    }
    return img.Image.fromBytes(
      width: w, height: h, bytes: rgb.buffer, numChannels: 3,
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
      await Future.delayed(_mode == CamMode.ocr ? _ocrInterval : _frameInterval);
    }
  }

  /// Procesa un frame en modo lectura de texto (OCR).
  Future<void> _processOcr(XFile xfile) async {
    final text = await _ocr.recognize(xfile.path);
    if (!mounted) return;
    if (text.isEmpty) {
      setState(() => _statusMessage = 'Acerca la cámara al texto...');
      return;
    }
    // Solo leer en voz alta cuando el texto cambia, para no repetir.
    if (text != _ocrText) {
      setState(() {
        _ocrText = text;
        _statusMessage = 'Leyendo texto';
      });
      _audio.speak(text);
    }
  }

  /// Cambia entre modo YOLO y OCR. Detiene el mecanismo anterior (stream o
  /// bucle), actualiza el estado y reinicia si estaba activo.
  void _setMode(CamMode mode) {
    if (_mode == mode) return;
    final wasActive = _streamActive;

    // Para limpiamente el modo anterior antes de cambiar.
    if (wasActive) _stopDetection();

    setState(() {
      _mode = mode;
      _detections = [];
      _ocrText = '';
      _lastDetectedLabels = const [];
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

  // ── Voz dentro de la cámara ───────────────────────────────────────────
  Future<void> _handleVoiceTap() async {
    if (_voiceListening) {
      await _stt.stop();
      if (mounted) setState(() => _voiceListening = false);
      return;
    }
    setState(() => _voiceListening = true);
    await _audio.speak('Te escucho.');
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    await _stt.startListening(onResult: (text) {
      if (!mounted) return;
      setState(() => _voiceListening = false);
      if (text == null || text.isEmpty) {
        if (_stt.permanentlyDenied) {
          _audio.speak('Necesito permiso del micrófono. Te llevo a ajustes.');
          _stt.openSettings();
        } else {
          _audio.speak('No entendí, intenta de nuevo.');
        }
        return;
      }
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
    });
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
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _errorMessage != null ? Icons.videocam_off : Icons.hourglass_top,
            color: Colors.white38,
            size: 64,
          ),
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
              GestureDetector(
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
    return Container(
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
          Text(
            d.label.toUpperCase(),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '${(d.confidence * 100).toStringAsFixed(0)}%',
            style: const TextStyle(color: Colors.white54, fontSize: 14),
          ),
        ],
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
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
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
