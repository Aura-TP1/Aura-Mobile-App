import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'object_detector_common.dart';

/// Implementacion web: tflite_flutter usa dart:ffi y no esta soportado en web.
class ObjectDetector {
  bool _isModelLoaded = false;

  bool get isLoaded => _isModelLoaded;

  Future<void> loadModel() async {
    _isModelLoaded = false;
    debugPrint(
      'ObjectDetector no disponible en Web: tflite_flutter requiere dart:ffi.',
    );
  }

  Future<List<Detection>> detect(img.Image image) async {
    return const [];
  }

  void dispose() {}
}
