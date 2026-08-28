import 'package:flutter/material.dart';

/// Colores de marca compartidos por toda la app — la paleta "llamativa"
/// (azul, amarillo, verde, morado, rojo) que ya se usaba en los botones de
/// la pantalla principal, ahora como estándar para toda la app, junto con
/// el fondo gris de esa misma pantalla.
///
/// Todos los pares color-de-fondo + texto-blanco fueron verificados contra
/// WCAG 1.4.3 (4.5:1 mínimo para texto normal, el mismo criterio que ya se
/// usaba en `home_screen.dart`):
///   - [blue]   vs blanco: 4.51:1
///   - [green]  vs blanco: 4.59:1
///   - [purple] vs blanco: 5.70:1
///   - [red]    vs blanco: 4.98:1
///   - [redActive] vs blanco: 6.57:1
/// [yellow] es una excepción deliberada: cualquier amarillo vívido es
/// demasiado claro para dar 4.5:1 con texto blanco. Se empareja con texto
/// NEGRO en su lugar (12.88:1), el patrón estándar de accesibilidad para
/// fondos amarillos — ver su uso en `home_screen.dart`.
abstract final class AuraColors {
  /// Antes `kAuraRed` / `_kAuraRed` = 0xFFE53935, copiado en 5 archivos.
  /// Se sube a 0xFFD32F2F: el valor anterior daba solo 4.23:1 con texto
  /// blanco (por debajo del propio estándar 4.5:1 de la app) y ya se usaba
  /// como fondo de botón con texto blanco en 4 pantallas (ACTIVAR, mic).
  static const Color red = Color(0xFFD32F2F);

  /// Rojo más profundo para estados "activo" (p. ej. "ESCUCHANDO...")
  /// que necesitan distinguirse visualmente de [red] sin dejar de leerse
  /// como parte de la misma familia de color.
  static const Color redActive = Color(0xFFB71C1C);

  /// Antes inline en `home_screen.dart` (botón "Encontrar objeto").
  static const Color blue = Color(0xFF1B79CC);

  /// Amarillo vívido — ver nota de contraste arriba: usar con texto/ícono
  /// NEGRO, no blanco.
  static const Color yellow = Color(0xFFFFC107);

  /// Antes inline en `home_screen.dart` (botón "Buscar objeto").
  static const Color green = Color(0xFF008838);

  /// Antes inline en `home_screen.dart` (botón "Mis objetos").
  static const Color purple = Color(0xFF7C3AED);

  /// Verde de estado "encontrado" en la búsqueda en vivo — antes
  /// `_kAuraGreen` en `real_search_screen.dart`. Deliberadamente distinto
  /// de [green]: es un indicador funcional (éxito de búsqueda), no un
  /// color de marca/menú, así que no se unifica con él.
  static const Color foundGreen = Color(0xFF2E7D32);

  /// Fondo gris estándar de la app — antes solo en `home_screen.dart`,
  /// ahora el fondo por defecto (ver `ThemeData.scaffoldBackgroundColor`
  /// en `main.dart`).
  static const Color background = Color(0xFF2A2A2A);

  /// Superficie para tarjetas, filas de lista y app bars sobre
  /// [background] — reutiliza el tono ya usado en el panel de comandos de
  /// voz de `home_screen.dart` (`_buildVoiceHintsPanel`).
  static const Color surface = Color(0xFF1F1F1F);
}

/// Altura mínima de botones táctiles (WCAG 2.5.5 — objetivo de tamaño
/// mínimo). Antes duplicada como `kMinButtonHeight` / `_kMinButtonHeight`
/// en `real_search_screen.dart`, `save_object_screen.dart` y
/// `search_screen.dart`.
const double kAuraMinButtonHeight = 64;
