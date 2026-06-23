import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'google_auth_service.dart';
import '../config/app_config.dart';

/// Servicio para hacer peticiones HTTP autenticadas con Google
class BackendService {
  static final BackendService _instance = BackendService._internal();

  final http.Client _httpClient = http.Client();
  final GoogleAuthService _googleAuth = GoogleAuthService();

  factory BackendService() => _instance;
  BackendService._internal();

  // ── Headers con token (auto-refresh si está a punto de expirar) ──────────

  Future<Map<String, String>> _getHeaders() async {
    // Cargar de disco primero si no hay nada en memoria.
    // IMPORTANTE: isTokenExpired usa _authToken y _tokenExpiry en memoria;
    // si son null (reinicio de app) parecerán siempre expirados aunque no lo sean.
    if (_googleAuth.authToken == null) {
      await _googleAuth.getSavedToken();
    }

    if (_googleAuth.isTokenExpired) {
      developer.log('Token expirado o próximo a expirar — renovando...');
      final refreshed = await _googleAuth.refreshToken();
      if (!refreshed) {
        _showReloginDialog();
        throw Exception('Sesión expirada. Por favor, vuelve a iniciar sesión.');
      }
    }

    final token = _googleAuth.authToken;
    if (token == null || token.isEmpty) {
      _showReloginDialog();
      throw Exception('No hay sesión activa. Por favor, inicia sesión con Google.');
    }

    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  // ── Helper: ejecuta request y reintenta una vez si recibe 401 ────────────

  Future<http.Response> _send(Future<http.Response> Function(Map<String, String> h) call) async {
    var headers = await _getHeaders();
    var response = await call(headers);

    if (response.statusCode == 401) {
      developer.log('401 recibido — intentando renovar token y reintentar...');
      final refreshed = await _googleAuth.refreshToken();
      if (refreshed) {
        headers = await _getHeaders();
        response = await call(headers);
      }
      if (response.statusCode == 401) {
        _showReloginDialog();
        throw Exception('Sesión expirada. Por favor, vuelve a iniciar sesión.');
      }
    }

    return response;
  }

  // ── Endpoints de sincronización ──────────────────────────────────────────

  Future<Map<String, dynamic>> syncObjectsUpload(List<Map<String, dynamic>> objects) async {
    final response = await _send(
      (h) => _httpClient
          .post(
            Uri.parse('${AppConfig.backendUrl}/sync/objects/upload'),
            headers: h,
            body: jsonEncode(objects),
          )
          .timeout(const Duration(seconds: AppConfig.httpTimeout),
              onTimeout: () => throw Exception('Timeout al conectar con el servidor')),
    );

    if (response.statusCode == 200) return jsonDecode(response.body);
    final err = jsonDecode(response.body);
    throw Exception('Error ${response.statusCode}: ${err['detail'] ?? 'Error desconocido'}');
  }

  Future<List<dynamic>> getSyncedObjects() async {
    final response = await _send(
      (h) => _httpClient
          .get(
            Uri.parse('${AppConfig.backendUrl}/sync/objects/download'),
            headers: h,
          )
          .timeout(const Duration(seconds: AppConfig.httpTimeout),
              onTimeout: () => throw Exception('Timeout al conectar con el servidor')),
    );

    if (response.statusCode == 200) return jsonDecode(response.body);
    throw Exception('Error ${response.statusCode}');
  }

  Future<Map<String, dynamic>> searchObject(Map<String, dynamic> data) async {
    final response = await _send(
      (h) => _httpClient
          .post(
            Uri.parse('${AppConfig.backendUrl}/search'),
            headers: h,
            body: jsonEncode(data),
          )
          .timeout(const Duration(seconds: AppConfig.httpTimeout),
              onTimeout: () => throw Exception('Timeout al conectar con el servidor')),
    );

    if (response.statusCode == 200) return jsonDecode(response.body);
    throw Exception('Error ${response.statusCode}');
  }

  Future<dynamic> get(String endpoint) async {
    final response = await _send(
      (h) => _httpClient
          .get(Uri.parse('${AppConfig.backendUrl}$endpoint'), headers: h)
          .timeout(const Duration(seconds: AppConfig.httpTimeout),
              onTimeout: () => throw Exception('Timeout')),
    );
    if (response.statusCode == 200) return jsonDecode(response.body);
    throw Exception('Error ${response.statusCode}');
  }

  Future<dynamic> post(String endpoint, Map<String, dynamic> data) async {
    final response = await _send(
      (h) => _httpClient
          .post(
            Uri.parse('${AppConfig.backendUrl}$endpoint'),
            headers: h,
            body: jsonEncode(data),
          )
          .timeout(const Duration(seconds: AppConfig.httpTimeout),
              onTimeout: () => throw Exception('Timeout')),
    );
    if (response.statusCode == 200 || response.statusCode == 201) {
      return jsonDecode(response.body);
    }
    throw Exception('Error ${response.statusCode}');
  }

  void dispose() => _httpClient.close();

  // ── Diálogo de re-login ──────────────────────────────────────────────────

  void _showReloginDialog() {
    final context = AppConfig.navigatorKey.currentContext;
    if (context == null) return;

    // Evitar mostrar múltiples diálogos apilados
    if (ModalRoute.of(context)?.settings.name == '_relogin_dialog') return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Text('Sesión expirada'),
        content: const Text(
          'Tu sesión de Google expiró.\nVuelve a iniciar sesión para continuar.',
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _googleAuth.signIn();
            },
            child: const Text('Iniciar sesión'),
          ),
        ],
      ),
    );
  }
}
