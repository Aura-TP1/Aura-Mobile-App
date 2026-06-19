/// Representa un objeto personal guardado por el usuario.
///
/// - [name] es el nombre hablado/escrito por el usuario (ej. "Mi tomatodo").
/// - [embedding] es el vector de características extraído por MobileNetV2
///   (típicamente 1280 floats). DEPRECATED - usar [embeddings] en su lugar.
/// - [embeddings] es una lista de ObjectEmbedding con múltiples vistas del objeto
///   desde diferentes ángulos para mejor reconocimiento.
/// - [createdAt] es la fecha de guardado; se usa para ordenar y mostrar en UI.
class SavedObject {
  final String name;
  final List<double> embedding; // Retrocompatibilidad
  final List<ObjectEmbedding> embeddings;
  final DateTime createdAt;

  const SavedObject({
    required this.name,
    this.embedding = const [],
    this.embeddings = const [],
    required this.createdAt,
  });

  bool get hasEmbedding => embedding.isNotEmpty || embeddings.isNotEmpty;

  // Retorna todos los embeddings disponibles (tanto legacy como nuevos)
  List<List<double>> getAllEmbeddings() {
    final all = <List<double>>[];
    if (embedding.isNotEmpty) all.add(embedding);
    all.addAll(embeddings.map((e) => e.embedding));
    return all;
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'embedding': embedding,
        'embeddings': embeddings.map((e) => e.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory SavedObject.fromJson(Map<String, dynamic> json) {
    final rawEmbedding = json['embedding'];
    final List<double> parsed = rawEmbedding is List
        ? rawEmbedding.whereType<num>().map((n) => n.toDouble()).toList()
        : const [];

    final List<ObjectEmbedding> embeddingsList = [];
    if (json['embeddings'] is List) {
      embeddingsList.addAll(
        (json['embeddings'] as List).map((e) => ObjectEmbedding.fromJson(e as Map<String, dynamic>))
      );
    }

    return SavedObject(
      name: (json['name'] as String?) ?? '',
      embedding: parsed,
      embeddings: embeddingsList,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  SavedObject copyWith({
    String? name,
    List<double>? embedding,
    List<ObjectEmbedding>? embeddings,
    DateTime? createdAt,
  }) {
    return SavedObject(
      name: name ?? this.name,
      embedding: embedding ?? this.embedding,
      embeddings: embeddings ?? this.embeddings,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// Representa un embedding de un objeto capturado desde un ángulo específico.
class ObjectEmbedding {
  final List<double> embedding;
  final String angleDescription; // "frontal", "izquierda", "derecha", "arriba", "abajo"
  final DateTime capturedAt;

  const ObjectEmbedding({
    required List<double> embedding,
    required String angleDescription,
    required DateTime capturedAt,
  })  : embedding = embedding,
        angleDescription = angleDescription,
        capturedAt = capturedAt;

  // Factory constructor para crear con DateTime.now()
  factory ObjectEmbedding.create({
    required List<double> embedding,
    required String angleDescription,
  }) =>
      ObjectEmbedding(
        embedding: embedding,
        angleDescription: angleDescription,
        capturedAt: DateTime.now(),
      );

  Map<String, dynamic> toJson() => {
        'embedding': embedding,
        'angleDescription': angleDescription,
        'capturedAt': capturedAt.toIso8601String(),
      };

  factory ObjectEmbedding.fromJson(Map<String, dynamic> json) {
    final rawEmbedding = json['embedding'];
    final List<double> parsed = rawEmbedding is List
        ? rawEmbedding.whereType<num>().map((n) => n.toDouble()).toList()
        : const [];

    return ObjectEmbedding(
      embedding: parsed,
      angleDescription: (json['angleDescription'] as String?) ?? 'desconocido',
      capturedAt: DateTime.tryParse(json['capturedAt'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

