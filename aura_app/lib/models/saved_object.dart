import 'dart:convert';
import 'dart:typed_data';

/// Representa un objeto personal guardado por el usuario.
///
/// - [name] es el nombre hablado/escrito por el usuario (ej. "Mi tomatodo").
/// - [embedding] es el vector de características extraído por MobileNetV2
///   (típicamente 1280 floats). DEPRECATED - usar [embeddings] en su lugar.
/// - [embeddings] es una lista de ObjectEmbedding con múltiples vistas del objeto
///   desde diferentes ángulos para mejor reconocimiento.
/// - [createdAt] es la fecha de guardado; se usa para ordenar y mostrar en UI.
class SavedObject {
  final int id;
  final String name;
  final List<double> embedding; // Retrocompatibilidad
  final List<ObjectEmbedding> embeddings;

  /// Banco de descriptores ORB del objeto, uno por escala (ver
  /// `orb_matcher.dart` → `buildBank`). Es una señal INDEPENDIENTE del
  /// embedding de MobileNetV2: describe parches locales alrededor de esquinas
  /// del objeto, así que no le afecta el fondo y es invariante a rotación.
  /// Se agregó porque en campo el objeto solo se reconocía sobre el mismo
  /// fondo, que es el techo de un descriptor global.
  ///
  /// Vacío en objetos guardados antes de esta versión: la búsqueda cae a la
  /// similitud coseno de siempre en ese caso.
  final List<Uint8List> orbBank;

  final DateTime createdAt;

  SavedObject({
    int? id,
    required this.name,
    this.embedding = const [],
    this.embeddings = const [],
    this.orbBank = const [],
    required this.createdAt,
  }) : id = id ?? createdAt.millisecondsSinceEpoch ~/ 1000;

  bool get hasEmbedding => embedding.isNotEmpty || embeddings.isNotEmpty;

  // Retorna todos los embeddings disponibles (tanto legacy como nuevos)
  List<List<double>> getAllEmbeddings() {
    final all = <List<double>>[];
    if (embedding.isNotEmpty) all.add(embedding);
    all.addAll(embeddings.map((e) => e.embedding));
    return all;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'embedding': embedding,
        'embeddings': embeddings.map((e) => e.toJson()).toList(),
        'orbBank': orbBank.map(base64Encode).toList(),
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

    final List<Uint8List> orb = [];
    if (json['orbBank'] is List) {
      for (final e in (json['orbBank'] as List)) {
        if (e is String && e.isNotEmpty) {
          try {
            orb.add(base64Decode(e));
          } catch (_) {
            // Un bloque corrupto no debe impedir cargar el objeto: sin ORB
            // la búsqueda sigue funcionando por similitud coseno.
          }
        }
      }
    }

    return SavedObject(
      id: json['id'] as int?,
      name: (json['name'] as String?) ?? '',
      embedding: parsed,
      embeddings: embeddingsList,
      orbBank: orb,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  SavedObject copyWith({
    int? id,
    String? name,
    List<double>? embedding,
    List<ObjectEmbedding>? embeddings,
    List<Uint8List>? orbBank,
    DateTime? createdAt,
  }) {
    return SavedObject(
      id: id ?? this.id,
      name: name ?? this.name,
      embedding: embedding ?? this.embedding,
      embeddings: embeddings ?? this.embeddings,
      orbBank: orbBank ?? this.orbBank,
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
    required this.embedding,
    required this.angleDescription,
    required this.capturedAt,
  });

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

