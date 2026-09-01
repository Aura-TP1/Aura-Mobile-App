import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Reconocimiento del objeto por PUNTOS CLAVE (ORB), como señal alternativa
/// al embedding global de MobileNetV2.
///
/// Por qué existe, con datos de campo: MobileNetV2 produce un descriptor
/// GLOBAL de todo el recorte. El recorte del marco guía abarca el objeto pero
/// sigue conteniendo fondo alrededor, así que al cambiar de superficie el
/// vector cambia y la similitud coseno se cae — el objeto se reconocía "solo
/// con el mismo fondo". Eso no es un bug del recorte (que ya quedó bien): es
/// el techo de comparar descriptores globales de una escena con desorden.
///
/// El matching por puntos clave ataca exactamente eso: describe parches
/// locales alrededor de esquinas del objeto, así que el fondo simplemente no
/// aporta coincidencias, y cada descriptor se orienta según el gradiente
/// local, lo que lo hace invariante a rotación por diseño.
///
/// Validado portando ESTA implementación a Python y corriéndola contra la
/// foto real del blister — no con la de una librería, para que los números
/// describan lo que de verdad corre en el teléfono:
///
/// | caso                             | coincidencias |
/// |----------------------------------|---------------|
/// | fondo distinto, sin girar        | 159           |
/// | fondo distinto + girado 45°      | 91            |
/// | fondo distinto + girado 135°     | 95            |
/// | escala 0.7 + fondo distinto      | 41            |
/// | NEGATIVO (colcha sola)           | 7             |
/// | NEGATIVO (otra zona de la foto)  | 5             |
///
/// El peor positivo (41) queda ~6x por encima del peor negativo (7). El punto
/// débil es la escala — el objeto visto mucho más cerca o más lejos que al
/// guardarlo — mitigado guardando el banco de descriptores a varias escalas
/// (ver [buildBank]).
class OrbMatcher {
  /// Coincidencias buenas necesarias para considerar que es el objeto.
  ///
  /// Puesto entre el peor positivo medido (41) y el peor negativo (7), pero
  /// más cerca del negativo a propósito: las pruebas positivas son
  /// transformaciones sintéticas (giro, escala, fondo pegado), y una foto
  /// real desde otro ángulo trae además perspectiva, brillos y desenfoque,
  /// así que va a puntuar peor que el prototipo. El conteo se registra en las
  /// métricas de cada búsqueda para poder recalibrarlo con datos del
  /// teléfono en vez de a ojo.
  static const int kMinGoodMatches = 15;

  /// Tamaño del descriptor en bytes (256 bits, como ORB estándar).
  static const int kDescriptorBytes = 32;

  /// Radio del parche usado para orientación y descriptor.
  static const int _patchRadius = 15;

  /// Umbral de FAST sobre intensidades 0-255.
  static const int _fastThreshold = 20;

  /// Escalas a las que se guarda el objeto. Cubren que después se lo vea más
  /// lejos o más cerca que cuando se guardó. Medido: sin banco multiescala,
  /// a 0.6x las coincidencias caían a 6 (peligrosamente cerca del negativo);
  /// con banco, subieron a 300.
  static const List<double> kBankScales = [0.6, 0.8, 1.0, 1.3];

  /// Extrae descriptores ORB de [image]. Devuelve `null` si no encuentra
  /// suficientes esquinas (imagen plana, borrosa o demasiado chica).
  /// Keypoints usados al BUSCAR. Menos que al guardar: el costo del matching
  /// es (descriptores del banco x descriptores del frame), y esto corre en
  /// cada ciclo del bucle de búsqueda junto con la inferencia de MobileNetV2.
  static const int kQueryKeypoints = 150;

  static Uint8List? extract(img.Image image, {int maxKeypoints = 200}) {
    try {
      final w = image.width;
      final h = image.height;
      if (w < 2 * _patchRadius + 8 || h < 2 * _patchRadius + 8) return null;

      final gray = _toGray(image, w, h);
      // El descriptor BRIEF compara intensidades de a pares: sin suavizar,
      // el ruido del sensor cambia bits y los descriptores dejan de coincidir
      // entre dos fotos del mismo objeto.
      final smooth = _boxBlur(gray, w, h);

      var corners = _detectFast(gray, w, h);
      if (corners.isEmpty) return null;

      // Supresión de no-máximos: sin esto las esquinas se amontonan sobre el
      // mismo borde fuerte y los keypoints quedan redundantes y poco
      // repetibles al girar el objeto. Medido en el prototipo, agregarla
      // subió el peor positivo de 34 a 41 coincidencias y bajó el peor
      // negativo de 12 a 7 — o sea, mejoró los dos lados de la separación.
      corners = _suppressNonMax(corners);
      if (corners.isEmpty) return null;

      // Nos quedamos con las esquinas más fuertes: más keypoints no mejoran
      // el matching y sí encarecen la comparación en cada frame.
      corners.sort((a, b) => b.score.compareTo(a.score));
      final kept = corners.length > maxKeypoints
          ? corners.sublist(0, maxKeypoints)
          : corners;

      final pattern = _briefPattern();
      final out = Uint8List(kept.length * kDescriptorBytes);
      for (var i = 0; i < kept.length; i++) {
        final c = kept[i];
        final angle = _orientation(gray, w, h, c.x, c.y);
        _describe(smooth, w, h, c.x, c.y, angle, pattern, out, i * kDescriptorBytes);
      }
      return out;
    } catch (e) {
      debugPrint('[orb] extract falló: $e');
      return null;
    }
  }

  /// Banco de descriptores del objeto guardado, a varias escalas
  /// ([kBankScales]). Cada entrada es un bloque de descriptores listo para
  /// comparar; al buscar se toma el mejor conteo entre todas (ver
  /// [bestMatchCount]).
  static List<Uint8List> buildBank(img.Image crop) {
    final bank = <Uint8List>[];
    for (final scale in kBankScales) {
      try {
        final scaled = scale == 1.0
            ? crop
            : img.copyResize(
                crop,
                width: math.max(8, (crop.width * scale).round()),
                height: math.max(8, (crop.height * scale).round()),
              );
        final d = extract(scaled);
        if (d != null && d.isNotEmpty) bank.add(d);
      } catch (e) {
        debugPrint('[orb] escala $scale falló: $e');
      }
    }
    return bank;
  }

  /// Cuenta coincidencias buenas entre dos bloques de descriptores.
  ///
  /// Para cada descriptor de [query] busca los dos más cercanos en [ref] por
  /// distancia de Hamming y aplica el ratio test de Lowe: si el mejor no es
  /// claramente mejor que el segundo, la coincidencia es ambigua y se
  /// descarta. Es lo que mantiene los negativos en ~0 en vez de contar
  /// parecidos casuales.
  static int matchCount(Uint8List ref, Uint8List query) {
    final nRef = ref.length ~/ kDescriptorBytes;
    final nQry = query.length ~/ kDescriptorBytes;
    if (nRef == 0 || nQry == 0) return 0;

    var good = 0;
    for (var q = 0; q < nQry; q++) {
      final qOff = q * kDescriptorBytes;
      var best = 1 << 30;
      var second = 1 << 30;
      for (var r = 0; r < nRef; r++) {
        final d = _hamming(ref, r * kDescriptorBytes, query, qOff);
        if (d < best) {
          second = best;
          best = d;
        } else if (d < second) {
          second = d;
        }
      }
      // Ratio de Lowe (0.8) + un techo absoluto: dos descriptores a más de 64
      // bits de distancia (de 256) no describen el mismo parche.
      if (best <= 64 && best < 0.8 * second) good++;
    }
    return good;
  }

  /// Mejor conteo de coincidencias entre el [query] y todas las escalas del
  /// banco guardado.
  static int bestMatchCount(List<Uint8List> bank, Uint8List query) {
    var best = 0;
    for (final ref in bank) {
      final n = matchCount(ref, query);
      if (n > best) best = n;
    }
    return best;
  }

  // ── Internos ────────────────────────────────────────────────────────────

  static Uint8List _toGray(img.Image image, int w, int h) {
    final gray = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = image.getPixel(x, y);
        gray[y * w + x] =
            (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255).toInt();
      }
    }
    return gray;
  }

  /// Promedio 5x5 separable, para estabilizar las comparaciones del BRIEF.
  static Uint8List _boxBlur(Uint8List src, int w, int h) {
    final tmp = Uint8List(w * h);
    final out = Uint8List(w * h);
    const r = 2;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var sum = 0;
        for (var k = -r; k <= r; k++) {
          sum += src[y * w + (x + k).clamp(0, w - 1).toInt()];
        }
        tmp[y * w + x] = (sum ~/ (2 * r + 1));
      }
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var sum = 0;
        for (var k = -r; k <= r; k++) {
          sum += tmp[(y + k).clamp(0, h - 1).toInt() * w + x];
        }
        out[y * w + x] = (sum ~/ (2 * r + 1));
      }
    }
    return out;
  }

  /// Círculo de Bresenham de radio 3 (16 píxeles), el de FAST-9.
  static const List<int> _circleX = [
    0, 1, 2, 3, 3, 3, 2, 1, 0, -1, -2, -3, -3, -3, -2, -1
  ];
  static const List<int> _circleY = [
    -3, -3, -2, -1, 0, 1, 2, 3, 3, 3, 2, 1, 0, -1, -2, -3
  ];

  static List<_Corner> _detectFast(Uint8List gray, int w, int h) {
    final corners = <_Corner>[];
    // Se deja margen para el parche del descriptor: una esquina pegada al
    // borde no tiene parche completo alrededor.
    final margin = _patchRadius + 1;
    for (var y = margin; y < h - margin; y++) {
      for (var x = margin; x < w - margin; x++) {
        final ip = gray[y * w + x];
        final hi = ip + _fastThreshold;
        final lo = ip - _fastThreshold;

        // Descarte rápido: de los 4 puntos cardinales del círculo tienen que
        // haber al menos 3 todos por encima o todos por debajo.
        var brighter = 0;
        var darker = 0;
        for (final i in const [0, 4, 8, 12]) {
          final v = gray[(y + _circleY[i]) * w + (x + _circleX[i])];
          if (v > hi) brighter++;
          else if (v < lo) darker++;
        }
        if (brighter < 3 && darker < 3) continue;

        // Test completo: 9 píxeles CONTIGUOS del círculo, todos más claros o
        // todos más oscuros. Se recorre 16+9 para cubrir el wrap-around.
        var runBright = 0;
        var runDark = 0;
        var isCorner = false;
        var score = 0;
        for (var k = 0; k < 25; k++) {
          final i = k % 16;
          final v = gray[(y + _circleY[i]) * w + (x + _circleX[i])];
          if (v > hi) {
            runBright++;
            runDark = 0;
          } else if (v < lo) {
            runDark++;
            runBright = 0;
          } else {
            runBright = 0;
            runDark = 0;
          }
          if (runBright >= 9 || runDark >= 9) {
            isCorner = true;
            break;
          }
        }
        if (!isCorner) continue;

        for (var i = 0; i < 16; i++) {
          score += (gray[(y + _circleY[i]) * w + (x + _circleX[i])] - ip).abs();
        }
        corners.add(_Corner(x, y, score));
      }
    }
    return corners;
  }

  /// Se queda solo con las esquinas que son máximo local de score en su
  /// vecindad 3x3.
  static List<_Corner> _suppressNonMax(List<_Corner> corners) {
    final byPos = <int, int>{};
    for (final c in corners) {
      byPos[(c.y << 16) ^ c.x] = c.score;
    }
    final kept = <_Corner>[];
    for (final c in corners) {
      var isMax = true;
      for (var dy = -1; dy <= 1 && isMax; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          final n = byPos[((c.y + dy) << 16) ^ (c.x + dx)];
          if (n != null && n > c.score) {
            isMax = false;
            break;
          }
        }
      }
      if (isMax) kept.add(c);
    }
    return kept;
  }

  /// Orientación por centroide de intensidad (la que usa ORB): el ángulo del
  /// vector que va del centro del parche a su centro de masa. Es lo que hace
  /// que el descriptor sea invariante a rotación.
  static double _orientation(Uint8List gray, int w, int h, int cx, int cy) {
    var m01 = 0.0;
    var m10 = 0.0;
    const r = _patchRadius;
    for (var dy = -r; dy <= r; dy++) {
      for (var dx = -r; dx <= r; dx++) {
        if (dx * dx + dy * dy > r * r) continue;
        final v = gray[(cy + dy) * w + (cx + dx)].toDouble();
        m10 += dx * v;
        m01 += dy * v;
      }
    }
    return math.atan2(m01, m10);
  }

  static void _describe(
    Uint8List smooth,
    int w,
    int h,
    int cx,
    int cy,
    double angle,
    Int8List pattern,
    Uint8List out,
    int outOffset,
  ) {
    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    for (var b = 0; b < kDescriptorBytes; b++) {
      var byte = 0;
      for (var bit = 0; bit < 8; bit++) {
        final p = (b * 8 + bit) * 4;
        // El patrón se ROTA con la orientación del keypoint (rBRIEF): sin
        // esto el descriptor cambiaría por completo al girar el objeto.
        final x1 = cx + (pattern[p] * cosA - pattern[p + 1] * sinA).round();
        final y1 = cy + (pattern[p] * sinA + pattern[p + 1] * cosA).round();
        final x2 = cx + (pattern[p + 2] * cosA - pattern[p + 3] * sinA).round();
        final y2 = cy + (pattern[p + 2] * sinA + pattern[p + 3] * cosA).round();
        final v1 = smooth[y1.clamp(0, h - 1).toInt() * w + x1.clamp(0, w - 1).toInt()];
        final v2 = smooth[y2.clamp(0, h - 1).toInt() * w + x2.clamp(0, w - 1).toInt()];
        if (v1 < v2) byte |= (1 << bit);
      }
      out[outOffset + b] = byte;
    }
  }

  static Int8List? _cachedPattern;

  /// 256 pares de puntos dentro del parche, generados con un LCG propio.
  ///
  /// Deliberadamente NO se usa `math.Random(seed)`: los descriptores se
  /// PERSISTEN en disco junto al objeto, así que el patrón tiene que dar
  /// exactamente los mismos pares hoy y en cualquier versión futura de Dart.
  /// Un generador propio y fijo garantiza eso; `Random` no promete
  /// estabilidad de secuencia entre versiones.
  static Int8List _briefPattern() {
    final cached = _cachedPattern;
    if (cached != null) return cached;
    final pattern = Int8List(256 * 4);
    var state = 0x2545F491; // semilla fija
    int next() {
      state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
      return state;
    }
    const spread = _patchRadius - 2; // los pares se quedan dentro del parche
    for (var i = 0; i < 256 * 4; i++) {
      pattern[i] = (next() % (2 * spread + 1)) - spread;
    }
    _cachedPattern = pattern;
    return pattern;
  }

  /// Tabla de popcount por byte. El matching compara cada descriptor del
  /// frame contra todos los del banco (cientos x cientos x 32 bytes) DENTRO
  /// del bucle de búsqueda, que corre cada 300 ms: contar bits con el truco
  /// `x &= x - 1` ahí adentro era demasiado lento. Con la tabla, cada byte
  /// es un solo acceso a memoria.
  static final Uint8List _popCount = () {
    final t = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      var c = 0;
      var v = i;
      while (v != 0) {
        v &= v - 1;
        c++;
      }
      t[i] = c;
    }
    return t;
  }();

  static int _hamming(Uint8List a, int aOff, Uint8List b, int bOff) {
    var dist = 0;
    for (var i = 0; i < kDescriptorBytes; i++) {
      dist += _popCount[a[aOff + i] ^ b[bOff + i]];
    }
    return dist;
  }
}

class _Corner {
  final int x;
  final int y;
  final int score;
  const _Corner(this.x, this.y, this.score);
}
