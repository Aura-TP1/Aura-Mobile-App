import 'package:image/image.dart' as img;

import 'object_detector.dart' show Detection;

/// Umbral de confianza usado SOLO para elegir un recorte antes de extraer
/// el embedding — deliberadamente mucho más bajo que el umbral de
/// detección en vivo (0.4 en `ObjectDetector._confThreshold`). El objetivo
/// aquí no es clasificar correctamente el objeto, solo localizarlo
/// espacialmente: YOLOv8n es COCO-pretrained (80 clases fijas), y varios
/// objetos de prueba (llaves, pastillas, vitaminas, lentes, billetera) no
/// tienen clase COCO análoga, así que sus activaciones de clase se quedan
/// muy por debajo de 0.4 en la mayoría de los frames aunque el objeto esté
/// perfectamente ubicado en el cuadro. Un umbral bajo deja pasar esas cajas
/// de baja confianza igual, ya que solo nos interesa su posición.
const double kCropConfThreshold = 0.15;

/// Recorte central de respaldo cuando ni siquiera [kCropConfThreshold]
/// encuentra una caja: recorta el [fraction] central del ancho/alto de
/// [image] (centrado), sin depender de que YOLO reconozca la clase del
/// objeto. Sigue reduciendo el fondo para objetos razonablemente centrados
/// en el encuadre, que es como se pide capturar/buscar objetos en la app.
img.Image centerCrop(img.Image image, {double fraction = 0.65}) {
  final w = image.width;
  final h = image.height;
  final cropW = (w * fraction).round().clamp(1, w);
  final cropH = (h * fraction).round().clamp(1, h);
  final x = ((w - cropW) / 2).round();
  final y = ((h - cropH) / 2).round();
  return img.copyCrop(image, x: x, y: y, width: cropW, height: cropH);
}

/// Normaliza brillo/contraste antes de extraer el embedding: estira el
/// rango de intensidad de la imagen a [0, 255]. Objetivo: que la diferencia
/// de iluminación entre el momento de GUARDAR un objeto y el momento de
/// BUSCARLO pese menos en el embedding resultante — hoy una foto guardada
/// con luz de día y buscada con luz artificial (o viceversa) puede dar una
/// similitud coseno más baja solo por el cambio de luz, no por ser un
/// objeto distinto.
///
/// Debe aplicarse en AMBOS lados (guardar y buscar) para que ayude — ver
/// `save_object_screen.dart` y `real_search_screen.dart`. Si falla por
/// cualquier motivo, devuelve la imagen original sin normalizar en vez de
/// interrumpir el flujo de guardado/búsqueda.
img.Image normalizeForEmbedding(img.Image image) {
  try {
    return img.normalize(image, min: 0, max: 255);
  } catch (_) {
    return image;
  }
}

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

/// Ancho/alto mínimo (fracción normalizada del frame) que una detección
/// necesita para considerarse una caja real y no ruido del regressor.
///
/// Verificado con 12 fotos reales de un objeto no-COCO ("llaves"): a
/// [kCropConfThreshold] (0.15), YOLOv8n devuelve cajas de 0.001-0.003 de
/// ancho/alto normalizado — un puñado de píxeles pegados a la esquina
/// (0,0) del frame, sin relación con la posición real del objeto — en 9
/// de 12 fotos, en float32 e INT8 por igual. El umbral de confianza por sí
/// solo no filtra esto porque el problema es de tamaño/posición de la
/// caja, no de la clase asignada.
const double kMinCropBoxFraction = 0.05;

/// Como [highestConfidence], pero descarta cajas degeneradas: cualquier
/// detección cuyo ancho o alto normalizado sea menor a
/// [kMinCropBoxFraction] se ignora, porque recortar sobre ella produce un
/// crop de pocos píxeles (ruido, no el objeto) antes de reescalarlo para
/// el embedding.
Detection? bestCropCandidate(List<Detection> detections) {
  final candidates = detections.where(
    (d) => d.rect.width >= kMinCropBoxFraction && d.rect.height >= kMinCropBoxFraction,
  );
  Detection? best;
  for (final d in candidates) {
    if (best == null || d.confidence > best.confidence) best = d;
  }
  return best;
}
