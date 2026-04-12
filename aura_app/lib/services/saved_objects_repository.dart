import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/saved_object.dart';

/// Repositorio de objetos personales guardados.
///
/// - Fuente de verdad: clave [_kV2] con una lista de JSON serializados.
/// - Compatibilidad: si existe la clave legacy [_kV1] (lista de strings
///   plana, el formato anterior) y v2 está vacío, hace una migración
///   lazy one-shot copiando los nombres con embedding vacío.
/// - Toda la persistencia es local (shared_preferences). Sin red.
class SavedObjectsRepository {
  static const String _kV2 = 'aura_saved_objects_v2';
  static const String _kV1 = 'aura_saved_objects';

  Future<List<SavedObject>> getAll() async {
    final prefs = await SharedPreferences.getInstance();
    final rawList = prefs.getStringList(_kV2);

    if (rawList != null && rawList.isNotEmpty) {
      return _decodeList(rawList);
    }

    // Migración lazy desde v1 (lista plana de strings).
    final legacy = prefs.getStringList(_kV1);
    if (legacy != null && legacy.isNotEmpty) {
      final migrated = legacy
          .map((name) => SavedObject(
                name: name,
                embedding: const [],
                createdAt: DateTime.now(),
              ))
          .toList();
      await _writeAll(prefs, migrated);
      return migrated;
    }

    return <SavedObject>[];
  }

  /// Upsert: si ya existe un objeto con el mismo [SavedObject.name]
  /// (case-insensitive + trimmed), lo reemplaza; en caso contrario lo añade.
  Future<void> save(SavedObject obj) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    final normalized = obj.name.trim().toLowerCase();

    final idx = current.indexWhere(
      (o) => o.name.trim().toLowerCase() == normalized,
    );
    if (idx >= 0) {
      current[idx] = obj;
    } else {
      current.add(obj);
    }
    await _writeAll(prefs, current);
  }

  Future<void> delete(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await getAll();
    final normalized = name.trim().toLowerCase();
    current.removeWhere((o) => o.name.trim().toLowerCase() == normalized);
    await _writeAll(prefs, current);
  }

  /// Solo para debugging / pantalla de settings futura.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kV2);
  }

  // ── Internas ────────────────────────────────────────────────────────────

  List<SavedObject> _decodeList(List<String> rawList) {
    final out = <SavedObject>[];
    for (final raw in rawList) {
      try {
        final map = json.decode(raw) as Map<String, dynamic>;
        out.add(SavedObject.fromJson(map));
      } catch (_) {
        // Silenciosamente ignora entradas corruptas — mejor perder una
        // que bloquear toda la carga.
      }
    }
    return out;
  }

  Future<void> _writeAll(
    SharedPreferences prefs,
    List<SavedObject> items,
  ) async {
    final encoded = items.map((o) => json.encode(o.toJson())).toList();
    await prefs.setStringList(_kV2, encoded);
  }
}
