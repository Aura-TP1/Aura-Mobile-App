// Evaluador offline de detección (mAP@0.5, precisión, recall) para el
// modelo YOLOv8n usado por AURA.
//
// POR QUÉ ESTO NO ES UN SCRIPT STANDALONE (`dart run tool/evaluate_detector.dart`):
// `tflite_flutter` carga el intérprete de TFLite vía un binding FFI a una
// librería nativa (`libtensorflowlite_c.*`) que el plugin empaqueta y
// resuelve *dentro* del proceso de una app Flutter en ejecución (Android/
// iOS/desktop embebido por Flutter). Un script Dart puro ejecutado con
// `dart run` fuera de un `flutter run`/`flutter test` no tiene ese binario
// nativo disponible ni el registro de plugins que resuelve su ruta — por
// lo tanto `Interpreter.fromFile`/`Interpreter.fromAsset` fallarían al
// cargar la librería nativa en ese contexto. Por eso esta evaluación se
// implementó como una utilidad *dentro* de la app (llamable desde un botón
// de depuración o desde un test de integración de Flutter), no como un
// script Dart standalone.
//
// CÓMO EJECUTARLA:
//   Opción A (recomendada para uso puntual): agregar temporalmente un botón
//   de depuración en alguna pantalla (ej. Ajustes) que llame a
//   `evaluateDetector(...)` y muestre el resultado / lo escriba a disco.
//   Opción B: crear un test de integración
//   `integration_test/evaluate_detector_test.dart` que llame a
//   `evaluateDetector(...)` con rutas fijas y corra con
//   `flutter test integration_test/evaluate_detector_test.dart -d <device>`.
//
// FORMATO DE ANOTACIONES DE GROUND TRUTH (--annotationsPath):
// Se aceptan DOS formatos:
//
// 1) Un único archivo JSON con esta forma (coordenadas normalizadas [0,1],
//    mismo convenio que `Detection.rect`; classId = índice en `cocoLabels`
//    de `object_detector_common.dart`, orden oficial de YOLOv8):
//    {
//      "images": [
//        {
//          "file": "img001.jpg",
//          "boxes": [
//            {"classId": 16, "label": "perro", "x": 0.12, "y": 0.30, "w": 0.25, "h": 0.40}
//          ]
//        }
//      ]
//    }
//
// 2) Un directorio con un archivo .txt por imagen en formato YOLO/darknet
//    (`<mismo_nombre_que_la_imagen>.txt`, una línea por caja:
//    `classId cx cy w h`, todo normalizado [0,1], cx/cy = centro).
//
// La carpeta de imágenes (--imagesDir) debe contener los .jpg/.png
// referenciados por las anotaciones.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../object_detector_common.dart';

// ── Parámetros del modelo — DEBEN coincidir byte-a-byte con
// `lib/services/object_detector_native.dart` para que la evaluación
// refleje el detector real de la app. NO modificar sin actualizar también
// el detector en vivo. ──────────────────────────────────────────────────
const int _inputSize = 320;
const int _numClasses = 80;
const int _numBoxes = 2100;
const int _numFeatures = 84;
const double _confThreshold = 0.4;
const double _iouThreshold = 0.45; // NMS
const double _mapIouThreshold = 0.5; // matching de evaluación (mAP@0.5)

/// Subconjunto de clases COCO (en español, como en `cocoLabels`) plausibles
/// para el caso de uso de AURA (objetos personales domésticos), reportado
/// aparte como `householdRelevantSummary`.
const List<String> _householdRelevantLabels = [
  'mochila', // backpack
  'paraguas', // umbrella
  'bolso', // handbag
  'botella', // bottle
  'taza', // cup
  'silla', // chair
  'sofa', // couch
  'cama', // bed
  'televisor', // tv
  'laptop',
  'mouse',
  'control remoto', // remote
  'teclado', // keyboard
  'celular', // cell phone
  'microondas', // microwave
  'horno', // oven
  'refrigerador',
  'libro',
  'reloj', // clock
  'jarron', // vase
  'tijeras', // scissors
  'oso de peluche', // teddy bear
  'cepillo de dientes', // toothbrush
];

class _Box {
  final int classId;
  final double confidence; // -1 para ground truth (no aplica)
  final double x, y, w, h;
  bool matched = false;

  _Box({
    required this.classId,
    required this.confidence,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  double get left => x;
  double get top => y;
  double get right => x + w;
  double get bottom => y + h;
}

double _iou(_Box a, _Box b) {
  final x1 = math.max(a.left, b.left);
  final y1 = math.max(a.top, b.top);
  final x2 = math.min(a.right, b.right);
  final y2 = math.min(a.bottom, b.bottom);
  final inter = math.max(0.0, x2 - x1) * math.max(0.0, y2 - y1);
  final union = a.w * a.h + b.w * b.h - inter;
  if (union <= 0) return 0;
  return inter / union;
}

/// Carga anotaciones desde un archivo JSON (formato AURA) o un directorio
/// de archivos .txt en formato YOLO. Devuelve un mapa `nombreArchivo ->
/// lista de cajas ground-truth`.
Future<Map<String, List<_Box>>> _loadAnnotations(
  String annotationsPath,
  String imagesDir,
) async {
  final result = <String, List<_Box>>{};
  final annEntity = FileSystemEntity.typeSync(annotationsPath);

  if (annEntity == FileSystemEntityType.file) {
    final raw = await File(annotationsPath).readAsString();
    final decoded = json.decode(raw) as Map<String, dynamic>;
    final images = decoded['images'] as List<dynamic>? ?? [];
    for (final entry in images) {
      final map = entry as Map<String, dynamic>;
      final file = map['file'] as String;
      final boxes = (map['boxes'] as List<dynamic>? ?? [])
          .map((b) {
            final bm = b as Map<String, dynamic>;
            return _Box(
              classId: (bm['classId'] as num).toInt(),
              confidence: -1,
              x: (bm['x'] as num).toDouble(),
              y: (bm['y'] as num).toDouble(),
              w: (bm['w'] as num).toDouble(),
              h: (bm['h'] as num).toDouble(),
            );
          })
          .toList();
      result[file] = boxes;
    }
  } else if (annEntity == FileSystemEntityType.directory) {
    final imgDir = Directory(imagesDir);
    final imageFiles = imgDir
        .listSync()
        .whereType<File>()
        .where((f) =>
            f.path.toLowerCase().endsWith('.jpg') ||
            f.path.toLowerCase().endsWith('.jpeg') ||
            f.path.toLowerCase().endsWith('.png'))
        .toList();
    for (final imgFile in imageFiles) {
      final base = imgFile.uri.pathSegments.last;
      final nameNoExt = base.substring(0, base.lastIndexOf('.'));
      final txtFile = File('$annotationsPath/$nameNoExt.txt');
      final boxes = <_Box>[];
      if (txtFile.existsSync()) {
        final lines = await txtFile.readAsLines();
        for (final line in lines) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length < 5) continue;
          final classId = int.parse(parts[0]);
          final cx = double.parse(parts[1]);
          final cy = double.parse(parts[2]);
          final w = double.parse(parts[3]);
          final h = double.parse(parts[4]);
          boxes.add(_Box(
            classId: classId,
            confidence: -1,
            x: cx - w / 2,
            y: cy - h / 2,
            w: w,
            h: h,
          ));
        }
      }
      result[base] = boxes;
    }
  } else {
    throw ArgumentError(
        'annotationsPath no es ni un archivo .json ni un directorio válido: $annotationsPath');
  }
  return result;
}

/// Ejecuta la inferencia YOLOv8n sobre una imagen y devuelve las cajas
/// predichas post-NMS, replicando exactamente la lógica de
/// `ObjectDetector._parseOutput`/`_nms` en `object_detector_native.dart`.
List<_Box> _runInference(Interpreter interpreter, img.Image image) {
  final resized = img.copyResize(image, width: _inputSize, height: _inputSize);
  final bytes = resized.getBytes(order: img.ChannelOrder.rgb);

  final input = Float32List(_inputSize * _inputSize * 3);
  for (int i = 0; i < bytes.length; i++) {
    input[i] = bytes[i] / 255.0;
  }
  final output = Float32List(_numFeatures * _numBoxes);

  interpreter.run(input.buffer, output.buffer);

  final raw = <_Box>[];
  for (int i = 0; i < _numBoxes; i++) {
    double maxConf = 0;
    int classId = 0;
    for (int c = 0; c < _numClasses; c++) {
      final v = output[(4 + c) * _numBoxes + i];
      if (v > maxConf) {
        maxConf = v;
        classId = c;
      }
    }
    if (maxConf < _confThreshold) continue;

    final cx = output[0 * _numBoxes + i] / _inputSize;
    final cy = output[1 * _numBoxes + i] / _inputSize;
    final w = output[2 * _numBoxes + i] / _inputSize;
    final h = output[3 * _numBoxes + i] / _inputSize;

    raw.add(_Box(
      classId: classId,
      confidence: maxConf,
      x: cx - w / 2,
      y: cy - h / 2,
      w: w,
      h: h,
    ));
  }

  return _nms(raw, _iouThreshold);
}

List<_Box> _nms(List<_Box> boxes, double iouThresh) {
  if (boxes.isEmpty) return boxes;
  boxes.sort((a, b) => b.confidence.compareTo(a.confidence));
  final keep = <_Box>[];
  final suppressed = List<bool>.filled(boxes.length, false);
  for (int i = 0; i < boxes.length; i++) {
    if (suppressed[i]) continue;
    keep.add(boxes[i]);
    for (int j = i + 1; j < boxes.length; j++) {
      if (suppressed[j]) continue;
      if (_iou(boxes[i], boxes[j]) > iouThresh) suppressed[j] = true;
    }
  }
  return keep;
}

class _ClassStats {
  int tp = 0;
  int fp = 0;
  int fn = 0;
  // Para AP: cada predicción de esta clase con su confianza y si fue TP.
  final List<double> confidences = [];
  final List<bool> isTruePositive = [];
  int totalGt = 0;
}

/// Corre la evaluación completa: carga anotaciones, corre inferencia sobre
/// cada imagen, hace matching greedy por IoU y calcula mAP@0.5, precisión y
/// recall globales y por clase. Escribe el resultado en [outPath] (JSON) y
/// también lo devuelve.
///
/// Lanza [ArgumentError] si las rutas no existen (no fabrica resultados).
Future<Map<String, dynamic>> evaluateDetector({
  required String imagesDir,
  required String annotationsPath,
  required String outPath,
  Interpreter? interpreter,
}) async {
  final imgDirEntity = Directory(imagesDir);
  if (!imgDirEntity.existsSync()) {
    throw ArgumentError('imagesDir no existe: $imagesDir');
  }
  if (!File(annotationsPath).existsSync() &&
      !Directory(annotationsPath).existsSync()) {
    throw ArgumentError('annotationsPath no existe: $annotationsPath');
  }

  final ownInterpreter = interpreter == null;
  final interp = interpreter ??
      await Interpreter.fromFile(
        File('assets/yolov8n_float32.tflite'),
        options: InterpreterOptions()..threads = 2,
      );

  try {
    final annotations = await _loadAnnotations(annotationsPath, imagesDir);
    if (annotations.isEmpty) {
      throw ArgumentError('No se encontraron anotaciones en $annotationsPath');
    }

    final statsByClass = <int, _ClassStats>{};
    for (int c = 0; c < cocoLabels.length; c++) {
      statsByClass[c] = _ClassStats();
    }

    for (final entry in annotations.entries) {
      final fileName = entry.key;
      final gtBoxes = entry.value;
      final imageFile = File('$imagesDir/$fileName');
      if (!imageFile.existsSync()) {
        debugPrint('evaluateDetector: imagen faltante, se omite: $fileName');
        continue;
      }
      final bytes = await imageFile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) continue;

      for (final gt in gtBoxes) {
        statsByClass[gt.classId]?.totalGt += 1;
      }

      final predictions = _runInference(interp, decoded);
      predictions.sort((a, b) => b.confidence.compareTo(a.confidence));

      for (final pred in predictions) {
        final stats = statsByClass.putIfAbsent(pred.classId, () => _ClassStats());
        _Box? bestGt;
        double bestIou = 0;
        for (final gt in gtBoxes) {
          if (gt.matched || gt.classId != pred.classId) continue;
          final iouVal = _iou(pred, gt);
          if (iouVal > bestIou) {
            bestIou = iouVal;
            bestGt = gt;
          }
        }
        final isTp = bestGt != null && bestIou >= _mapIouThreshold;
        stats.confidences.add(pred.confidence);
        stats.isTruePositive.add(isTp);
        if (isTp) {
          bestGt!.matched = true;
          stats.tp += 1;
        } else {
          stats.fp += 1;
        }
      }

      for (final gt in gtBoxes) {
        if (!gt.matched) {
          statsByClass[gt.classId]?.fn += 1;
        }
      }
    }

    final perClass = <String, dynamic>{};
    final apValues = <double>[];
    for (final e in statsByClass.entries) {
      final classId = e.key;
      final stats = e.value;
      if (stats.totalGt == 0 && stats.tp == 0 && stats.fp == 0) continue;

      final precision =
          (stats.tp + stats.fp) == 0 ? 0.0 : stats.tp / (stats.tp + stats.fp);
      final recall =
          (stats.tp + stats.fn) == 0 ? 0.0 : stats.tp / (stats.tp + stats.fn);

      double ap = 0.0;
      if (stats.totalGt > 0 && stats.confidences.isNotEmpty) {
        final order = List<int>.generate(stats.confidences.length, (i) => i)
          ..sort((a, b) => stats.confidences[b].compareTo(stats.confidences[a]));
        int cumTp = 0, cumFp = 0;
        final recalls = <double>[];
        final precisions = <double>[];
        for (final idx in order) {
          if (stats.isTruePositive[idx]) {
            cumTp++;
          } else {
            cumFp++;
          }
          recalls.add(cumTp / stats.totalGt);
          precisions.add(cumTp / (cumTp + cumFp));
        }
        // All-point interpolation (Pascal VOC 2010+ / estándar): para cada
        // punto de recall alcanzado, AP += (recall_i - recall_{i-1}) *
        // max(precision en todos los puntos con recall >= recall_i).
        double prevRecall = 0.0;
        for (int i = 0; i < recalls.length; i++) {
          final r = recalls[i];
          if (r <= prevRecall) continue;
          double maxP = 0;
          for (int j = 0; j < recalls.length; j++) {
            if (recalls[j] >= r && precisions[j] > maxP) maxP = precisions[j];
          }
          ap += (r - prevRecall) * maxP;
          prevRecall = r;
        }
        apValues.add(ap);
      }

      perClass[cocoLabels[classId]] = {
        'classId': classId,
        'tp': stats.tp,
        'fp': stats.fp,
        'fn': stats.fn,
        'precision': precision,
        'recall': recall,
        'ap': ap,
      };
    }

    final overallTp = statsByClass.values.fold<int>(0, (s, c) => s + c.tp);
    final overallFp = statsByClass.values.fold<int>(0, (s, c) => s + c.fp);
    final overallFn = statsByClass.values.fold<int>(0, (s, c) => s + c.fn);
    final overallPrecision =
        (overallTp + overallFp) == 0 ? 0.0 : overallTp / (overallTp + overallFp);
    final overallRecall =
        (overallTp + overallFn) == 0 ? 0.0 : overallTp / (overallTp + overallFn);
    final mAP50 = apValues.isEmpty
        ? 0.0
        : apValues.reduce((a, b) => a + b) / apValues.length;

    final householdRelevantSummary = <String, dynamic>{};
    for (final label in _householdRelevantLabels) {
      if (perClass.containsKey(label)) {
        householdRelevantSummary[label] = perClass[label];
      }
    }

    final report = {
      'generatedAt': DateTime.now().toIso8601String(),
      'imagesEvaluated': annotations.length,
      'overall': {
        'mAP50': mAP50,
        'precision': overallPrecision,
        'recall': overallRecall,
        'tp': overallTp,
        'fp': overallFp,
        'fn': overallFn,
      },
      'perClass': perClass,
      'householdRelevantSummary': householdRelevantSummary,
    };

    final outFile = File(outPath);
    await outFile.writeAsString(const JsonEncoder.withIndent('  ').convert(report));

    return report;
  } finally {
    if (ownInterpreter) interp.close();
  }
}
