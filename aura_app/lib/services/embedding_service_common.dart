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

/// Encuentra el [SavedObject] más similar al [query] en [saved].
///
/// - Ignora objetos cuyo `embedding` esté vacío (p. ej. migrados desde
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
    if (obj.embedding.isEmpty) continue;
    final sim = cosineSimilarity(query, obj.embedding);
    if (best == null || sim > best.similarity) {
      best = MatchResult(object: obj, similarity: sim);
    }
  }
  if (best == null || best.similarity < threshold) return null;
  return best;
}
