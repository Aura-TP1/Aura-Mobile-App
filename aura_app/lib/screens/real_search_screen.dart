import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:vibration/vibration.dart';

import '../models/saved_object.dart';
import '../services/detection_crop.dart';
import '../services/embedding_service.dart';
import '../services/embedding_service_common.dart';
import '../services/tts.dart';
import '../services/app_settings.dart';
import '../services/metrics_logger.dart';
import '../services/saved_objects_repository.dart';
import '../theme/aura_colors.dart';

const Color _kAuraRed = AuraColors.red;
const Color _kAuraGreen = AuraColors.foundGreen;
const double _kMinButtonHeight = kAuraMinButtonHeight;

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
  final EmbeddingService _embeddings =
      EmbeddingService(useInt8: AppSettings.instance.useEmbeddingInt8);
  final AudioFeedback _audio = AudioFeedback();
  final SavedObjectsRepository _savedObjectsRepo = SavedObjectsRepository();

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

  /// Intervalo entre cuadros analizados. Ajustable en Ajustes (WCAG 2.2.1);
  /// 300 ms por defecto.
  Duration get _frameInterval => AppSettings.instance.scanInterval;

  /// Umbral base de match confirmado. NO se modifica (requisito).
  static const double _threshold = 0.75;

  /// Umbral inferior de "duda": entre [_kMaybeThreshold] y [_threshold] avisamos
  /// al usuario que creemos verlo pero sin confirmar.
  static const double _kMaybeThreshold = 0.70;

  /// Cooldown del aviso de duda para no repetirlo cada frame.
  DateTime _lastMaybeAt = DateTime.fromMillisecondsSinceEpoch(0);

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

    // Fire-and-forget: antes esto era `await`, así que la cámara ni
    // empezaba a inicializar hasta que el TTS terminaba de hablar la
    // frase completa — mismo bug que en save_object_screen.dart, la
    // cámara se veía en gris mucho más de lo necesario.
    unawaited(_audio.speak(
      'Buscando ${widget.target}. Apunta la cámara al objeto.',
    ));

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
      // Sin esto, algunos Android disparan el flash automático en poca luz al
      // llamar takePicture() — el plugin no fija FlashMode por defecto. En
      // esta pantalla el bucle de escaneo llama takePicture varias veces por
      // segundo, así que el flash se prendía solo mientras el usuario
      // buscaba. Mismo bloque que en camera_detection_view.dart.
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (e) {
        debugPrint('No se pudo forzar flash apagado: $e');
      }
      // La orientación de captura tiene que quedar fija para que el recorte
      // del marco guía corresponda a lo que se ve en pantalla, igual que al
      // guardar (ver save_object_screen.dart).
      try {
        await controller.lockCaptureOrientation();
      } catch (e) {
        debugPrint('No se pudo fijar la orientación de captura: $e');
      }
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
    // YOLO ya no se carga acá: dejó de elegir el recorte (ahora es el marco
    // guía, igual que al guardar) y era el modelo más pesado de los dos.
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
        // Solo para métricas: mide la latencia de este ciclo de escaneo
        // (captura + embedding + comparación) de forma aditiva, sin alterar
        // el flujo ni el timing real del loop.
        final metricsStopwatch = Stopwatch()..start();

        final xfile = await c.takePicture();
        final bytes = await xfile.readAsBytes();
        final image = img.decodeImage(bytes);
        if (image == null) {
          await Future.delayed(_frameInterval);
          continue;
        }

        // EXACTAMENTE el mismo recorte que se usa al guardar
        // (`save_object_screen.dart` → `_captureEmbedding`). Antes esta
        // pantalla recortaba con el bbox de YOLO y caía a `centerCrop` si no
        // había detección, mientras que el guardado ya recortaba al marco
        // guía: se estaba comparando el recorte ajustado del objeto contra
        // un recorte del teclado/la mesa, y la similitud coseno se hundía
        // sin que el objeto hubiera cambiado. Comparar "mismo tipo de
        // recorte contra mismo tipo de recorte" es lo que hace que el número
        // de la Tabla II signifique algo.
        var toEmbed = cropToGuideSquare(image);
        var cropMethod = 'guide_frame';
        if (AppSettings.instance.useWatershedSegmentation) {
          final segmented = segmentForeground(toEmbed);
          if (segmented != null) {
            toEmbed = segmented;
            cropMethod = 'watershed_segmentation';
          }
        }

        // Mismo preprocesamiento que al guardar (ver detection_crop.dart):
        // sin esto, comparar una foto guardada con una luz contra una
        // buscada con otra luz mete ruido adicional al embedding.
        final frameEmb = await _embeddings.extractEmbedding(normalizeForEmbedding(toEmbed));
        if (frameEmb.isEmpty) {
          await Future.delayed(_frameInterval);
          continue;
        }

        // Compara contra TODOS los embeddings disponibles (múltiples ángulos)
        double bestSim = 0.0;
        
        // Primero intenta con los embeddings nuevos (múltiples ángulos)
        if (widget.savedObject.embeddings.isNotEmpty) {
          for (final objEmb in widget.savedObject.embeddings) {
            final sim = cosineSimilarity(objEmb.embedding, frameEmb);
            if (sim > bestSim) {
              bestSim = sim;
            }
          }
        }
        
        // Si no hay embeddings nuevos, usa el embedding legacy
        if (bestSim == 0.0 && widget.savedObject.embedding.isNotEmpty) {
          bestSim = cosineSimilarity(widget.savedObject.embedding, frameEmb);
        }

        if (!mounted || _disposed) return;
        setState(() => _currentSimilarity = bestSim);

        final decision = bestSim >= _threshold
            ? 'found'
            : (bestSim >= _kMaybeThreshold ? 'maybe' : 'none');

        // Solo para métricas: similitud contra TODOS los objetos guardados,
        // para detectar falsos positivos (otro objeto con mayor similitud
        // que el objetivo). No afecta la decisión de match, que sigue
        // basándose solo en widget.savedObject. Fire-and-forget: no se
        // espera el resultado para no retrasar el siguiente frame.
        // ignore: discarded_futures
        _logSearchMetrics(
          frameEmb: frameEmb,
          bestSim: bestSim,
          decision: decision,
          stopwatch: metricsStopwatch,
          cropMethod: cropMethod,
        );

        if (bestSim >= _threshold) {
          await _onFound();
          return;
        } else if (bestSim >= _kMaybeThreshold) {
          _announceMaybe();
        }
      } catch (e) {
        debugPrint('RealSearchScreen scan error: $e');
      }

      await Future.delayed(_frameInterval);
    }
  }

  /// Solo para métricas (instrumentación pura, no afecta el flujo de
  /// búsqueda real). Calcula la similitud del frame actual contra TODOS los
  /// objetos guardados (para detectar falsos positivos por confusión con
  /// otro objeto) y registra el intento de búsqueda en
  /// `search_metrics.jsonl` vía [MetricsLogger]. Nunca lanza excepciones.
  Future<void> _logSearchMetrics({
    required List<double> frameEmb,
    required double bestSim,
    required String decision,
    required Stopwatch stopwatch,
    required String cropMethod,
    int? cropClassId,
    String? cropLabel,
    double? cropConfidence,
    String? cropFallbackReason,
    double? discardedBoxWidth,
    double? discardedBoxHeight,
  }) async {
    try {
      final allSavedObjects = await _savedObjectsRepo.getAll();
      final Map<String, double> allSims = {};
      for (final obj in allSavedObjects) {
        double s = 0.0;
        for (final e in obj.embeddings) {
          final v = cosineSimilarity(e.embedding, frameEmb);
          if (v > s) s = v;
        }
        if (s == 0.0 && obj.embedding.isNotEmpty) {
          s = cosineSimilarity(obj.embedding, frameEmb);
        }
        allSims[obj.id.toString()] = s;
      }

      stopwatch.stop();

      await MetricsLogger.instance.logSearchAttempt(
        targetObjectId: widget.savedObject.id.toString(),
        targetObjectName: widget.savedObject.name,
        targetSimilarity: bestSim,
        decision: decision,
        latencyMs: stopwatch.elapsedMilliseconds,
        storedObjectCount: allSavedObjects.length,
        allObjectSimilarities: allSims,
        cropMethod: cropMethod,
        cropDetectionClassId: cropClassId,
        cropDetectionLabel: cropLabel,
        cropDetectionConfidence: cropConfidence,
        cropFallbackReason: cropFallbackReason,
        discardedBoxWidth: discardedBoxWidth,
        discardedBoxHeight: discardedBoxHeight,
      );
    } catch (e) {
      debugPrint('RealSearchScreen metrics logging error: $e');
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

    final hasVibrator = (await Vibration.hasVibrator()) == true;
    if (hasVibrator) {
      // Vibración larga (500 ms) al confirmar el match (spec).
      await Vibration.vibrate(duration: 500);
    }

    await _audio.speak('¡Encontrado! Tu ${widget.target} está aquí.');
  }

  /// Aviso de "duda" cuando la similitud cae entre 0.70 y 0.75: creemos ver
  /// el objeto pero sin confirmarlo. Respeta un cooldown para no repetir.
  void _announceMaybe() {
    final now = DateTime.now();
    if (now.difference(_lastMaybeAt) < const Duration(seconds: 4)) return;
    _lastMaybeAt = now;
    _audio.speak('Creo que veo tu ${widget.target}, pero no estoy seguro.');
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
    setState(() {
      _scanning = false;
      _detected = false;
    });
    // No esperar el stop() antes de navegar: con awaitSpeakCompletion(true)
    // en tts.dart, si hay una locución larga en curso, stop() puede tardar
    // varios segundos en resolver — el botón "volver" se sentía trabado.
    // Fire-and-forget: el audio se corta igual, pero no bloquea el pop.
    unawaited(_audio.stop());
    Navigator.of(context).pop();
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
    _audio.dispose();
    super.dispose();
  }

  // ── UI ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        // canPop:false intercepta el botón físico de atrás (Android) para
        // detener el escaneo antes de salir.
        final nav = Navigator.of(context);
        setState(() { _scanning = false; _detected = false; });
        await _audio.stop();
        nav.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            tooltip: 'Volver',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
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
        if (_cameraReady && !_detected) _buildGuideFrame(),
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

  /// Mismo marco guía cuadrado que en la pantalla de guardar. El recorte que
  /// se compara es exactamente esta región (ver `cropToGuideSquare`), así que
  /// el usuario tiene que apuntar igual que cuando guardó el objeto — sin el
  /// marco visible no hay forma de que sepa qué parte del encuadre cuenta.
  Widget _buildGuideFrame() {
    return IgnorePointer(
      child: Center(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final side = kGuideFrameFraction *
                math.min(constraints.maxWidth, constraints.maxHeight);
            return Semantics(
              label: 'Marco guía: apunta al objeto dentro de este recuadro',
              child: SizedBox(
                width: side,
                height: side,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.white70, width: 3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
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
    final isClose = pct > 0.85;
    final color = isClose ? _kAuraGreen : _kAuraRed;
    final pctInt = (_currentSimilarity * 100).toStringAsFixed(0);
    // No dependemos solo del color: agregamos texto/ícono de estado
    // (WCAG 1.4.1) además de la etiqueta accesible (WCAG 4.1.2).
    final stateLabel = isClose ? 'Cerca' : 'Buscando';
    return Semantics(
      label: 'Similitud: $pctInt%, $stateLabel',
      value: '$pctInt%',
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isClose ? Icons.trending_up : Icons.search,
                      color: Colors.white60,
                      size: 14,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        'Similitud con el objeto ($stateLabel)',
                        style: const TextStyle(color: Colors.white60, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '$pctInt%',
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
      ),
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
