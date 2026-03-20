import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class ObjectDetector {
  Interpreter? _interpreter;
  bool _isModelLoaded = false;

  // Cargar modelo YOLO
  Future<void> loadModel() async {
    try {
      print('📦 Cargando YOLOv8...');
      
      _interpreter = await Interpreter.fromAsset(
        'assets/models/yolov8n_float32.tflite',
        options: InterpreterOptions()
          ..threads = 4
          ..useNnApiForAndroid = true,
      );
      
      _isModelLoaded = true;
      
      // Ver detalles del modelo
      print('✅ Modelo cargado!');
      print('📊 Input: ${_interpreter!.getInputTensors()}');
      print('📊 Output: ${_interpreter!.getOutputTensors()}');
      
    } catch (e) {
      print('❌ Error cargando modelo: $e');
    }
  }

  bool get isLoaded => _isModelLoaded;

  void dispose() {
    _interpreter?.close();
  }
}