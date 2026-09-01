import 'dart:isolate';
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
  static Future<img.Image?> toDisplayImage(
    CameraImage frame,
    CameraController controller,
  ) async {
    final image = await toImage(frame);
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
  static Future<img.Image?> toImage(CameraImage frame) async {
    try {
      if (frame.format.group == ImageFormatGroup.yuv420) {
        return await _convertYuv420(frame);
      } else if (frame.format.group == ImageFormatGroup.bgra8888) {
        return _convertBgra8888(frame);
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
  static Future<img.Image> _convertYuv420(CameraImage frame) async {
    final yPlane = frame.planes[0];
    final uPlane = frame.planes[1];
    final vPlane = frame.planes[2];

    final args = YuvConversionArgs(
      width: frame.width,
      height: frame.height,
      yStride: yPlane.bytesPerRow,
      uvStride: uPlane.bytesPerRow,
      uvPixelStride: uPlane.bytesPerPixel ?? 1,
      // Copias explícitas: los bytes de los planes viven en memoria nativa
      // gestionada por el plugin `camera` y no son seguros de compartir
      // directamente entre isolates.
      yBytes: Uint8List.fromList(yPlane.bytes),
      uBytes: Uint8List.fromList(uPlane.bytes),
      vBytes: Uint8List.fromList(vPlane.bytes),
    );

    final rgb = await Isolate.run(() => yuv420ToRgb(args));
    return img.Image.fromBytes(
      width: args.width,
      height: args.height,
      bytes: rgb.buffer,
      numChannels: 3,
    );
  }

  static img.Image _convertBgra8888(CameraImage frame) {
    return img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.planes[0].bytes.buffer,
      numChannels: 4,
      order: img.ChannelOrder.bgra,
    );
  }
}

/// Datos de entrada para la conversión YUV420→RGB en isolate. Todos los
/// campos son tipos "sendable" (primitivos + Uint8List) para poder cruzar
/// el límite del isolate sin copias implícitas costosas.
class YuvConversionArgs {
  final int width;
  final int height;
  final int yStride;
  final int uvStride;
  final int uvPixelStride;
  final Uint8List yBytes;
  final Uint8List uBytes;
  final Uint8List vBytes;

  YuvConversionArgs({
    required this.width,
    required this.height,
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
  final rgb = Uint8List(a.width * a.height * 3);
  int idx = 0;
  for (int y = 0; y < a.height; y++) {
    for (int x = 0; x < a.width; x++) {
      final yy = a.yBytes[y * a.yStride + x] - 16;
      final uvIdx = (y >> 1) * a.uvStride + (x >> 1) * a.uvPixelStride;
      final uu = a.uBytes[uvIdx] - 128;
      final vv = a.vBytes[uvIdx] - 128;
      rgb[idx++] = ((298 * yy + 409 * vv + 128) >> 8).clamp(0, 255).toInt();
      rgb[idx++] = ((298 * yy - 100 * uu - 208 * vv + 128) >> 8).clamp(0, 255).toInt();
      rgb[idx++] = ((298 * yy + 516 * uu + 128) >> 8).clamp(0, 255).toInt();
    }
  }
  return rgb;
}
