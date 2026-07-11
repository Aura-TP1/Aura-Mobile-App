import 'dart:typed_data';

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

  /// Si es `true`, carga la variante INT8 cuantizada
  /// (`assets/mobilenetv2_embeddings_int8.tflite`) en vez del modelo
  /// float32 por defecto (`assets/mobilenetv2_embeddings.tflite`).
  ///
  /// IMPORTANTE: el modelo INT8 fue reconstruido desde
  /// `tf.keras.applications.MobileNetV2(weights='imagenet', pooling='avg')`
  /// + post-training quantization (calibrado con un puñado de fotos reales),
  /// ya que no existe el código/fuente que generó el .tflite float32
  /// original en este repo. NO hay garantía de que sea el mismo grafo/pesos
  /// (truncamiento, fine-tuning, etc.) — por lo tanto sus embeddings NO son
  /// directamente comparables/compatibles con embeddings ya guardados en la
  /// base de datos usando el modelo float32. Este flag es solo para
  /// comparar latencia/tamaño manualmente, no para uso en producción sin
  /// re-generar todos los embeddings guardados.
  final bool useInt8;

  EmbeddingService({this.useInt8 = false});

  Interpreter? _interpreter;
  bool _isLoaded = false;
  int _outputLength = 1280; // fallback; se sobrescribe al cargar

  // Parámetros de cuantización de entrada/salida (solo relevantes si
  // useInt8 == true). Se leen dinámicamente en loadModel() desde
  // tensor.params (QuantizationParams: scale, zeroPoint).
  double _inputScale = 1.0;
  int _inputZeroPoint = 0;
  double _outputScale = 1.0;
  int _outputZeroPoint = 0;

  bool get isLoaded => _isLoaded;
  int get outputLength => _outputLength;

  Future<void> loadModel() async {
    final assetPath = useInt8
        ? 'assets/mobilenetv2_embeddings_int8.tflite'
        : 'assets/mobilenetv2_embeddings.tflite';
    try {
      debugPrint('Cargando MobileNetV2 embeddings ($assetPath)...');
      _interpreter = await Interpreter.fromAsset(
        assetPath,
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

      if (useInt8) {
        if (inputTensors.isNotEmpty) {
          _inputScale = inputTensors.first.params.scale;
          _inputZeroPoint = inputTensors.first.params.zeroPoint;
        }
        if (outputTensors.isNotEmpty) {
          _outputScale = outputTensors.first.params.scale;
          _outputZeroPoint = outputTensors.first.params.zeroPoint;
        }
        debugPrint(
          '  Quant input: scale=$_inputScale zeroPoint=$_inputZeroPoint | '
          'output: scale=$_outputScale zeroPoint=$_outputZeroPoint',
        );
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
  /// - Normalización a [0..1] (el spec lo pide así) y, si [useInt8] es
  ///   true, cuantización adicional a int8 usando los parámetros de
  ///   cuantización del tensor de entrada del modelo.
  /// - Shape final del input: [1, 224, 224, 3].
  ///
  /// Retorna la lista de floats del embedding (longitud = [outputLength]),
  /// dequantizada a float32 si el modelo es INT8, para que el resto de la
  /// app (comparación de similitud coseno, almacenamiento, etc.) no tenga
  /// que saber qué variante de modelo se usó.
  /// Si el modelo no está cargado, retorna lista vacía.
  Future<List<double>> extractEmbedding(img.Image image) async {
    if (!_isLoaded || _interpreter == null) return const [];

    final resized = img.copyResize(
      image,
      width: _inputSize,
      height: _inputSize,
    );

    try {
      if (useInt8) {
        return await _extractEmbeddingInt8(resized);
      }
      return await _extractEmbeddingFloat32(resized);
    } catch (e) {
      debugPrint('Error en inferencia de embedding: $e');
      return const [];
    }
  }

  Future<List<double>> _extractEmbeddingFloat32(img.Image resized) async {
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

    _interpreter!.run(input, output);

    return List<double>.from(output[0]);
  }

  Future<List<double>> _extractEmbeddingInt8(img.Image resized) async {
    final bytes = resized.getBytes(order: img.ChannelOrder.rgb);
    final inputBuffer = Int8List(_inputSize * _inputSize * 3);
    for (int i = 0; i < bytes.length; i++) {
      final normalized = bytes[i] / 255.0;
      final q = (normalized / _inputScale + _inputZeroPoint)
          .round()
          .clamp(-128, 127);
      inputBuffer[i] = q;
    }

    final outputBuffer = Int8List(_outputLength);

    _interpreter!.run(inputBuffer.buffer, outputBuffer.buffer);

    final result = List<double>.filled(_outputLength, 0.0);
    for (int i = 0; i < _outputLength; i++) {
      result[i] = (outputBuffer[i] - _outputZeroPoint) * _outputScale;
    }
    return result;
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
  }
}
