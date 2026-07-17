import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';
import 'object_detector_common.dart';

/// Servicio de logging de métricas (instrumentación pura, no funcional).
///
/// Escribe archivos JSONL (un objeto JSON por línea) con datos de cada
/// frame de detección y cada intento de búsqueda, para análisis offline
/// (mAP, precisión/recall, sensibilidad a fondo, confusión entre objetos
/// similares, escalabilidad, etc.). Nunca debe afectar el flujo de
/// detección/búsqueda en vivo: toda excepción se captura y se descarta
/// (con `debugPrint`), y nunca se relanza hacia el llamador.
class MetricsLogger {
  MetricsLogger._();
  static final MetricsLogger instance = MetricsLogger._();

  /// Umbral real de match confirmado usado en `real_search_screen.dart`
  /// (`_threshold`). Se duplica aquí como constante porque este archivo no
  /// debe depender del estado de una pantalla — debe mantenerse en sync si
  /// el umbral cambia allí.
  static const double kMatchThreshold = 0.75;

  static const String _detectionFileName = 'detection_metrics.jsonl';
  static const String _searchFileName = 'search_metrics.jsonl';
  static const String _cropFileName = 'crop_metrics.jsonl';

  Directory? _metricsDir;

  Future<Directory> _getMetricsDir() async {
    if (_metricsDir != null) return _metricsDir!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/aura_metrics');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _metricsDir = dir;
    return dir;
  }

  Future<void> _appendLine(String fileName, Map<String, dynamic> entry) async {
    try {
      final dir = await _getMetricsDir();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(
        '${json.encode(entry)}\n',
        mode: FileMode.append,
        flush: false,
      );
    } catch (e) {
      debugPrint('MetricsLogger: error escribiendo $fileName: $e');
    }
  }

  int _classIdOf(String label) {
    final idx = cocoLabels.indexOf(label);
    return idx; // -1 si no se encuentra en la lista COCO.
  }

  Future<void> logDetectionFrame({
    required int frameLatencyMs,
    required List<Detection> detections,
  }) async {
    try {
      final entry = <String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
        'frameLatencyMs': frameLatencyMs,
        'detections': detections
            .map((d) => {
                  'classId': _classIdOf(d.label),
                  'label': d.label,
                  'confidence': d.confidence,
                  'bbox': {
                    'x': d.rect.left,
                    'y': d.rect.top,
                    'w': d.rect.width,
                    'h': d.rect.height,
                  },
                })
            .toList(),
      };
      await _appendLine(_detectionFileName, entry);
    } catch (e) {
      debugPrint('MetricsLogger.logDetectionFrame error: $e');
    }
  }

  Future<void> logSearchAttempt({
    required String targetObjectId,
    required String targetObjectName,
    required double targetSimilarity,
    required String decision,
    required int latencyMs,
    required int storedObjectCount,
    Map<String, double>? allObjectSimilarities,
    // Diagnóstico del recorte usado para este intento de búsqueda (ver
    // detection_crop.dart): permite analizar, por objeto, si YOLO logró
    // localizar el objeto (aunque sea con baja confianza) o si se usó el
    // recorte central de respaldo — clave para confirmar/refutar si el
    // recorte por bbox realmente ayuda en objetos que no son clases COCO.
    String? cropMethod, // 'yolo_detection' | 'center_crop_fallback' | 'full_frame_no_model'
    int? cropDetectionClassId,
    String? cropDetectionLabel,
    double? cropDetectionConfidence,
  }) async {
    try {
      String? topOtherObjectId;
      double? topOtherObjectSimilarity;
      bool? wouldConfuseWithOther;
      bool? matchCorrect;

      if (allObjectSimilarities != null) {
        for (final e in allObjectSimilarities.entries) {
          if (e.key == targetObjectId) continue;
          if (topOtherObjectSimilarity == null || e.value > topOtherObjectSimilarity) {
            topOtherObjectSimilarity = e.value;
            topOtherObjectId = e.key;
          }
        }

        wouldConfuseWithOther = topOtherObjectSimilarity != null &&
            topOtherObjectSimilarity >= kMatchThreshold &&
            topOtherObjectSimilarity > targetSimilarity;

        matchCorrect = decision == 'found' &&
            (topOtherObjectSimilarity == null ||
                targetSimilarity >= topOtherObjectSimilarity);
      }

      final entry = <String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
        'targetObjectId': targetObjectId,
        'targetObjectName': targetObjectName,
        'targetSimilarity': targetSimilarity,
        'decision': decision,
        'latencyMs': latencyMs,
        'storedObjectCount': storedObjectCount,
        'testCondition': _testCondition,
        'testRunLabel': _testRunLabel,
        'topOtherObjectId': topOtherObjectId,
        'topOtherObjectSimilarity': topOtherObjectSimilarity,
        'wouldConfuseWithOther': wouldConfuseWithOther,
        'matchCorrect': matchCorrect,
        'cropMethod': cropMethod,
        'cropDetectionClassId': cropDetectionClassId,
        'cropDetectionLabel': cropDetectionLabel,
        'cropDetectionConfidence': cropDetectionConfidence,
      };
      await _appendLine(_searchFileName, entry);
    } catch (e) {
      debugPrint('MetricsLogger.logSearchAttempt error: $e');
    }
  }

  /// Diagnóstico del recorte para los flujos de guardado (save_object /
  /// multi_angle_capture), que no tienen un log de intento existente para
  /// extender como sí lo tiene la búsqueda. Mismo propósito que los campos
  /// `crop*` de [logSearchAttempt]: saber si YOLO localizó el objeto (con
  /// qué confianza/clase) o si se usó el recorte central de respaldo.
  Future<void> logCropSelection({
    required String screen,
    required String objectLabel,
    required String cropMethod,
    int? detectionClassId,
    String? detectionLabel,
    double? detectionConfidence,
  }) async {
    try {
      final entry = <String, dynamic>{
        'timestamp': DateTime.now().toIso8601String(),
        'screen': screen,
        'objectLabel': objectLabel,
        'cropMethod': cropMethod,
        'detectionClassId': detectionClassId,
        'detectionLabel': detectionLabel,
        'detectionConfidence': detectionConfidence,
      };
      await _appendLine(_cropFileName, entry);
    } catch (e) {
      debugPrint('MetricsLogger.logCropSelection error: $e');
    }
  }

  /// Lecturas defensivas de las etiquetas de prueba: si algo falla (p.ej.
  /// `AppSettings` no cargado aún), cae a valores por defecto en vez de
  /// romper el logging.
  String get _testCondition {
    try {
      return AppSettings.instance.testCondition;
    } catch (_) {
      return 'default';
    }
  }

  String get _testRunLabel {
    try {
      return AppSettings.instance.testRunLabel;
    } catch (_) {
      return '';
    }
  }
}
