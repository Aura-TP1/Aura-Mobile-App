import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Stub web de [EmbeddingService]. `tflite_flutter` depende de `dart:ffi`
/// y no funciona en Chrome, por lo que en web no se puede extraer el
/// embedding visual. La pantalla de guardar objeto debe cablear un
/// fallback que permita guardar solo el nombre.
class EmbeddingService {
  bool _isLoaded = false;
  static const int _stubOutputLength = 0;

  bool get isLoaded => _isLoaded;
  int get outputLength => _stubOutputLength;

  Future<void> loadModel() async {
    _isLoaded = false;
    debugPrint(
      'EmbeddingService no disponible en Web: '
      'tflite_flutter requiere dart:ffi.',
    );
  }

  // ignore: unused_element
  Future<List<double>> extractEmbedding(img.Image image) async {
    return const [];
  }

  void dispose() {}
}
