import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Servicio de extracción de embeddings visuales basado en MobileNetV2 TFLite.
///
/// Asume un modelo truncado al penúltimo layer (salida del global average
/// pooling), con shape típica [1, 1280]. Detecta dinámicamente la shape
/// real en [loadModel] para tolerar variantes del modelo.
///
/// Implementación native — usa `tflite_flutter` (dart:ffi) y solo corre en
/// Android, iOS, Windows, macOS, Linux. En Web usa el stub de
/// `embedding_service_web.dart`.
class EmbeddingService {
  static const int _inputSize = 224;

  Interpreter? _interpreter;
  bool _isLoaded = false;
  int _outputLength = 1280; // fallback; se sobrescribe al cargar

  bool get isLoaded => _isLoaded;
  int get outputLength => _outputLength;

  Future<void> loadModel() async {
    try {
      debugPrint('Cargando MobileNetV2 embeddings...');
      _interpreter = await Interpreter.fromAsset(
        'assets/mobilenetv2_embeddings.tflite',
        options: InterpreterOptions()..threads = 4,
      );

      final inputTensors = _interpreter!.getInputTensors();
      final outputTensors = _interpreter!.getOutputTensors();
      debugPrint(
        '  Input : ${inputTensors.map((t) => t.shape).toList()}',
      );
      debugPrint(
        '  Output: ${outputTensors.map((t) => t.shape).toList()}',
      );

      // Detecta el tamaño del embedding a partir de la última dimensión
      // del primer tensor de salida.
      if (outputTensors.isNotEmpty) {
        final shape = outputTensors.first.shape;
        if (shape.isNotEmpty) {
          _outputLength = shape.last;
        }
      }

      _isLoaded = true;
      debugPrint('Embedding model listo (dim=$_outputLength).');
    } catch (e, st) {
      debugPrint('Error cargando MobileNetV2: $e\n$st');
      _isLoaded = false;
    }
  }

  /// Extrae el vector de características del [image] dado.
  ///
  /// Preprocesamiento:
  /// - Resize a 224x224.
  /// - Normalización a [0..1] (el spec lo pide así).
  /// - Shape final del input: [1, 224, 224, 3] float32.
  ///
  /// Retorna la lista de floats del embedding (longitud = [outputLength]).
  /// Si el modelo no está cargado, retorna lista vacía.
  Future<List<double>> extractEmbedding(img.Image image) async {
    if (!_isLoaded || _interpreter == null) return const [];

    final resized = img.copyResize(
      image,
      width: _inputSize,
      height: _inputSize,
    );

    final input = List.generate(
      1,
      (_) => List.generate(
        _inputSize,
        (y) => List.generate(_inputSize, (x) {
          final p = resized.getPixel(x, y);
          return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
        }),
      ),
    );

    final output = List.generate(
      1,
      (_) => List.filled(_outputLength, 0.0),
    );

    try {
      _interpreter!.run(input, output);
    } catch (e) {
      debugPrint('Error en inferencia de embedding: $e');
      return const [];
    }

    return List<double>.from(output[0]);
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
