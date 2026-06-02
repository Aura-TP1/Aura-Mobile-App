// Selección condicional de implementación, igual que object_detector.dart:
// - native (Android/iOS/desktop) → ML Kit Text Recognition (offline).
// - web → stub que devuelve cadena vacía (ML Kit no soporta web).
export 'ocr_service_web.dart'
    if (dart.library.io) 'ocr_service_native.dart';
