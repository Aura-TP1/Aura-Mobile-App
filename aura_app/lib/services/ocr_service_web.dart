import 'package:flutter/foundation.dart';

/// Stub web de [OcrService]. ML Kit Text Recognition no está disponible en
/// Chrome, así que en web el OCR no hace nada.
class OcrService {
  Future<String> recognize(String imagePath) async {
    debugPrint('OCR no disponible en Web.');
    return '';
  }

  void dispose() {}
}
