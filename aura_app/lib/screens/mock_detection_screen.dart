import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/tts.dart';

const Color _kAuraRed = Color(0xFFE53935);
const Color _kAuraGreen = Color(0xFF2E7D32);
const double _kMinButtonHeight = 64;

/// Pantalla de detección simulada (sin cámara ni TFLite).
///
/// Muestra un placeholder con barrido de radar durante 3 s y luego "encuentra"
/// el objeto indicado. Todo anunciado con TTS.
class MockDetectionScreen extends StatefulWidget {
  final String target;
  const MockDetectionScreen({super.key, required this.target});

  @override
  State<MockDetectionScreen> createState() => _MockDetectionScreenState();
}

class _MockDetectionScreenState extends State<MockDetectionScreen>
    with TickerProviderStateMixin {
  final AudioFeedback _audio = AudioFeedback();

  late final AnimationController _sweepController;
  late final AnimationController _foundController;
  Timer? _detectionTimer;

  bool _detected = false;

  static const Duration _scanDuration = Duration(seconds: 3);

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
    _audio.init().then((_) => _startCycle());
  }

  @override
  void dispose() {
    _detectionTimer?.cancel();
    _sweepController.dispose();
    _foundController.dispose();
    _audio.stop();
    super.dispose();
  }

  void _startCycle() {
    setState(() => _detected = false);
    _foundController.reset();
    _sweepController.repeat();
    _audio.speak('Escaneando. Estoy buscando tus ${widget.target}.');
    _detectionTimer?.cancel();
    _detectionTimer = Timer(_scanDuration, _onDetected);
  }

  Future<void> _onDetected() async {
    if (!mounted) return;
    setState(() => _detected = true);
    _sweepController.stop();
    _foundController.forward();
    await _audio.speak(
      'Encontré tus ${widget.target}. Está al centro, cerca de ti.',
    );
  }

  void _searchAgain() {
    _startCycle();
  }

  Future<void> _handleBack() async {
    await _audio.stop();
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        await _audio.stop();
        return true;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFFAFAFA),
        appBar: AppBar(
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.black),
            onPressed: _handleBack,
          ),
          title: Text(
            'BUSCANDO: ${widget.target.toUpperCase()}',
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const SizedBox(height: 16),
                Expanded(child: _buildScannerArea()),
                const SizedBox(height: 20),
                _buildStatusCard(),
                const SizedBox(height: 20),
                _buildSearchAgainButton(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildScannerArea() {
    return Center(
      child: AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = math.min(constraints.maxWidth, constraints.maxHeight);
            return SizedBox(
              width: size,
              height: size,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Placeholder de cámara (fondo gris con icono).
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.grey.shade300,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: _detected ? _kAuraGreen : _kAuraRed,
                        width: 4,
                      ),
                    ),
                    child: Center(
                      child: Icon(
                        _detected ? Icons.check_circle : Icons.videocam_off,
                        size: size * 0.25,
                        color: _detected
                            ? _kAuraGreen
                            : Colors.grey.shade600,
                      ),
                    ),
                  ),
                  // Barrido de radar mientras no se detecta.
                  if (!_detected)
                    AnimatedBuilder(
                      animation: _sweepController,
                      builder: (context, _) {
                        return CustomPaint(
                          size: Size(size, size),
                          painter: _RadarSweepPainter(
                            progress: _sweepController.value,
                          ),
                        );
                      },
                    ),
                  // Highlight verde animado al detectar.
                  if (_detected)
                    AnimatedBuilder(
                      animation: _foundController,
                      builder: (context, _) {
                        final t = _foundController.value;
                        return IgnorePointer(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: _kAuraGreen.withOpacity(0.4 * (1 - t)),
                                  blurRadius: 40 + t * 40,
                                  spreadRadius: 10 + t * 20,
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStatusCard() {
    if (!_detected) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: _kAuraRed, width: 2),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: _kAuraRed,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                'Escaneando el entorno para encontrar tus ${widget.target}...',
                style: const TextStyle(fontSize: 16, color: Colors.black87),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _kAuraGreen.withOpacity(0.08),
        border: Border.all(color: _kAuraGreen, width: 2.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: const BoxDecoration(
              color: _kAuraGreen,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check, color: Colors.white, size: 28),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '¡Encontré tus ${widget.target}!',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: _kAuraGreen,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Al centro, cerca de ti',
                  style: TextStyle(fontSize: 14, color: Colors.black87),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: _kAuraGreen,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              '94%',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
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
}

/// Pinta un barrido de radar (arco con gradiente que rota).
class _RadarSweepPainter extends CustomPainter {
  final double progress; // 0..1

  _RadarSweepPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Líneas concéntricas del radar.
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = _kAuraRed.withOpacity(0.25);
    for (int i = 1; i <= 3; i++) {
      canvas.drawCircle(center, radius * i / 3, ringPaint);
    }

    // Cruz central.
    canvas.drawLine(
      Offset(center.dx - radius, center.dy),
      Offset(center.dx + radius, center.dy),
      ringPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius),
      Offset(center.dx, center.dy + radius),
      ringPaint,
    );

    // Barrido (arco con gradiente).
    final startAngle = progress * 2 * math.pi;
    const sweepAngle = math.pi / 3; // 60°
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
