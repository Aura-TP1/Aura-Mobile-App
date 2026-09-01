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
    // Coincidencias ORB (puntos clave) contra el objeto buscado. Es la señal
    // independiente del embedding — se registra para poder recalibrar
    // OrbMatcher.kMinGoodMatches con datos del teléfono en vez de a ojo.
    int orbMatches = 0,
    // Diagnóstico del recorte usado para este intento de búsqueda (ver
    // detection_crop.dart): permite analizar, por objeto, si YOLO logró
    // localizar el objeto (aunque sea con baja confianza) o si se usó el
    // recorte central de respaldo — clave para confirmar/refutar si el
    // recorte por bbox realmente ayuda en objetos que no son clases COCO.
    String? cropMethod, // 'yolo_detection' | 'center_crop_fallback' | 'full_frame_no_model'
    int? cropDetectionClassId,
    String? cropDetectionLabel,
    double? cropDetectionConfidence,
    // Por qué se cayó a centerCrop, cuando cropMethod == 'center_crop_fallback':
    // 'no_detection' (YOLO no encontró nada ≥ kCropConfThreshold) o
    // 'box_too_small' (encontró algo, pero bestCropCandidate lo descartó por
    // tamaño — ver kMinCropBoxFraction en detection_crop.dart). Junto con
    // discardedBoxWidth/Height, permite diferenciar en el log si el cuello de
    // botella es que YOLO no ve nada o que ve algo demasiado chico, sin tener
    // que adivinar a partir de campos que hoy quedan null en ambos casos.
    String? cropFallbackReason,
    double? discardedBoxWidth,
    double? discardedBoxHeight,
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
        'orbMatches': orbMatches,
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
        'cropFallbackReason': cropFallbackReason,
        'discardedBoxWidth': discardedBoxWidth,
        'discardedBoxHeight': discardedBoxHeight,
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
    String? cropFallbackReason,
    double? discardedBoxWidth,
    double? discardedBoxHeight,
    // Geometría real de la captura. Sirve para verificar que el marco guía
    // en pantalla y el recorte cubren la misma región: si vuelven a
    // desalinearse, estos números lo muestran en vez de tener que deducirlo
    // mirando una foto.
    String? frameSource,
    int? frameWidth,
    int? frameHeight,
    int? previewWidth,
    int? previewHeight,
    int? cropSide,
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
        'cropFallbackReason': cropFallbackReason,
        'discardedBoxWidth': discardedBoxWidth,
        'discardedBoxHeight': discardedBoxHeight,
        'frameSource': frameSource,
        'frameWidth': frameWidth,
        'frameHeight': frameHeight,
        'previewWidth': previewWidth,
        'previewHeight': previewHeight,
        'cropSide': cropSide,
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

  // ── Lectura/borrado (para el visor de métricas en Ajustes) ─────────────
  // Todo lo de arriba solo escribe — hasta ahora la única forma de ver
  // estos archivos era conectar el celular por cable y leerlos a mano.

  static const List<String> _allFileNames = [
    _detectionFileName,
    _searchFileName,
    _cropFileName,
  ];

  /// Nombre, tamaño en bytes y cantidad de líneas (registros) de cada
  /// archivo de métricas. Archivos que aún no existen (nada logueado todavía)
  /// aparecen con 0 líneas y 0 bytes, no se omiten.
  Future<List<MetricsFileInfo>> listMetricsFiles() async {
    final dir = await _getMetricsDir();
    final result = <MetricsFileInfo>[];
    for (final name in _allFileNames) {
      final file = File('${dir.path}/$name');
      if (!await file.exists()) {
        result.add(MetricsFileInfo(fileName: name, sizeBytes: 0, lineCount: 0));
        continue;
      }
      final stat = await file.stat();
      // Contar líneas no vacías en vez de asumir que cada '\n' es un
      // registro completo, por si la última línea quedó sin el '\n' final.
      final lines = (await file.readAsLines())
          .where((l) => l.trim().isNotEmpty)
          .length;
      result.add(MetricsFileInfo(
        fileName: name,
        sizeBytes: stat.size,
        lineCount: lines,
      ));
    }
    return result;
  }

  /// Ruta absoluta de un archivo de métricas (para compartirlo por
  /// `share_plus`). No garantiza que el archivo exista.
  Future<String> filePathFor(String fileName) async {
    final dir = await _getMetricsDir();
    return '${dir.path}/$fileName';
  }

  Future<List<String>> allFilePaths() async {
    final dir = await _getMetricsDir();
    return _allFileNames.map((n) => '${dir.path}/$n').toList();
  }

  /// Últimas [maxLines] líneas de un archivo de métricas, para mostrar
  /// directo en pantalla (visor de Ajustes) sin depender de compartir el
  /// archivo. Las más recientes primero. Lista vacía si el archivo no
  /// existe o está vacío.
  Future<List<String>> readLastLines(String fileName, {int maxLines = 20}) async {
    final dir = await _getMetricsDir();
    final file = File('${dir.path}/$fileName');
    if (!await file.exists()) return const [];
    final lines = (await file.readAsLines())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    final start = (lines.length - maxLines).clamp(0, lines.length).toInt();
    return lines.sublist(start).reversed.toList();
  }

  /// Borra los 3 archivos de métricas y los recortes de depuración
  /// guardados. Pensado para arrancar una tanda de pruebas de campo desde
  /// cero.
  Future<void> deleteAllMetrics() async {
    final dir = await _getMetricsDir();
    for (final name in _allFileNames) {
      final file = File('${dir.path}/$name');
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (e) {
          debugPrint('MetricsLogger: error borrando $name: $e');
        }
      }
    }
    try {
      final cropsDir = await _getCropsDir();
      for (final entity in await cropsDir.list().toList()) {
        if (entity is File) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('MetricsLogger: error borrando recortes: $e');
    }
  }

  // ── Recortes de depuración (visor "Recortes recientes" en Ajustes) ─────
  // Antes solo se logueaba metadata (clase, confianza) del recorte elegido
  // — no había forma de ver la imagen real. Esto guarda el recorte que
  // efectivamente se usó para extraer el embedding, para poder confirmar
  // a simple vista si agarró el objeto correcto o algo de fondo (caso real
  // que motivó esto: una pastilla sobre un teclado, donde YOLO recortaba
  // el teclado en vez de la pastilla).

  static const int _maxCropDebugImages = 20;

  Future<Directory> _getCropsDir() async {
    final dir = await _getMetricsDir();
    final cropsDir = Directory('${dir.path}/crops');
    if (!await cropsDir.exists()) {
      await cropsDir.create(recursive: true);
    }
    return cropsDir;
  }

  /// Guarda [jpegBytes] (ya codificados como JPEG) como el recorte de
  /// depuración más reciente. Mantiene como máximo [_maxCropDebugImages],
  /// borrando los más viejos, para no llenar el almacenamiento del
  /// celular con esto.
  Future<void> saveCropDebugImage(
    List<int> jpegBytes, {
    required String objectLabel,
    required String cropMethod,
  }) async {
    try {
      final cropsDir = await _getCropsDir();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeLabel = objectLabel.trim().isEmpty
          ? 'objeto'
          : objectLabel.replaceAll(RegExp(r'[^a-zA-Z0-9_\-áéíóúÁÉÍÓÚñÑ ]'), '_');
      final file = File('${cropsDir.path}/${timestamp}_${safeLabel}_$cropMethod.jpg');
      await file.writeAsBytes(jpegBytes);

      final files = (await cropsDir.list().toList()).whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path)); // el timestamp al inicio del nombre ordena cronológicamente
      if (files.length > _maxCropDebugImages) {
        for (final f in files.take(files.length - _maxCropDebugImages)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (e) {
      debugPrint('MetricsLogger: error guardando recorte de depuración: $e');
    }
  }

  /// Recortes de depuración guardados, más reciente primero.
  Future<List<File>> listCropDebugImages() async {
    final cropsDir = await _getCropsDir();
    final files = (await cropsDir.list().toList()).whereType<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }
}

/// Resumen de un archivo de métricas, para mostrar en el visor de Ajustes.
class MetricsFileInfo {
  final String fileName;
  final int sizeBytes;
  final int lineCount;

  const MetricsFileInfo({
    required this.fileName,
    required this.sizeBytes,
    required this.lineCount,
  });
}
