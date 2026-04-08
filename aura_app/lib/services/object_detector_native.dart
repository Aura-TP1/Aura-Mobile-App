import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'object_detector_common.dart';

/// Detector de objetos basado en YOLOv8n (TFLite).
class ObjectDetector {
  static const int inputSize = 640;
  static const int _numClasses = 80;
  static const int _numBoxes = 8400;
  static const double _confThreshold = 0.4;
  static const double _iouThreshold = 0.45;

  Interpreter? _interpreter;
  bool _isModelLoaded = false;

  bool get isLoaded => _isModelLoaded;

  Future<void> loadModel() async {
    try {
      debugPrint('Cargando YOLOv8n...');
      _interpreter = await Interpreter.fromAsset(
        'assets/yolov8n_float32.tflite',
        options: InterpreterOptions()..threads = 4,
      );
      _isModelLoaded = true;
      debugPrint('Modelo cargado.');
      debugPrint('  Input : ${_interpreter!.getInputTensors().map((t) => t.shape)}');
      debugPrint('  Output: ${_interpreter!.getOutputTensors().map((t) => t.shape)}');
    } catch (e, st) {
      debugPrint('Error cargando modelo: $e\n$st');
      _isModelLoaded = false;
    }
  }

  Future<List<Detection>> detect(img.Image image) async {
    if (!_isModelLoaded || _interpreter == null) return const [];

    final resized = img.copyResize(image, width: inputSize, height: inputSize);

    final input = List.generate(
      1,
      (_) => List.generate(
        inputSize,
        (y) => List.generate(inputSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        }),
      ),
    );

    final output = List.generate(
      1,
      (_) => List.generate(84, (_) => List.filled(_numBoxes, 0.0)),
    );

    _interpreter!.run(input, output);

    return _parseOutput(output[0]);
  }

  List<Detection> _parseOutput(List<List<double>> out) {
    final detections = <Detection>[];

    for (int i = 0; i < _numBoxes; i++) {
      double maxConf = 0;
      int classId = 0;
      for (int c = 0; c < _numClasses; c++) {
        final v = out[4 + c][i];
        if (v > maxConf) {
          maxConf = v;
          classId = c;
        }
      }

      if (maxConf < _confThreshold) continue;

      double cx = out[0][i];
      double cy = out[1][i];
      double w = out[2][i];
      double h = out[3][i];
      if (cx > 1.5 || cy > 1.5 || w > 1.5 || h > 1.5) {
        cx /= inputSize;
        cy /= inputSize;
        w /= inputSize;
        h /= inputSize;
      }

      detections.add(
        Detection(
          label: classId < cocoLabels.length ? cocoLabels[classId] : 'clase_$classId',
          confidence: maxConf,
          rect: Rect.fromLTWH(cx - w / 2, cy - h / 2, w, h),
        ),
      );
    }

    return _nms(detections, _iouThreshold);
  }

  List<Detection> _nms(List<Detection> dets, double iouThresh) {
    if (dets.isEmpty) return dets;
    dets.sort((a, b) => b.confidence.compareTo(a.confidence));
    final keep = <Detection>[];
    final suppressed = List<bool>.filled(dets.length, false);

    for (int i = 0; i < dets.length; i++) {
      if (suppressed[i]) continue;
      keep.add(dets[i]);
      for (int j = i + 1; j < dets.length; j++) {
        if (suppressed[j]) continue;
        if (dets[i].label == dets[j].label &&
            _iou(dets[i].rect, dets[j].rect) > iouThresh) {
          suppressed[j] = true;
        }
      }
    }
    return keep;
  }

  double _iou(Rect a, Rect b) {
    final x1 = math.max(a.left, b.left);
    final y1 = math.max(a.top, b.top);
    final x2 = math.min(a.right, b.right);
    final y2 = math.min(a.bottom, b.bottom);
    final inter = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
    final union = a.width * a.height + b.width * b.height - inter;
    if (union <= 0) return 0;
    return inter / union;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isModelLoaded = false;
  }
}
