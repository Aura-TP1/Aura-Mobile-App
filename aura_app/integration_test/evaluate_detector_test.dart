// Corre la evaluación de mAP@0.5 / precisión / recall de YOLOv8n contra un
// dataset con anotaciones (ej. un subconjunto de COCO val2017), UNA VEZ POR
// CADA VARIANTE DEL MODELO (float32 e INT8), para poder comparar ambas bajo
// exactamente las mismas imágenes/anotaciones/umbrales.
//
// CÓMO CORRERLO:
//   1. Copiar las imágenes .jpg/.png del dataset a un directorio accesible
//      desde el dispositivo/emulador (ver EVAL_README.md en esta carpeta
//      para el formato exacto esperado).
//   2. Editar las 2 constantes de abajo (_imagesDir, _annotationsPath) con
//      las rutas reales EN EL DISPOSITIVO donde corre el test (no rutas de
//      esta máquina de desarrollo).
//   3. flutter test integration_test/evaluate_detector_test.dart -d <device>
//   4. Los reportes JSON quedan en el mismo directorio que _imagesDir,
//      como eval_report_float32.json y eval_report_int8.json.
//   5. Pegar la sección "overall" de cada JSON acá en el chat, o el archivo
//      completo, y valido/redacto Table I con los números reales de ambas
//      variantes.
//
// No inventa resultados: si las rutas no existen, `evaluateDetector` lanza
// ArgumentError y el test falla explícitamente en vez de reportar ceros.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'package:aura_app/services/eval/detection_evaluator.dart';

// ── EDITAR ANTES DE CORRER ──────────────────────────────────────────────
// Rutas en el almacenamiento del dispositivo/emulador de prueba, no en esta
// máquina. En Android, algo como '/sdcard/aura_eval/images' suele funcionar
// si el dataset se copió ahí con `adb push`.
const String _imagesDir = '/sdcard/aura_eval/images';
const String _annotationsPath = '/sdcard/aura_eval/annotations';
const String _outDir = '/sdcard/aura_eval';
// ─────────────────────────────────────────────────────────────────────────

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('YOLOv8n float32 vs INT8 — mAP@0.5/precision/recall',
      (tester) async {
    for (final variant in ['float32', 'int8']) {
      final assetPath = variant == 'int8'
          ? 'assets/yolov8n_int8.tflite'
          : 'assets/yolov8n_float32.tflite';
      final outPath = '$_outDir/eval_report_$variant.json';

      final interpreter = await Interpreter.fromAsset(
        assetPath,
        options: InterpreterOptions()..threads = 2,
      );

      final report = await evaluateDetector(
        imagesDir: _imagesDir,
        annotationsPath: _annotationsPath,
        outPath: outPath,
        interpreter: interpreter,
      );

      interpreter.close();

      // Falla ruidosamente si algo salió mal, en vez de dejar pasar un
      // reporte vacío/silencioso.
      expect(report['imagesEvaluated'], greaterThan(0),
          reason:
              'No se evaluó ninguna imagen para $variant — revisar _imagesDir/_annotationsPath.');

      // eslint-disable-next-line
      // ignore: avoid_print
      print('=== $variant ===');
      // ignore: avoid_print
      print(report['overall']);
      // ignore: avoid_print
      print('Reporte completo escrito en: $outPath');
    }
  });
}
