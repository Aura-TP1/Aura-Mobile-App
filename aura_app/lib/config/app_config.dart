import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Configuración centralizada de la aplicación.
///
/// La URL del backend se inyecta en tiempo de compilación:
///   Dev:  flutter run  (usa fallback → Railway)
///   Prod: flutter build apk --dart-define=BACKEND_URL=https://backend-production-e2c1.up.railway.app
///
/// Si no se pasa --dart-define, usa la IP local como fallback de desarrollo.
class AppConfig {
  /// Clave global del Navigator — permite mostrar diálogos desde servicios
  /// sin acceso al BuildContext (e.g. cuando el token expira en BackendService).
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  static const String _devFallbackUrl =
      'https://backend-production-e2c1.up.railway.app';

  /// URL base del backend. Inyectada con --dart-define=BACKEND_URL=...
  /// En release sin dart-define, lanzará un assert para forzar configuración.
  static const String backendUrl = String.fromEnvironment(
    'BACKEND_URL',
    defaultValue: _devFallbackUrl,
  );

  // Endpoints de la API
  static String get apiObjectsEndpoint => '$backendUrl/api/objects';
  static String get apiSearchEndpoint => '$backendUrl/api/search';
  static String get apiHealthEndpoint => '$backendUrl/health';

  // Timeouts (en segundos)
  static const int httpTimeout = 30;
  static const int connectionTimeout = 15;

  // Versión de la app
  static const String appVersion = '7.1.0';

  static bool get isProduction => kReleaseMode;
}
