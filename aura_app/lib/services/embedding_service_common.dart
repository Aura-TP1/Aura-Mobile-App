import 'dart:math' as math;

import '../models/saved_object.dart';

/// Resultado de una búsqueda por similitud de embeddings.
class MatchResult {
  final SavedObject object;
  final double similarity;

  const MatchResult({required this.object, required this.similarity});
}

/// Similitud coseno entre dos vectores. Retorna 0.0 si los vectores
/// están vacíos, tienen longitudes distintas o alguna norma es cero.
double cosineSimilarity(List<double> a, List<double> b) {
  if (a.isEmpty || b.isEmpty || a.length != b.length) return 0.0;
  double dot = 0.0;
  double na = 0.0;
  double nb = 0.0;
  for (int i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  final denom = math.sqrt(na) * math.sqrt(nb);
  if (denom == 0) return 0.0;
  return dot / denom;
}

/// Promedia varios embeddings (mismo largo) en uno solo, componente a
/// componente. Sirve para combinar varias capturas del mismo objeto desde
/// ángulos distintos y obtener un vector más robusto a posición/iluminación.
///
/// - Ignora vectores vacíos.
/// - Si los largos no coinciden, usa el del primer vector no vacío y descarta
///   los que difieran (defensivo; en la práctica MobileNetV2 da largo fijo).
/// - Devuelve lista vacía si no hay nada que promediar.
///
/// No re-normaliza: [cosineSimilarity] ya normaliza al comparar.
List<double> averageEmbeddings(List<List<double>> embeddings) {
  final valid = embeddings.where((e) => e.isNotEmpty).toList();
  if (valid.isEmpty) return const [];
  final len = valid.first.length;
  final sum = List<double>.filled(len, 0.0);
  int count = 0;
  for (final e in valid) {
    if (e.length != len) continue;
    for (int i = 0; i < len; i++) {
      sum[i] += e[i];
    }
    count++;
  }
  if (count == 0) return const [];
  for (int i = 0; i < len; i++) {
    sum[i] /= count;
  }
  return sum;
}

/// Encuentra el [SavedObject] más similar al [query] en [saved].
///
/// - Utiliza múltiples embeddings por objeto (si existen) y toma el máximo
/// - Si existen embeddings nuevos (ObjectEmbedding), los compara todos
/// - Retrocede al embedding legacy si no hay embeddings nuevos
/// - Ignora objetos sin ningún embedding (p. ej. migrados desde
///   la v1 sin captura, o guardados en web sin ML).
/// - Devuelve `null` si la mejor similitud no supera [threshold].
MatchResult? findBestMatch(
  List<double> query,
  List<SavedObject> saved, {
  double threshold = 0.80,
}) {
  if (query.isEmpty || saved.isEmpty) return null;
  MatchResult? best;

  for (final obj in saved) {
    double bestObjSim = 0.0;

    // Primero intenta con los embeddings nuevos (múltiples ángulos)
    if (obj.embeddings.isNotEmpty) {
      for (final objEmb in obj.embeddings) {
        final sim = cosineSimilarity(query, objEmb.embedding);
        if (sim > bestObjSim) {
          bestObjSim = sim;
        }
      }
    }

    // Si no hay embeddings nuevos, usa el embedding legacy
    if (bestObjSim == 0.0 && obj.embedding.isNotEmpty) {
      bestObjSim = cosineSimilarity(query, obj.embedding);
    }

    // Actualiza el mejor match global
    if (bestObjSim > 0.0 && (best == null || bestObjSim > best.similarity)) {
      best = MatchResult(object: obj, similarity: bestObjSim);
    }
  }

  if (best == null || best.similarity < threshold) return null;
  return best;
}
