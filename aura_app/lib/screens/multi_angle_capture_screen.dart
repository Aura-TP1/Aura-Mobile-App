import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/saved_object.dart';
import '../services/app_settings.dart';
import '../services/detection_crop.dart';
import '../services/embedding_service.dart';
import '../services/metrics_logger.dart';
import '../services/object_detector.dart';
import '../services/stt_service.dart';
import '../services/tts.dart';

const Color _kAuraRed = Color(0xFFE53935);

/// Define los ángulos a capturar
enum CaptureAngle {
  frontal('Frontal', 'Mira directamente al objeto'),
  izquierda('Izquierda', 'Gira la cámara hacia la izquierda'),
  derecha('Derecha', 'Gira la cámara hacia la derecha'),
  arriba('Arriba', 'Inclina la cámara hacia arriba'),
  abajo('Abajo', 'Inclina la cámara hacia abajo');

  final String label;
  final String instruction;

  const CaptureAngle(this.label, this.instruction);
}

/// Pantalla para capturar múltiples imágenes de un objeto desde diferentes ángulos.
class MultiAngleCaptureScreen extends StatefulWidget {
  final String objectName;

  const MultiAngleCaptureScreen({
    required this.objectName,
    super.key,
  });

  @override
  State<MultiAngleCaptureScreen> createState() =>
      _MultiAngleCaptureScreenState();
}

class _MultiAngleCaptureScreenState extends State<MultiAngleCaptureScreen> {
  final AudioFeedback _audio = AudioFeedback();
  final EmbeddingService _embeddings =
      EmbeddingService(useInt8: AppSettings.instance.useEmbeddingInt8);
  final ObjectDetector _detector =
      ObjectDetector(useInt8: AppSettings.instance.useYoloInt8);

  CameraController? _camera;
  bool _cameraReady = false;
  String? _cameraError;
  bool _modelLoaded = false;

  // Captura
  int _currentAngleIndex = 0;
  final Map<CaptureAngle, List<double>> _capturedEmbeddings = {};
  final Map<CaptureAngle, String> _angleLabels = {};
  bool _isCapturing = false;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _audio.init();
    await _audio.speak(
        'Captura de múltiples ángulos. Prepárate para tomar fotos desde diferentes posiciones.');
    await _initCamera();
    await _embeddings.loadModel();
    await _detector.loadModel();
    if (mounted) setState(() => _modelLoaded = _embeddings.isLoaded);
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
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    _embeddings.dispose();
    _detector.dispose();
    _audio.stop();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _captureCurrentAngle() async {
    if (_isCapturing || !_cameraReady || _camera == null) return;

    setState(() => _isCapturing = true);
    final angle = CaptureAngle.values[_currentAngleIndex];

    try {
      await _audio.speak('Capturando. Mantén firme.');
      await Future.delayed(const Duration(milliseconds: 500));

      final xfile = await _camera!.takePicture();
      final bytes = await xfile.readAsBytes();
      final decoded = img.decodeImage(bytes);

      if (decoded == null) {
        await _audio.speak('Error al capturar. Intenta de nuevo.');
        return;
      }

      setState(() => _isProcessing = true);

      // Recortar en vez de usar el frame completo: el embedding de cada
      // ángulo debe describir el objeto, no el fondo alrededor de él. Usa
      // kCropConfThreshold (bajo, solo localización) — varios objetos de
      // prueba no son clases COCO y casi nunca cruzan el umbral de
      // detección en vivo (0.4). Si ni con el umbral bajo hay nada, recorte
      // central en vez de imagen entera.
      var toEmbed = decoded;
      String cropMethod;
      int? cropClassId;
      String? cropLabel;
      double? cropConfidence;
      String? cropFallbackReason;
      double? discardedBoxWidth;
      double? discardedBoxHeight;
      if (_detector.isLoaded) {
        final detections =
            await _detector.detect(decoded, confThreshold: kCropConfThreshold);
        final best = bestCropCandidate(detections);
        if (best != null) {
          toEmbed = cropToDetection(decoded, best);
          cropMethod = 'yolo_detection';
          cropClassId = cocoLabels.indexOf(best.label);
          cropLabel = best.label;
          cropConfidence = best.confidence;
        } else {
          toEmbed = centerCrop(decoded);
          cropMethod = 'center_crop_fallback';
          if (detections.isEmpty) {
            cropFallbackReason = 'no_detection';
          } else {
            cropFallbackReason = 'box_too_small';
            final discarded = highestConfidence(detections);
            discardedBoxWidth = discarded?.rect.width;
            discardedBoxHeight = discarded?.rect.height;
          }
          debugPrint('[multi_angle] Sin detección ≥$kCropConfThreshold en $angle; usando center-crop como fallback ($cropFallbackReason).');
        }
      } else {
        cropMethod = 'full_frame_no_model';
        debugPrint('[multi_angle] Detector YOLO no cargado; usando imagen completa como fallback.');
      }

      // ignore: discarded_futures
      MetricsLogger.instance.logCropSelection(
        screen: 'multi_angle_capture',
        objectLabel: '${widget.objectName} (${angle.label})',
        cropMethod: cropMethod,
        detectionClassId: cropClassId,
        detectionLabel: cropLabel,
        detectionConfidence: cropConfidence,
        cropFallbackReason: cropFallbackReason,
        discardedBoxWidth: discardedBoxWidth,
        discardedBoxHeight: discardedBoxHeight,
      );

      final embedding = await _embeddings.extractEmbedding(toEmbed);

      if (mounted) {
        setState(() {
          _capturedEmbeddings[angle] = embedding;
          _angleLabels[angle] = angle.label;
          _isProcessing = false;
        });

        await _audio.speak('${angle.label} capturada exitosamente.');

        // Automáticamente ir al siguiente ángulo si hay más
        if (_currentAngleIndex < CaptureAngle.values.length - 1) {
          await Future.delayed(const Duration(seconds: 2));
          if (mounted) _moveToNextAngle();
        }
      }
    } catch (e) {
      debugPrint('Error capturando: $e');
      if (mounted) {
        setState(() => _isProcessing = false);
        await _audio.speak('Error al capturar. Intenta de nuevo.');
      }
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  void _moveToNextAngle() {
    if (_currentAngleIndex < CaptureAngle.values.length - 1) {
      setState(() => _currentAngleIndex++);
      final nextAngle = CaptureAngle.values[_currentAngleIndex];
      _audio.speak('Siguiente: ${nextAngle.instruction}');
    }
  }

  void _moveToPreviousAngle() {
    if (_currentAngleIndex > 0) {
      setState(() => _currentAngleIndex--);
      final prevAngle = CaptureAngle.values[_currentAngleIndex];
      _audio.speak('Anterior: ${prevAngle.instruction}');
    }
  }

  Future<void> _finishCapture() async {
    if (_capturedEmbeddings.isEmpty) {
      await _audio.speak('Debes capturar al menos una imagen.');
      return;
    }

    if (mounted) {
      Navigator.pop(context, _capturedEmbeddings);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black87,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Volver',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'CAPTURA MULTI-ÁNGULO',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Instrucción y progreso
            _buildProgressArea(),

            // Cámara preview
            Expanded(
              child: _buildCameraArea(),
            ),

            // Controles
            _buildControlsArea(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressArea() {
    final angle = CaptureAngle.values[_currentAngleIndex];
    final progress = _currentAngleIndex + 1;
    final total = CaptureAngle.values.length;
    final isAlreadyCaptured = _capturedEmbeddings.containsKey(angle);

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Barra de progreso
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: progress / total,
              minHeight: 8,
              backgroundColor: Colors.grey.shade700,
              valueColor: AlwaysStoppedAnimation<Color>(
                isAlreadyCaptured ? Colors.green : _kAuraRed,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Instrucción
          Text(
            angle.instruction,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),

          // Estado
          Row(
            children: [
              Icon(
                isAlreadyCaptured ? Icons.check_circle : Icons.radio_button_unchecked,
                color: isAlreadyCaptured ? Colors.green : _kAuraRed,
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                '$progress / $total - ${angle.label}${isAlreadyCaptured ? ' ✓' : ''}',
                style: TextStyle(
                  color: isAlreadyCaptured ? Colors.green : Colors.white70,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCameraArea() {
    if (_cameraError != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Text(
            _cameraError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    if (!_cameraReady || _camera == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(_kAuraRed),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_camera!),
        if (_isProcessing)
          Container(
            color: Colors.black.withOpacity(0.6),
            child: const Center(
              child: CircularProgressIndicator(
                valueColor: AlwaysStoppedAnimation<Color>(_kAuraRed),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildControlsArea() {
    final angle = CaptureAngle.values[_currentAngleIndex];
    final isAlreadyCaptured = _capturedEmbeddings.containsKey(angle);
    final canFinish = _capturedEmbeddings.isNotEmpty;

    return Container(
      color: Colors.black,
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Botones de navegación
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: Semantics(
                    button: true,
                    label: 'Ángulo anterior',
                    child: OutlinedButton(
                      onPressed: _currentAngleIndex > 0 ? _moveToPreviousAngle : null,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: _kAuraRed),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Icon(Icons.arrow_back, color: _kAuraRed),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isCapturing || _isProcessing ? null : _captureCurrentAngle,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isAlreadyCaptured ? Colors.green : _kAuraRed,
                      disabledBackgroundColor: Colors.grey.shade600,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text(
                      _isCapturing || _isProcessing
                          ? 'CAPTURANDO...'
                          : isAlreadyCaptured
                              ? 'RECAPTURAR'
                              : 'CAPTURAR',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 52,
                  child: Semantics(
                    button: true,
                    label: 'Ángulo siguiente',
                    child: OutlinedButton(
                      onPressed: _currentAngleIndex < CaptureAngle.values.length - 1
                          ? _moveToNextAngle
                          : null,
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: _kAuraRed),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Icon(Icons.arrow_forward, color: _kAuraRed),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Botón de finalizar
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: canFinish && !_isCapturing && !_isProcessing
                  ? _finishCapture
                  : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                disabledBackgroundColor: Colors.grey.shade600,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: Text(
                'FINALIZAR (${_capturedEmbeddings.length}/${CaptureAngle.values.length})',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

