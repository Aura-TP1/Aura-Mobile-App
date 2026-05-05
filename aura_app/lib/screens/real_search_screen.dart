import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:vibration/vibration.dart';

import '../models/saved_object.dart';
import '../services/embedding_service.dart';
import '../services/embedding_service_common.dart';
import '../services/tts.dart';

const Color _kAuraRed = Color(0xFFE53935);
const Color _kAuraGreen = Color(0xFF2E7D32);
const double _kMinButtonHeight = 64;

/// Pantalla de búsqueda real de un objeto personal.
///
/// Abre la cámara, extrae un embedding cada 300 ms con MobileNetV2 y
/// lo compara contra el embedding guardado del objeto buscado usando
/// similitud coseno. Si supera 0.75 → vibración + TTS + pantalla de éxito.
///
/// Si el [savedObject] no tiene embedding (fue guardado en web o antes de la
/// captura con cámara), muestra un mensaje claro en lugar de buscar.
class RealSearchScreen extends StatefulWidget {
  final String target;
  final SavedObject savedObject;

  const RealSearchScreen({
    super.key,
    required this.target,
    required this.savedObject,
  });

  @override
  State<RealSearchScreen> createState() => _RealSearchScreenState();
}

class _RealSearchScreenState extends State<RealSearchScreen>
    with TickerProviderStateMixin {
  final EmbeddingService _embeddings = EmbeddingService();
  final AudioFeedback _audio = AudioFeedback();

  CameraController? _camera;
  bool _cameraReady = false;
  String? _cameraError;

  bool _modelLoaded = false;
  bool _scanning = false;
  bool _detected = false;
  bool _disposed = false;
  double _currentSimilarity = 0;

  late final AnimationController _sweepController;
  late final AnimationController _foundController;

  static const Duration _frameInterval = Duration(milliseconds: 300);
  static const double _threshold = 0.75;

  @override
  void initState() {
    super.initState();
    _sweepController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _foundController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _init();
  }

  Future<void> _init() async {
    await _audio.init();

    if (!widget.savedObject.hasEmbedding) {
      await _audio.speak(
        'Este objeto no tiene imagen guardada. '
        'Ve a Mis objetos y captúralo con la cámara primero.',
      );
      return;
    }

    await _audio.speak(
      'Buscando ${widget.target}. Apunta la cámara al objeto.',
    );

    // Cámara y modelo se cargan en paralelo.
    await Future.wait([_initCamera(), _loadModel()]);

    if (mounted && _cameraReady && _modelLoaded) {
      _startScan();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _cameraError = 'No se encontró cámara.');
        return;
      }
      final controller = CameraController(
        cams.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraReady = true;
      });
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'Error de cámara: $e');
      debugPrint('RealSearchScreen camera error: $e');
    }
  }

  Future<void> _loadModel() async {
    await _embeddings.loadModel();
    if (mounted) setState(() => _modelLoaded = _embeddings.isLoaded);
  }

  // ── Bucle de escaneo ─────────────────────────────────────────────────────

  void _startScan() {
    if (_scanning || _detected) return;
    setState(() {
      _scanning = true;
      _currentSimilarity = 0;
    });
    _sweepController.repeat();
    _scanLoop();
  }

  Future<void> _scanLoop() async {
    while (!_disposed && mounted && _scanning && !_detected) {
      final c = _camera;
      if (c == null || !c.value.isInitialized) {
        await Future.delayed(_frameInterval);
        continue;
      }

      try {
        final xfile = await c.takePicture();
        final bytes = await xfile.readAsBytes();
        final image = img.decodeImage(bytes);
        if (image == null) {
          await Future.delayed(_frameInterval);
          continue;
        }

        final frameEmb = await _embeddings.extractEmbedding(image);
        if (frameEmb.isEmpty) {
          await Future.delayed(_frameInterval);
          continue;
        }

        final sim = cosineSimilarity(widget.savedObject.embedding, frameEmb);

        if (!mounted || _disposed) return;
        setState(() => _currentSimilarity = sim);

        if (sim >= _threshold) {
          await _onFound();
          return;
        }
      } catch (e) {
        debugPrint('RealSearchScreen scan error: $e');
      }

      await Future.delayed(_frameInterval);
    }
  }

  Future<void> _onFound() async {
    if (!mounted || _disposed) return;
    setState(() {
      _detected = true;
      _scanning = false;
    });
    _sweepController.stop();
    _foundController.forward();

    final hasVibrator = await Vibration.hasVibrator() ?? false;
    if (hasVibrator) {
      await Vibration.vibrate(pattern: [0, 300, 100, 300]);
    }

    await _audio.speak('¡Encontrado! Tu ${widget.target} está aquí.');
  }

  void _searchAgain() {
    if (!_detected) return;
    setState(() {
      _detected = false;
      _currentSimilarity = 0;
    });
    _foundController.reset();
    _startScan();
  }

  Future<void> _handleBack() async {
    setState(() => _scanning = false);
    await _audio.stop();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanning = false;
    _sweepController.dispose();
    _foundController.dispose();
    _camera?.dispose();
    _embeddings.dispose();
    _audio.stop();
    super.dispose();
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _handleBack,
          ),
          title: Text(
            'BUSCANDO: ${widget.target.toUpperCase()}',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ),
        body: !widget.savedObject.hasEmbedding
            ? _buildNoEmbeddingBody()
            : _buildScanBody(),
      ),
    );
  }

  // ── Cuerpo principal (con cámara) ────────────────────────────────────────

  Widget _buildScanBody() {
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildCameraLayer(),
        if (_cameraReady && !_detected) _buildRadarOverlay(),
        if (_detected) _buildFoundOverlay(),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: _buildBottomPanel(),
        ),
      ],
    );
  }

  Widget _buildCameraLayer() {
    if (_cameraError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off, color: Colors.white38, size: 64),
            const SizedBox(height: 16),
            Text(
              _cameraError!,
              style: const TextStyle(color: Colors.white54),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }
    if (!_cameraReady || _camera == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white38),
      );
    }
    return CameraPreview(_camera!);
  }

  Widget _buildRadarOverlay() {
    return AnimatedBuilder(
      animation: _sweepController,
      builder: (context, _) => CustomPaint(
        painter: _RadarSweepPainter(progress: _sweepController.value),
      ),
    );
  }

  Widget _buildFoundOverlay() {
    return AnimatedBuilder(
      animation: _foundController,
      builder: (context, _) => IgnorePointer(
        child: Container(
          color: _kAuraGreen.withOpacity(0.18 * _foundController.value),
        ),
      ),
    );
  }

  Widget _buildBottomPanel() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 44),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.92), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_detected) ...[
            _buildSimilarityBar(),
            const SizedBox(height: 14),
            _buildScanningCard(),
          ] else ...[
            _buildFoundCard(),
            const SizedBox(height: 14),
            _buildSearchAgainButton(),
          ],
        ],
      ),
    );
  }

  Widget _buildSimilarityBar() {
    final pct = (_currentSimilarity / _threshold).clamp(0.0, 1.0);
    final color = pct > 0.85 ? _kAuraGreen : _kAuraRed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Similitud con el objeto',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            Text(
              '${(_currentSimilarity * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 7,
            backgroundColor: Colors.white12,
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _buildScanningCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: _kAuraRed,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              !_modelLoaded
                  ? 'Cargando modelo...'
                  : 'Apunta la cámara al objeto.',
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFoundCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _kAuraGreen.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.white, size: 32),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '¡Encontrado! Tu ${widget.target} está aquí.',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Similitud: ${(_currentSimilarity * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchAgainButton() {
    return SizedBox(
      width: double.infinity,
      height: _kMinButtonHeight,
      child: ElevatedButton.icon(
        onPressed: _searchAgain,
        icon: const Icon(Icons.refresh, color: Colors.white),
        label: const Text(
          'BUSCAR DE NUEVO',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _kAuraRed,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
      ),
    );
  }

  // ── Sin embedding ────────────────────────────────────────────────────────

  Widget _buildNoEmbeddingBody() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.image_not_supported,
              color: Colors.white38,
              size: 72,
            ),
            const SizedBox(height: 24),
            Text(
              '"${widget.target}" no tiene imagen guardada.',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'Para buscar este objeto, primero ve a "Mis objetos" '
              'y guárdalo apuntando la cámara hacia él.',
              style: TextStyle(
                color: Colors.white60,
                fontSize: 15,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: _kMinButtonHeight,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).maybePop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kAuraRed,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'VOLVER',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Radar sweep painter ───────────────────────────────────────────────────────

class _RadarSweepPainter extends CustomPainter {
  final double progress;

  _RadarSweepPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _kAuraRed.withOpacity(0.3);
    for (int i = 1; i <= 3; i++) {
      canvas.drawCircle(center, radius * i / 3, ringPaint);
    }
    canvas.drawLine(Offset(center.dx - radius, center.dy),
        Offset(center.dx + radius, center.dy), ringPaint);
    canvas.drawLine(Offset(center.dx, center.dy - radius),
        Offset(center.dx, center.dy + radius), ringPaint);

    final startAngle = progress * 2 * math.pi;
    const sweepAngle = math.pi / 3;
    final sweepPaint = Paint()
      ..shader = SweepGradient(
        startAngle: startAngle,
        endAngle: startAngle + sweepAngle,
        colors: [
          _kAuraRed.withOpacity(0.0),
          _kAuraRed.withOpacity(0.55),
        ],
      ).createShader(rect)
      ..style = PaintingStyle.fill;
    canvas.drawArc(rect, startAngle, sweepAngle, true, sweepPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarSweepPainter old) =>
      old.progress != progress;
}
