import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;

import '../services/object_detector.dart';
import '../services/tts.dart';

/// Vista de cámara con detección de objetos en vivo.
///
/// Usa un bucle con [CameraController.takePicture] en lugar de
/// [startImageStream], porque este último no está soportado en Flutter Web
/// ni en Windows desktop (los objetivos principales de AURA para pruebas
/// en laptop).
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
  final AudioFeedback _audio = AudioFeedback();

  bool _isInitialized = false;
  bool _isDetecting = false;
  bool _streamActive = false;
  bool _modelLoaded = false;

  List<Detection> _detections = [];
  String _statusMessage = 'Inicializando...';
  String? _errorMessage;

  /// Intervalo entre capturas (≈ 3–4 fps). Ajustable según rendimiento.
  static const Duration _frameInterval = Duration(milliseconds: 250);

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
    await _loadModel();
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
    _controller?.dispose();
    _detector.dispose();
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

  // ── Bucle de detección ────────────────────────────────────────────────
  void _startDetection() {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (!_modelLoaded) {
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
    _detectionLoop();
  }

  void _stopDetection() {
    setState(() {
      _streamActive = false;
      _detections = [];
      _statusMessage = 'Detenido. Presiona ▶ para detectar.';
    });
  }

  Future<void> _detectionLoop() async {
    while (mounted && _streamActive) {
      final c = _controller;
      if (c == null || !c.value.isInitialized) break;
      if (_isDetecting) {
        await Future.delayed(_frameInterval);
        continue;
      }
      _isDetecting = true;
      try {
        final xfile = await c.takePicture();
        final bytes = await xfile.readAsBytes();
        final image = img.decodeImage(bytes);
        if (image == null) {
          debugPrint('No se pudo decodificar el frame.');
        } else {
          final dets = await _detector.detect(image);
          if (!mounted) break;
          setState(() => _detections = dets);
          if (dets.isNotEmpty) {
            final top = dets.first;
            await _audio.announce(top.label);
            if (mounted) {
              setState(() =>
                  _statusMessage = '${top.label} (${(top.confidence * 100).toStringAsFixed(0)}%)');
            }
          } else if (mounted) {
            setState(() => _statusMessage = 'Detectando...');
          }
        }
      } catch (e) {
        debugPrint('Error en detección: $e');
      } finally {
        _isDetecting = false;
      }
      await Future.delayed(_frameInterval);
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
            const Text(
              'AURA',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
              ),
            ),
            const Spacer(),
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
          if (_detections.isNotEmpty) _buildDetectionBadge(_detections.first),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _IconButton(
                icon: Icons.flip_camera_ios,
                label: 'Cambiar',
                onTap: _cameras.length > 1 ? _switchCamera : null,
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
              _IconButton(
                icon: Icons.refresh_rounded,
                label: 'Modelo',
                onTap: _modelLoaded ? null : _loadModel,
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
