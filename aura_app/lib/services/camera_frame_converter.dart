import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Conversión de frames del stream de la cámara (`startImageStream`) a
/// `img.Image`.
///
/// Vivía dentro de `camera_detection_view.dart` como código privado, pero
/// ahora lo usan tres pantallas: la detección en vivo, guardar objeto y
/// buscar objeto. Motivo del cambio (ver más abajo): el frame del stream es
/// el ÚNICO que muestra exactamente lo mismo que el preview en pantalla.
///
/// Por qué importa: en Android el preview y `takePicture()` son dos streams
/// distintos del sensor, y la foto suele tener un campo de visión más ancho
/// que el preview. Un marco guía dibujado sobre el preview y un recorte
/// hecho sobre la foto NO son la misma región del mundo real — confirmado en
/// campo: con el blister entero dentro del marco en pantalla, en la foto
/// ocupaba ~57% del ancho mientras el recorte cubría ~43%, y se cortaba por
/// ambos lados. Tomando el frame del mismo stream que alimenta el preview,
/// "lo que ves es lo que se recorta" pasa a ser cierto por construcción.
class CameraFrameConverter {
  /// Convierte un frame del stream a `img.Image`, YA ROTADO a la orientación
  /// en que se ve en pantalla.
  ///
  /// Los frames llegan en orientación del sensor (apaisada), no en la del
  /// teléfono — `CameraPreview` los rota para mostrarlos. Se aplica la misma
  /// rotación acá para que el recorte guardado y el buscado compartan el
  /// mismo "arriba": MobileNetV2 no es invariante a rotación, así que un
  /// desfase de 90° entre guardar y buscar degrada la similitud coseno
  /// aunque el objeto sea el mismo.
  ///
  /// Nota: el recorte que usa la app es un cuadrado centrado, y la rotación
  /// no mueve un cuadrado centrado — solo endereza el contenido.
  ///
  /// [centerCropFraction] convierte SOLO un cuadrado centrado de lado
  /// `fracción * ladoCorto`, en vez del frame entero. Es lo que permite subir
  /// la resolución de la cámara sin que el escaneo se arrastre: el único
  /// píxel que la app usa es el del marco guía, y a 1080p convertir el frame
  /// completo son ~2 M de píxeles contra ~420 K del cuadrado guía.
  static Future<img.Image?> toDisplayImage(
    CameraImage frame,
    CameraController controller, {
    double? centerCropFraction,
    int? maxOutputSide,
  }) async {
    final image = await toImage(
      frame,
      centerCropFraction: centerCropFraction,
      maxOutputSide: maxOutputSide,
    );
    if (image == null) return null;
    final angle = controller.description.sensorOrientation;
    if (angle == 0) return image;
    try {
      return img.copyRotate(image, angle: angle);
    } catch (e) {
      debugPrint('[camera_frame] No se pudo rotar el frame: $e');
      return image;
    }
  }

  /// Convierte un frame del stream a `img.Image` en orientación de sensor.
  static Future<img.Image?> toImage(
    CameraImage frame, {
    double? centerCropFraction,
    int? maxOutputSide,
  }) async {
    try {
      if (frame.format.group == ImageFormatGroup.yuv420) {
        return await _convertYuv420(frame, centerCropFraction, maxOutputSide);
      } else if (frame.format.group == ImageFormatGroup.bgra8888) {
        return _convertBgra8888(frame, centerCropFraction, maxOutputSide);
      }
      return null;
    } catch (e) {
      debugPrint('[camera_frame] Error convirtiendo frame: $e');
      return null;
    }
  }

  // La conversión YUV420 corre en un isolate vía `Isolate.run` para no
  // bloquear el hilo principal (UI + gestos + el siguiente callback del
  // stream) mientras se procesa el frame.
  //
  // Trade-offs vs. un buffer reutilizado en el hilo principal:
  //  - No se puede reutilizar el buffer RGB entre frames: Isolate.run copia
  //    la entrada al isolate nuevo y el resultado de vuelta, así que se
  //    asigna un buffer nuevo por frame (~1 MB para 640x480). Más presión
  //    sobre el GC, pero ya no se bloquea la UI.
  //  - Isolate.run crea y destruye un isolate por llamada (~1-5 ms típico en
  //    móviles) más el costo de copiar los planes Y/U/V, que se copian
  //    explícitamente antes de cruzar el límite del isolate.
  //  - BGRA8888 (iOS) no pasa por el loop pixel-a-pixel — usa
  //    `img.Image.fromBytes` directo sobre los bytes nativos — así que se
  //    mantiene síncrono, no necesita isolate.
  static Future<img.Image> _convertYuv420(
    CameraImage frame,
    double? centerCropFraction,
    int? maxOutputSide,
  ) async {
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];

    final rect = _centerSquare(frame.width, frame.height, centerCropFraction);
    final cropX = rect[0], cropY = rect[1], cropW = rect[2], cropH = rect[3];

    final yStride = yPlane.bytesPerRow;
    final uvStride = uPlane.bytesPerRow;

    // Submuestreo: se avanza de a `step` píxeles durante la conversión, en vez
    // de convertir todo y reducir después. La cámara se pide a alta resolución
    // para tener píxeles REALES sobre el objeto, pero procesar el recorte a
    // tamaño completo multiplicaría el costo de cada pasada posterior
    // (nitidez, gris de ORB, blur, FAST) sin ganar nada.
    var step = 1;
    if (maxOutputSide != null && maxOutputSide > 0 && cropW > maxOutputSide) {
      step = (cropW / maxOutputSide).ceil();
    }
    final outW = cropW ~/ step;
    final outH = cropH ~/ step;

    // Solo se copian las FILAS del recorte, no los planos enteros. Antes se
    // copiaba el plano completo aunque se convirtiera un cuadrado chico: a
    // 1080p son ~3 MB por frame cruzando al isolate, y la mitad de la mejora
    // del recorte se perdía ahí.
    // Los límites se calculan con min/max y NO con clamp: `clamp` lanza si el
    // límite inferior queda por encima del superior, cosa que puede pasar si
    // un plano viene más corto de lo que sugieren stride y alto (padding o
    // formatos raros de algunos dispositivos). Acá un plano corto tiene que
    // degradar en un recorte más chico, no en una excepción.
    int sliceEnd(int rowStart, int rowCount, int stride, int len) {
      final start = math.min(rowStart * stride, len);
      final end = math.min((rowStart + rowCount) * stride, len);
      return math.max(start, end);
    }

    final yStart = math.min(cropY * yStride, yPlane.bytes.length);
    final yEnd = sliceEnd(cropY, cropH, yStride, yPlane.bytes.length);
    // El croma está submuestreado 2x1: las filas que hacen falta van de
    // cropY/2 hasta (cropY+cropH-1)/2 inclusive. cropY es par (ver
    // _centerSquare), así que la división es exacta.
    final uvRowStart = cropY >> 1;
    final uvRowCount = ((cropH - 1) >> 1) + 1;
    final uStart = math.min(uvRowStart * uvStride, uPlane.bytes.length);
    final uEnd = sliceEnd(uvRowStart, uvRowCount, uvStride, uPlane.bytes.length);
    final vStart = math.min(uvRowStart * uvStride, vPlane.bytes.length);
    final vEnd = sliceEnd(uvRowStart, uvRowCount, uvStride, vPlane.bytes.length);

    final args = YuvConversionArgs(
      cropX: cropX,
      cropW: cropW,
      cropH: cropH,
      outW: outW,
      outH: outH,
      step: step,
      yStride: yStride,
      uvStride: uvStride,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
      // Copias explícitas de SOLO las filas necesarias: los bytes de los
      // planos viven en memoria nativa del plugin `camera` y no son seguros
      // de compartir entre isolates.
      yBytes: Uint8List.fromList(yPlane.bytes.sublist(yStart, yEnd)),
      uBytes: Uint8List.fromList(uPlane.bytes.sublist(uStart, uEnd)),
      vBytes: Uint8List.fromList(vPlane.bytes.sublist(vStart, vEnd)),
    );

    final rgb = await Isolate.run(() => yuv420ToRgb(args));
    return img.Image.fromBytes(
      width: outW,
      height: outH,
      bytes: rgb.buffer,
      numChannels: 3,
    );
  }

  static img.Image _convertBgra8888(
    CameraImage frame,
    double? fraction,
    int? maxOutputSide,
  ) {
    final full = img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.planes[0].bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
    var out = full;
    if (fraction != null) {
      // En BGRA (iOS) no hay planos entrelazados que recortar: se convierte
      // todo y se recorta después. El ahorro no aplica, pero el resultado es
      // el mismo que en YUV.
      final r = _centerSquare(frame.width, frame.height, fraction);
      out = img.copyCrop(full, x: r[0], y: r[1], width: r[2], height: r[3]);
    }
    if (maxOutputSide != null && maxOutputSide > 0 && out.width > maxOutputSide) {
      out = img.copyResize(out, width: maxOutputSide);
    }
    return out;
  }

  /// Cuadrado centrado de lado `fracción * ladoCorto`, o el frame completo si
  /// [fraction] es null. Los offsets se fuerzan a PARES: los planos U/V están
  /// submuestreados a la mitad, así que recortar en un offset impar
  /// desalinearía el color respecto de la luminancia.
  static List<int> _centerSquare(int w, int h, double? fraction) {
    if (fraction == null) return [0, 0, w, h];
    final short = math.min(w, h);
    var side = (short * fraction).round();
    if (side.isOdd) side -= 1;
    // min/max en vez de clamp: clamp lanza si el límite inferior supera al
    // superior (frame degenerado).
    side = math.max(2, math.min(side, short));
    var x = ((w - side) ~/ 2);
    var y = ((h - side) ~/ 2);
    if (x.isOdd) x -= 1;
    if (y.isOdd) y -= 1;
    return [math.max(0, x), math.max(0, y), side, side];
  }
}

/// Datos de entrada para la conversión YUV420→RGB en isolate. Todos los
/// campos son tipos "sendable" (primitivos + Uint8List) para poder cruzar
/// el límite del isolate sin copias implícitas costosas.
class YuvConversionArgs {
  /// Columna inicial del recorte, en coordenadas del frame completo (las filas
  /// ya vienen recortadas en [yBytes]/[uBytes]/[vBytes], así que no hace falta
  /// un offset de fila).
  final int cropX;
  final int cropW;
  final int cropH;

  /// Tamaño de salida y paso de submuestreo: se toma un píxel cada [step].
  final int outW;
  final int outH;
  final int step;

  final int yStride;
  final int uvStride;
  final int uvPixelStride;
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;

  YuvConversionArgs({
    required this.cropX,
    required this.cropW,
    required this.cropH,
    required this.outW,
    required this.outH,
    required this.step,
    required this.yStride,
    required this.uvStride,
    required this.uvPixelStride,
    required this.yBytes,
    required this.uBytes,
    required this.vBytes,
  });
}

/// Función top-level ejecutada dentro del isolate de background vía
/// `Isolate.run`. Conversión YUV420 → RGB (BT.601).
Uint8List yuv420ToRgb(YuvConversionArgs a) {
  final rgb = Uint8List(a.outW * a.outH * 3);
  final yLen = a.yBytes.length;
  final uLen = a.uBytes.length;
  final vLen = a.vBytes.length;
  int idx = 0;
  for (int oy = 0; oy < a.outH; oy++) {
    // Fila relativa dentro del bloque de filas ya recortado.
    final row = oy * a.step;
    final yRowBase = row * a.yStride;
    // El croma va a la mitad de resolución; cropY es par, así que la fila de
    // croma relativa es simplemente row >> 1.
    final uvRowBase = (row >> 1) * a.uvStride;
    for (int ox = 0; ox < a.outW; ox++) {
      final x = a.cropX + ox * a.step;
      final yIdx = yRowBase + x;
      final uvIdx = uvRowBase + (x >> 1) * a.uvPixelStride;
      // Guardas: distintos dispositivos reportan strides y tamaños de plano
      // con padding, así que un índice puede caerse del buffer recortado.
      // Preferimos un píxel negro a una excepción que tire abajo el frame.
      final yy = (yIdx < yLen ? a.yBytes[yIdx] : 16) - 16;
      final uu = (uvIdx < uLen ? a.uBytes[uvIdx] : 128) - 128;
      final vv = (uvIdx < vLen ? a.vBytes[uvIdx] : 128) - 128;
      rgb[idx++] = ((298 * yy + 409 * vv + 128) >> 8).clamp(0, 255).toInt();
      rgb[idx++] = ((298 * yy - 100 * uu - 208 * vv + 128) >> 8).clamp(0, 255).toInt();
      rgb[idx++] = ((298 * yy + 516 * uu + 128) >> 8).clamp(0, 255).toInt();
    }
  }
  return rgb;
}
