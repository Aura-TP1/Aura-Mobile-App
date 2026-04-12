/// Representa un objeto personal guardado por el usuario.
///
/// - [name] es el nombre hablado/escrito por el usuario (ej. "Mi tomatodo").
/// - [embedding] es el vector de características extraído por MobileNetV2
///   (típicamente 1280 floats). Puede quedar vacío si el objeto se guardó
///   en una plataforma sin soporte TFLite (p. ej. Chrome) o si el usuario
///   migró desde la versión antigua de persistencia (solo strings).
/// - [createdAt] es la fecha de guardado; se usa para ordenar y mostrar en UI.
class SavedObject {
  final String name;
  final List<double> embedding;
  final DateTime createdAt;

  const SavedObject({
    required this.name,
    required this.embedding,
    required this.createdAt,
  });

  bool get hasEmbedding => embedding.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'name': name,
        'embedding': embedding,
        'createdAt': createdAt.toIso8601String(),
      };

  factory SavedObject.fromJson(Map<String, dynamic> json) {
    final rawEmbedding = json['embedding'];
    final List<double> parsed = rawEmbedding is List
        ? rawEmbedding.whereType<num>().map((n) => n.toDouble()).toList()
        : const [];
    return SavedObject(
      name: (json['name'] as String?) ?? '',
      embedding: parsed,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  SavedObject copyWith({
    String? name,
    List<double>? embedding,
    DateTime? createdAt,
  }) {
    return SavedObject(
      name: name ?? this.name,
      embedding: embedding ?? this.embedding,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
