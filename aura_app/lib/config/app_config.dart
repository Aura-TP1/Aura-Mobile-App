import 'package:flutter/material.dart';

/// Configuración centralizada de la aplicación
/// Cambiar solo aquí cuando necesites modificar URLs u otros parámetros

class AppConfig {
  /// Clave global del Navigator — permite mostrar diálogos desde servicios
  /// sin acceso al BuildContext (e.g. cuando el token expira en BackendService).
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  // URL del backend — usar IP local de la PC (no 127.0.0.1, eso es el propio teléfono)
  static const String backendUrl = 'http://192.168.1.38:8000';

  // Endpoints de la API
  static String get apiObjectsEndpoint => '$backendUrl/api/objects';
  static String get apiSearchEndpoint => '$backendUrl/api/search';
  static String get apiHealthEndpoint => '$backendUrl/health';

  // Timeouts (en segundos)
  static const int httpTimeout = 30;
  static const int connectionTimeout = 15;

  // Versión de la app
  static const String appVersion = '7.1.0';

  // Modo debug
  static const bool debugMode = true;
}

