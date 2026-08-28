import 'package:flutter/material.dart';

/// Colores de marca compartidos por toda la app.
///
/// Antes de este archivo, `kAuraRed` estaba copiado y pegado (público o
/// privado según el archivo) en `home_screen.dart`,
/// `multi_angle_capture_screen.dart`, `real_search_screen.dart`,
/// `save_object_screen.dart` y `search_screen.dart` — mismo valor,
/// cinco fuentes de verdad. Esta clase centraliza esos valores tal como
/// estaban (ningún color cambia de valor al migrar) para que un ajuste
/// futuro (p. ej. de contraste WCAG) se haga una sola vez.
abstract final class AuraColors {
  /// Rojo de marca. Antes `kAuraRed` / `_kAuraRed`, idéntico en los 5
  /// archivos que lo definían.
  static const Color red = Color(0xFFE53935);

  /// Verde usado para el estado "encontrado" en la búsqueda en vivo.
  /// Antes `_kAuraGreen` en `real_search_screen.dart`.
  static const Color green = Color(0xFF2E7D32);
}

/// Altura mínima de botones táctiles (WCAG 2.5.5 — objetivo de tamaño
/// mínimo). Antes duplicada como `kMinButtonHeight` / `_kMinButtonHeight`
/// en `real_search_screen.dart`, `save_object_screen.dart` y
/// `search_screen.dart`.
const double kAuraMinButtonHeight = 64;
