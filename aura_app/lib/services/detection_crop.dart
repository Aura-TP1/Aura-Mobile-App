import 'dart:math' as math;

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
///
/// Entre los candidatos que pasan ese filtro, NO se elige por confianza
/// pura — se usa [_cropScore], que además premia estar centrado y penaliza
/// cajas muy grandes. Motivo (confirmado con datos reales de campo): al
/// guardar una pastilla apoyada sobre un teclado, YOLO detectaba el
/// teclado (clase COCO real, bien entrenada, alta confianza) en vez de la
/// pastilla (sin clase COCO, confianza siempre baja) — con selección por
/// confianza pura, el teclado le ganaba a la pastilla y el embedding
/// terminaba representando el objeto de fondo, no el que el usuario
/// sostenía frente a la cámara. Un objeto de fondo/mobiliario (mesa,
/// teclado, silla) suele ocupar una fracción grande del encuadre y no
/// tiene por qué estar centrado; el objeto que alguien sostiene para
/// guardarlo/buscarlo, sí.
Detection? bestCropCandidate(List<Detection> detections) {
  final candidates = detections.where(
    (d) => d.rect.width >= kMinCropBoxFraction && d.rect.height >= kMinCropBoxFraction,
  );
  Detection? best;
  double bestScore = -1;
  for (final d in candidates) {
    final score = _cropScore(d);
    if (score > bestScore) {
      bestScore = score;
      best = d;
    }
  }
  return best;
}

/// Combina confianza, qué tan centrada está la caja, y un castigo a cajas
/// que ocupan una fracción muy grande del frame. Todos los factores son
/// heurísticas, no certezas — el objetivo es dejar de tratar la confianza
/// de YOLO como la única señal válida quando hay un objeto COCO de fondo
/// compitiendo con el objeto real (no-COCO) que el usuario quiere.
double _cropScore(Detection d) {
  final cx = d.rect.left + d.rect.width / 2;
  final cy = d.rect.top + d.rect.height / 2;
  final centerDist = math.sqrt((cx - 0.5) * (cx - 0.5) + (cy - 0.5) * (cy - 0.5));
  // 1.0 si está perfectamente centrada, 0.0 si el centro de la caja está a
  // 0.5 (mitad del frame) o más lejos del centro.
  final centeredness = (1.0 - (centerDist / 0.5)).clamp(0.0, 1.0);

  // Cajas que ocupan más del 60% del ancho/alto del frame (una mesa, un
  // teclado de cerca) pierden hasta el 80% de su puntaje; por debajo de
  // eso no hay penalidad.
  final maxDim = math.max(d.rect.width, d.rect.height);
  final sizePenalty = maxDim <= 0.6
      ? 1.0
      : (1.0 - ((maxDim - 0.6) / 0.4)).clamp(0.2, 1.0);

  // La confianza sigue pesando (40% del puntaje incluso con centrado
  // perfecto), pero ya no decide sola.
  return d.confidence * (0.4 + 0.6 * centeredness) * sizePenalty;
}
