import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// Servicio de OCR basado en ML Kit Text Recognition (offline, on-device).
///
/// Funciona en Android/iOS. En desktop (Windows/macOS/Linux) el plugin no
/// tiene implementación nativa, por lo que [recognize] devuelve "" tras
/// capturar la excepción — la UI muestra "no leí texto" en ese caso.
class OcrService {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  /// Reconoce el texto presente en la imagen ubicada en [imagePath]
  /// (la ruta del `XFile` que produce `CameraController.takePicture`).
  /// Devuelve el texto detectado (trim) o "" si no hay texto / hay error.
  Future<String> recognize(String imagePath) async {
    try {
      final input = InputImage.fromFilePath(imagePath);
      final result = await _recognizer.processImage(input);
      return result.text.trim();
    } catch (e) {
      debugPrint('OCR error: $e');
      return '';
    }
  }

  void dispose() {
    _recognizer.close();
  }
}
