import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import 'object_detector_common.dart';

/// Detector de objetos basado en YOLOv8n (TFLite).
class ObjectDetector {
  // Verificado contra el log del modelo: Input [1,320,320,3], Output [1,84,2100]
  static const int inputSize = 320;
  static const int _numClasses = 80;
  static const int _numBoxes = 2100;
  static const int _numFeatures = 84; // 4 coords (cx,cy,w,h) + 80 clases
  static const double _confThreshold = 0.4;
  static const double _iouThreshold = 0.45;

  /// Si es `true`, carga `assets/yolov8n_int8.tflite` (pesos cuantizados a
  /// INT8, ~3.3MB) en vez del float32 por defecto (~12.7MB). A diferencia
  /// del embedding INT8 de MobileNetV2, este modelo mantiene entrada Y
  /// salida en float32 (verificado con el intérprete: input [1,320,320,3]
  /// float32, output [1,84,2100] float32, igual que el modelo float32) —
  /// es cuantización "full-integer con I/O float", así que NO requiere
  /// dequantización: el mismo pipeline Float32List/_parseOutput de abajo
  /// sirve sin cambios para ambos modelos.
  final bool useInt8;

  ObjectDetector({this.useInt8 = false});

  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;
  bool _isModelLoaded = false;

  // Buffers de entrada/salida pre-allocados y reutilizados en cada frame.
  // Usar Float32List en vez de List<List<List<double>>> evita crear
  // decenas de miles de objetos Dart por frame (y su copia profunda al
  // enviarlos al isolate de inferencia), lo cual es clave para que la
  // detección funcione sin saturar la memoria en celulares de 4 GB de RAM.
  final Float32List _inputBuffer = Float32List(inputSize * inputSize * 3);
  final Float32List _outputBuffer = Float32List(_numFeatures * _numBoxes);

  bool get isLoaded => _isModelLoaded;

  Future<void> loadModel() async {
    final assetPath =
        useInt8 ? 'assets/yolov8n_int8.tflite' : 'assets/yolov8n_float32.tflite';
    try {
      debugPrint('Cargando YOLOv8n ($assetPath)...');
      _interpreter = await Interpreter.fromAsset(
        assetPath,
        // 2 hilos: en equipos de gama baja con 4 GB de RAM (típicamente
        // 4-8 núcleos compartidos con la UI), usar más hilos compite con
        // el hilo principal y no acelera la inferencia de forma notable.
        options: InterpreterOptions()..threads = 2,
      );
      _isModelLoaded = true;
      debugPrint('Modelo cargado.');
      debugPrint('  Input : ${_interpreter!.getInputTensors().map((t) => t.shape)}');
      debugPrint('  Output: ${_interpreter!.getOutputTensors().map((t) => t.shape)}');

      // Mover inferencia al background isolate para no bloquear la UI.
      try {
        _isolateInterpreter = await IsolateInterpreter.create(
          address: _interpreter!.address,
        );
        debugPrint('IsolateInterpreter creado — inferencia en background.');
      } catch (e) {
        debugPrint('IsolateInterpreter no disponible, usando main thread: $e');
      }
    } catch (e, st) {
      debugPrint('Error cargando modelo: $e\n$st');
      _isModelLoaded = false;
    }
  }

  /// [confThreshold] permite sobreescribir el umbral de confianza por
  /// llamada (p.ej. un umbral más bajo solo para elegir un recorte antes de
  /// extraer un embedding, sin afectar la detección en vivo). Si se omite,
  /// usa el umbral por defecto ([_confThreshold] = 0.4), igual que antes —
  /// las llamadas existentes sin este parámetro no cambian de comportamiento.
  Future<List<Detection>> detect(img.Image image, {double? confThreshold}) async {
    if (!_isModelLoaded || _interpreter == null) return const [];

    final resized = img.copyResize(image, width: inputSize, height: inputSize);

    // Lectura directa de los bytes RGB del buffer redimensionado: evita
    // ~100k llamadas a getPixel() (y sus objetos Pixel) por frame.
    final bytes = resized.getBytes(order: img.ChannelOrder.rgb);
    for (int i = 0; i < bytes.length; i++) {
      _inputBuffer[i] = bytes[i] / 255.0;
    }

    // Output real del modelo: [1, 84, 2100] — feature-first (transpuesto).
    // Cada columna i es un box; filas 0-3 son cx/cy/w/h, filas 4-83 son scores.
    if (_isolateInterpreter != null) {
      // Inferencia en background isolate → no bloquea el hilo principal.
      await _isolateInterpreter!.run(_inputBuffer.buffer, _outputBuffer.buffer);
    } else {
      _interpreter!.run(_inputBuffer.buffer, _outputBuffer.buffer);
    }

    return _parseOutput(_outputBuffer, confThreshold ?? _confThreshold);
  }

  // out es un Float32List plano de tamaño [84 * 2100]: out[feature * 2100 + box].
  // Filas 0-3: cx, cy, w, h en píxeles del espacio 320×320.
  // Filas 4-83: score de cada clase COCO.
  List<Detection> _parseOutput(Float32List out, double confThreshold) {
    final detections = <Detection>[];

    for (int i = 0; i < _numBoxes; i++) {
      double maxConf = 0;
      int classId = 0;
      for (int c = 0; c < _numClasses; c++) {
        final v = out[(4 + c) * _numBoxes + i];
        if (v > maxConf) {
          maxConf = v;
          classId = c;
        }
      }

      if (maxConf < confThreshold) continue;

      // Coordenadas en píxeles del espacio del modelo → normalizar a [0, 1].
      final cx = out[0 * _numBoxes + i] / inputSize;
      final cy = out[1 * _numBoxes + i] / inputSize;
      final w  = out[2 * _numBoxes + i] / inputSize;
      final h  = out[3 * _numBoxes + i] / inputSize;

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
        if (_iou(dets[i].rect, dets[j].rect) > iouThresh) {
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
    _isolateInterpreter?.close();
    _isolateInterpreter = null;
    _interpreter?.close();
    _interpreter = null;
    _isModelLoaded = false;
  }
}
