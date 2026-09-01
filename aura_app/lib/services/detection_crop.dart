import 'dart:math' as math;
import 'dart:typed_data';

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
  // `.clamp()` sobre un int devuelve `num`, no `int` — sin el `.toInt()`
  // esto no compila contra `img.copyCrop`, que exige `int` en width/height.
  final cropW = (w * fraction).round().clamp(1, w).toInt();
  final cropH = (h * fraction).round().clamp(1, h).toInt();
  final x = ((w - cropW) / 2).round();
  final y = ((h - cropH) / 2).round();
  return img.copyCrop(image, x: x, y: y, width: cropW, height: cropH);
}

/// Lado del marco guía cuadrado mostrado al usuario, como fracción del lado
/// MÁS CORTO del encuadre. El recorte que se guarda/busca usa exactamente
/// esta misma geometría (ver [cropToGuideSquare]).
const double kGuideFrameFraction = 0.6;

/// Recorta el CUADRADO centrado que corresponde al marco guía que el usuario
/// ve en pantalla.
///
/// Por qué un cuadrado y no un rectángulo con la forma del preview: la foto
/// que devuelve `takePicture()` y el widget de preview no comparten
/// necesariamente ni la relación de aspecto ni la orientación. En Android el
/// JPEG sale en orientación de sensor (apaisado) con un tag EXIF de rotación
/// que `img.decodeImage` NO aplica solo, mientras que el preview ya se ve
/// rotado a la orientación del teléfono. Recortar "el 60% del ancho y el 60%
/// del alto" de la foto daba entonces una región distinta a la que el usuario
/// tenía dentro del marco — confirmado en campo: al guardar una pastilla
/// sobre un teclado, el recorte salía apaisado y ancho, con medio teclado
/// adentro, aunque en pantalla el objeto estaba centrado en el marco.
///
/// Un cuadrado centrado de lado `fraction * min(ancho, alto)` evita el
/// problema entero: `min(ancho, alto)` no cambia al rotar la imagen 90°, así
/// que la región del mundo real que queda dentro del cuadrado es la misma
/// aunque la foto y el preview no coincidan en orientación o aspecto. Además
/// el recorte llega cuadrado a MobileNetV2, que de todas formas reescala a
/// 224x224 (ver `embedding_service_native.dart`): antes un recorte apaisado
/// se deformaba al cuadrarlo, y se deformaba distinto al guardar que al
/// buscar, lo cual metía diferencia en el embedding sin que el objeto
/// hubiera cambiado.
///
/// [fraction] debe ser EXACTAMENTE la misma que usa el marco dibujado en
/// pantalla (ver `save_object_screen.dart` / `real_search_screen.dart`).
img.Image cropToGuideSquare(img.Image photo, {double fraction = kGuideFrameFraction}) {
  final oriented = bakePhotoOrientation(photo);
  // `.clamp()` sobre un int devuelve `num`, no `int` (firma de la stdlib) —
  // sin el `.toInt()` esto no compila contra `img.copyCrop`, que exige un
  // `int` real para `width`/`height`.
  final side = (math.min(oriented.width, oriented.height) * fraction)
      .round()
      .clamp(1, math.min(oriented.width, oriented.height))
      .toInt();
  final x = ((oriented.width - side) / 2).round();
  final y = ((oriented.height - side) / 2).round();
  return img.copyCrop(oriented, x: x, y: y, width: side, height: side);
}

/// Recorta un cuadrado centrado de lado [side] píxeles.
///
/// Se usa para generar las variantes rotadas: se rota el ENCUADRE COMPLETO y
/// después se recorta de acá el cuadrado del tamaño del marco guía, en vez de
/// rotar el recorte ya hecho. Rotar un cuadrado 45° con `img.copyRotate`
/// expande el lienzo y rellena las esquinas de negro — medido: el 50% de la
/// imagen resultante queda negro. Ese aspa negra no existe en ninguna foto
/// real, así que las variantes diagonales nunca podían coincidir con el
/// objeto girado en diagonal (confirmado en campo: reconocía a 90° pero
/// nunca en diagonal). Rotando el frame completo, las esquinas del cuadrado
/// caen sobre contenido real: el cuadrado tiene media diagonal
/// `0.6 * min / 2 * raíz(2) = 0.424 * min`, dentro del círculo de radio
/// `0.5 * min` que queda garantizado con contenido real tras cualquier giro.
img.Image cropCenteredSquare(img.Image image, int side) {
  final s = side.clamp(1, math.min(image.width, image.height)).toInt();
  final x = ((image.width - s) / 2).round();
  final y = ((image.height - s) / 2).round();
  return img.copyCrop(image, x: x, y: y, width: s, height: s);
}

/// Aplica la rotación EXIF a una foto recién decodificada. `img.decodeImage`
/// deja el tag de orientación sin aplicar, así que sin esto una foto tomada
/// en vertical se procesa como si fuera apaisada.
img.Image bakePhotoOrientation(img.Image photo) {
  try {
    return img.bakeOrientation(photo);
  } catch (_) {
    return photo;
  }
}

/// Devuelve una copia del encuadre COMPLETO (ya orientado) con el marco guía
/// dibujado encima, para guardarla como imagen de depuración junto al
/// recorte real.
///
/// Sirve para responder a simple vista la pregunta "¿lo que estaba dentro del
/// marco es de verdad lo que se recortó?" — antes solo se guardaba el recorte
/// final, así que si salía mal no había forma de saber si el problema era el
/// encuadre del usuario o la geometría del recorte.
img.Image drawGuideSquareOverlay(img.Image photo, {double fraction = kGuideFrameFraction}) {
  final oriented = bakePhotoOrientation(photo);
  final canvas = oriented.clone();
  final side = (math.min(canvas.width, canvas.height) * fraction).round();
  final x = ((canvas.width - side) / 2).round();
  final y = ((canvas.height - side) / 2).round();
  final thickness = math.max(2, (math.min(canvas.width, canvas.height) * 0.006).round());
  try {
    final white = img.ColorRgb8(255, 255, 255);
    // Rectángulos concéntricos de 1px en vez de un solo `drawRect` con
    // `thickness`: el resultado visual es el mismo y solo depende de los
    // parámetros básicos de la API de `image`.
    for (var i = 0; i < thickness; i++) {
      img.drawRect(
        canvas,
        x1: x + i,
        y1: y + i,
        x2: x + side - 1 - i,
        y2: y + side - 1 - i,
        color: white,
      );
    }
  } catch (_) {
    // Dibujar el marco es solo diagnóstico: si falla, igual devolvemos el
    // encuadre completo, que ya es útil por sí solo.
  }
  return canvas;
}

/// Nitidez mínima que debe tener un recorte para que valga la pena
/// compararlo. Ver [imageSharpness] para el porqué del número.
const double kMinSharpness = 45.0;

/// Mide la nitidez de [image] como la VARIANZA DEL LAPLACIANO: cuánta
/// energía de alta frecuencia hay. Una imagen enfocada tiene bordes marcados
/// (varianza alta); una borrosa los tiene lavados (varianza baja).
///
/// Por qué se agregó, con números medidos sobre la foto real del blister: el
/// matching por puntos clave se DERRUMBA con el desenfoque normal de una
/// cámara en mano. Con el objeto al tamaño que tenía en la app:
///
/// | desenfoque | coincidencias ORB |
/// |------------|-------------------|
/// | nítido     | 180               |
/// | 0.8 px     | 10                |
/// | 1.5 px     | 0                 |
///
/// Y la tolerancia depende de cuántos píxeles tenga el objeto. Con un
/// desenfoque realista de 1.0 px:
///
/// | ancho del objeto | coincidencias | nitidez |
/// |------------------|---------------|---------|
/// | 110 px           | 3             | 33      |
/// | 260 px           | 37            | 49      |
/// | 360 px           | 43            | 73      |
///
/// El caso de 110 px reproduce exactamente los `orbMatches` de 0-7 medidos en
/// el teléfono. De ahí sale [kMinSharpness] = 45: entre el 33 que falla y el
/// 49 que funciona. El valor real se registra en las métricas de cada captura
/// y cada búsqueda, para poder recalibrarlo con datos del dispositivo en vez
/// de a ojo.
double imageSharpness(img.Image image) {
  try {
    final w = image.width;
    final h = image.height;
    if (w < 3 || h < 3) return 0;

    final gray = Float32List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        gray[y * w + x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }
    }

    var sum = 0.0;
    var sumSq = 0.0;
    var n = 0;
    for (var y = 1; y < h - 1; y++) {
      for (var x = 1; x < w - 1; x++) {
        final i = y * w + x;
        final lap = gray[i - 1] +
            gray[i + 1] +
            gray[i - w] +
            gray[i + w] -
            4 * gray[i];
        sum += lap;
        sumSq += lap * lap;
        n++;
      }
    }
    if (n == 0) return 0;
    final mean = sum / n;
    final variance = (sumSq / n) - (mean * mean);
    return variance < 0 ? 0 : variance;
  } catch (_) {
    // Nunca bloquear el guardado/búsqueda por no poder medir la nitidez.
    return double.infinity;
  }
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

/// Segmentación de primer plano SIN clases (watershed marcado): separa el
/// objeto del fondo usando solo bordes/contraste, no reconocimiento. A
/// diferencia de YOLO, no le importa si lo que está alrededor es una clase
/// COCO real (teclado, laptop) o no — solo mira dónde cambia bruscamente la
/// intensidad de la imagen.
///
/// Algoritmo (watershed por inmersión, marcado con semillas):
/// 1. Se reduce [image] a un tamaño de trabajo pequeño ([workSize]) para que
///    sea rápido en el teléfono.
/// 2. Se calcula el gradiente de Sobel en escala de grises: actúa como un
///    mapa de "elevación" donde los bordes del objeto son crestas altas.
/// 3. Se siembran dos marcadores: el centro de la imagen (primer plano —
///    ahí es donde el usuario coloca el objeto dentro del marco guía) y un
///    anillo de 2px en el borde (fondo).
/// 4. Se inunda desde ambas semillas por orden de elevación creciente (cola
///    de prioridad de 256 buckets, uno por nivel de gradiente) — cada
///    píxel se asigna a la semilla que lo alcanza primero, respetando las
///    crestas de alto gradiente como límites naturales entre regiones.
/// 5. Se calcula el bounding box de la región de primer plano resultante y
///    se recorta [image] (en su resolución original) a esa caja, con
///    padding.
///
/// Devuelve `null` si el resultado no es confiable (máscara vacía, o el
/// primer plano ocupa <2% o >85% del cuadro de trabajo) — en ese caso el
/// llamador debe seguir usando el recorte del marco guía sin segmentar,
/// para no arriesgar un recorte peor que el que ya se tenía.
///
/// Validado en un prototipo Python (Sobel + `skimage.segmentation.watershed`)
/// contra fotos reales de un llavero: aísla razonablemente bien la silueta
/// del objeto, aunque protrusiones delgadas (una llave suelta apuntando
/// hacia afuera) a veces quedan fuera de la máscara — limitación conocida
/// de watershed con semillas simples de centro/borde, mitigada por el
/// padding del bounding box y por el chequeo de fracción de área.
img.Image? segmentForeground(img.Image image, {int workSize = 160}) {
  try {
    final w = image.width;
    final h = image.height;
    if (w < 8 || h < 8) return null;

    final scale = workSize / math.max(w, h);
    final ww = math.max(1, (w * scale).round());
    final wh = math.max(1, (h * scale).round());
    final small = img.copyResize(image, width: ww, height: wh, interpolation: img.Interpolation.average);

    // 1) Escala de grises como Float32List.
    final gray = Float32List(ww * wh);
    for (var y = 0; y < wh; y++) {
      for (var x = 0; x < ww; x++) {
        final p = small.getPixel(x, y);
        gray[y * ww + x] = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      }
    }

    // 2) Gradiente de Sobel (magnitud) -> "elevación".
    final grad = Float32List(ww * wh);
    double maxGrad = 0;
    for (var y = 0; y < wh; y++) {
      for (var x = 0; x < ww; x++) {
        final gx = _sobelX(gray, x, y, ww, wh);
        final gy = _sobelY(gray, x, y, ww, wh);
        final mag = math.sqrt(gx * gx + gy * gy);
        grad[y * ww + x] = mag;
        if (mag > maxGrad) maxGrad = mag;
      }
    }
    if (maxGrad <= 0) return null;

    // 3) Marcadores: 0 = sin asignar, 1 = primer plano (centro), 2 = fondo
    // (anillo de 2px en el borde).
    const int unassigned = 0;
    const int foreground = 1;
    const int background = 2;
    final labels = Uint8List(ww * wh);

    final cx = ww ~/ 2;
    final cy = wh ~/ 2;
    final seedRadius = math.max(1, (math.min(ww, wh) * 0.06).round());
    for (var dy = -seedRadius; dy <= seedRadius; dy++) {
      for (var dx = -seedRadius; dx <= seedRadius; dx++) {
        final x = cx + dx;
        final y = cy + dy;
        if (x >= 0 && x < ww && y >= 0 && y < wh) {
          labels[y * ww + x] = foreground;
        }
      }
    }
    const int borderRing = 2;
    for (var y = 0; y < wh; y++) {
      for (var x = 0; x < ww; x++) {
        if (x < borderRing || y < borderRing || x >= ww - borderRing || y >= wh - borderRing) {
          labels[y * ww + x] = background;
        }
      }
    }

    // 4) Watershed por inmersión: cola de prioridad de 256 buckets sobre el
    // gradiente cuantizado. Cada bucket contiene los índices de píxeles con
    // ese nivel de gradiente pendientes de procesar, en orden creciente.
    final buckets = List<List<int>>.generate(256, (_) => <int>[]);
    for (var i = 0; i < ww * wh; i++) {
      if (labels[i] != unassigned) {
        // `.toInt()` por el mismo motivo que en cropToGuideSquare/centerCrop:
        // `.clamp()` devuelve `num`, y `buckets[level]` exige un índice `int`.
        final level = (grad[i] / maxGrad * 255).round().clamp(0, 255).toInt();
        buckets[level].add(i);
      }
    }

    int processed = 0;
    final total = ww * wh;
    for (var level = 0; level < 256 && processed < total; level++) {
      final queue = buckets[level];
      var qi = 0;
      while (qi < queue.length) {
        final idx = queue[qi];
        qi++;
        processed++;
        final x = idx % ww;
        final y = idx ~/ ww;
        final label = labels[idx];
        for (final n in _neighbors4(x, y, ww, wh)) {
          final nIdx = n[1] * ww + n[0];
          if (labels[nIdx] == unassigned) {
            labels[nIdx] = label;
            final nLevel = (grad[nIdx] / maxGrad * 255).round().clamp(0, 255).toInt();
            if (nLevel <= level) {
              queue.add(nIdx);
            } else {
              buckets[nLevel].add(nIdx);
            }
            processed++;
          }
        }
      }
    }

    // 5) Bounding box de la región de primer plano + chequeo de fracción de
    // área razonable.
    int minX = ww, minY = wh, maxX = -1, maxY = -1;
    int fgCount = 0;
    for (var y = 0; y < wh; y++) {
      for (var x = 0; x < ww; x++) {
        if (labels[y * ww + x] == foreground) {
          fgCount++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0 || maxY < 0) return null;
    final fgFraction = fgCount / total;
    if (fgFraction < 0.02 || fgFraction > 0.85) return null;

    // Aunque la máscara pase el filtro de área, el bounding box puede seguir
    // cubriendo casi todo el recorte de entrada (p. ej. una máscara con
    // forma de X, delgada pero que toca las cuatro esquinas). En ese caso la
    // segmentación no aporta nada — devolver el mismo recorte "ceñido" da
    // una falsa sensación de que sí se aisló el objeto, y encima lo etiqueta
    // como watershed_segmentation en las métricas. Mejor devolver null y
    // quedarse con el recorte del marco guía.
    final bboxFraction = ((maxX - minX + 1) * (maxY - minY + 1)) / total;
    if (bboxFraction > 0.92) return null;

    // Convertir bbox del tamaño de trabajo a coordenadas de la imagen
    // original, con padding.
    final invScale = 1.0 / scale;
    const double padding = 0.10;
    final boxW = (maxX - minX + 1).toDouble();
    final boxH = (maxY - minY + 1).toDouble();
    final padX = boxW * padding;
    final padY = boxH * padding;

    final left = ((minX - padX) * invScale).clamp(0.0, w.toDouble());
    final top = ((minY - padY) * invScale).clamp(0.0, h.toDouble());
    final right = ((maxX + 1 + padX) * invScale).clamp(0.0, w.toDouble());
    final bottom = ((maxY + 1 + padY) * invScale).clamp(0.0, h.toDouble());

    final cropW = (right - left).round();
    final cropH = (bottom - top).round();
    if (cropW <= 0 || cropH <= 0) return null;

    return img.copyCrop(image, x: left.round(), y: top.round(), width: cropW, height: cropH);
  } catch (_) {
    return null;
  }
}

double _sobelX(Float32List gray, int x, int y, int w, int h) {
  double v(int dx, int dy) {
    // `.toInt()` por el mismo motivo que en los demás clamp de este archivo:
    // `Float32List` exige un índice `int`, y `.clamp()` devuelve `num`.
    final xx = (x + dx).clamp(0, w - 1).toInt();
    final yy = (y + dy).clamp(0, h - 1).toInt();
    return gray[yy * w + xx];
  }
  return (v(1, -1) + 2 * v(1, 0) + v(1, 1)) - (v(-1, -1) + 2 * v(-1, 0) + v(-1, 1));
}

double _sobelY(Float32List gray, int x, int y, int w, int h) {
  double v(int dx, int dy) {
    // `.toInt()` por el mismo motivo que en los demás clamp de este archivo:
    // `Float32List` exige un índice `int`, y `.clamp()` devuelve `num`.
    final xx = (x + dx).clamp(0, w - 1).toInt();
    final yy = (y + dy).clamp(0, h - 1).toInt();
    return gray[yy * w + xx];
  }
  return (v(-1, 1) + 2 * v(0, 1) + v(1, 1)) - (v(-1, -1) + 2 * v(0, -1) + v(1, -1));
}

List<List<int>> _neighbors4(int x, int y, int w, int h) {
  final result = <List<int>>[];
  if (x > 0) result.add([x - 1, y]);
  if (x < w - 1) result.add([x + 1, y]);
  if (y > 0) result.add([x, y - 1]);
  if (y < h - 1) result.add([x, y + 1]);
  return result;
}
