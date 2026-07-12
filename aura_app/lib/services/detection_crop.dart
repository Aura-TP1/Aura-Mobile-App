import 'package:image/image.dart' as img;

import 'object_detector.dart' show Detection;

/// Recorta [image] alrededor del [Detection] de mayor confianza detectado
/// por YOLO, con un margen de padding alrededor del bounding box para no
/// cortar el objeto demasiado ajustado (p. ej. si YOLO subestima ligeramente
/// el tamaño real del objeto).
///
/// [padding] es una fracción del ancho/alto del bounding box que se agrega
/// a cada lado (0.10-0.15 recomendado). El recorte se clampea a los límites
/// de la imagen original.
///
/// Este recorte es el que debe alimentar a MobileNetV2, en vez de la imagen
/// completa: el bbox de YOLO acota el objeto de interés, mientras que la
/// imagen completa incluye fondo/otros objetos que degradan el embedding
/// (afecta directamente la similitud coseno reportada en la Tabla II).
img.Image cropToDetection(img.Image image, Detection detection, {double padding = 0.125}) {
  final w = image.width;
  final h = image.height;

  // detection.rect está en coordenadas normalizadas [0..1].
  final rect = detection.rect;
  final boxW = rect.width * w;
  final boxH = rect.height * h;
  final padX = boxW * padding;
  final padY = boxH * padding;

  final left = ((rect.left * w) - padX).clamp(0.0, w.toDouble());
  final top = ((rect.top * h) - padY).clamp(0.0, h.toDouble());
  final right = ((rect.right * w) + padX).clamp(0.0, w.toDouble());
  final bottom = ((rect.bottom * h) + padY).clamp(0.0, h.toDouble());

  final cropW = (right - left).round();
  final cropH = (bottom - top).round();

  // Si el bbox degenera (0 ancho/alto tras el clamp), no recortamos.
  if (cropW <= 0 || cropH <= 0) return image;

  return img.copyCrop(
    image,
    x: left.round(),
    y: top.round(),
    width: cropW,
    height: cropH,
  );
}

/// Devuelve la detección de mayor confianza de una lista, o `null` si está
/// vacía.
Detection? highestConfidence(List<Detection> detections) {
  if (detections.isEmpty) return null;
  Detection best = detections.first;
  for (final d in detections.skip(1)) {
    if (d.confidence > best.confidence) best = d;
  }
  return best;
}
