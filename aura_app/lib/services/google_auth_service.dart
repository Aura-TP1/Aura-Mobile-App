import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:developer' as developer;

import '../config/app_config.dart';

// Los access tokens de Google expiran en 1 hora.
const _kTokenDuration = Duration(hours: 1);
// Renovar 5 minutos antes para evitar que expire justo en medio de una petición.
const _kEarlyRefreshMargin = Duration(minutes: 5);

/// Servicio de autenticación con Google para obtener token de autenticación
class GoogleAuthService {
  static final GoogleAuthService _instance = GoogleAuthService._internal();

  late GoogleSignIn _googleSignIn;
  GoogleSignInAccount? _currentUser;
  String? _authToken;
  DateTime? _tokenExpiry;
  String? _lastError;

  factory GoogleAuthService() => _instance;

  GoogleAuthService._internal() {
    _googleSignIn = GoogleSignIn(
      scopes: [
        'email',
        'profile',
        'https://www.googleapis.com/auth/userinfo.email',
      ],
      signInOption: SignInOption.standard,
    );
  }

  GoogleSignInAccount? get currentUser => _currentUser;
  String? get authToken => _authToken;
  String? get lastError => _lastError;

  bool get isAuthenticated => _authToken != null;

  /// True si el token ya expiró (o expira en menos de 5 minutos).
  bool get isTokenExpired {
    if (_authToken == null) return true;
    if (_tokenExpiry == null) return true;
    return DateTime.now().isAfter(_tokenExpiry!.subtract(_kEarlyRefreshMargin));
  }

  // ── Login ────────────────────────────────────────────────────────────────

  Future<bool> signIn() async {
    try {
      _lastError = null;
      _currentUser = await _googleSignIn.signInSilently();
      if (_currentUser == null) {
        developer.log('Iniciando Google Sign-In con diálogo...');
        _currentUser = await _googleSignIn.signIn();
      }
      if (_currentUser == null) {
        _lastError = 'Google Sign-In cancelado por el usuario';
        return false;
      }
      developer.log('Usuario Google obtenido: ${_currentUser!.email}');
      return await _fetchAndStoreToken();
    } catch (e) {
      _lastError = e.toString().contains('sign_in_canceled')
          ? 'Has cancelado el inicio de sesión'
          : 'Error al iniciar sesión: $e';
      developer.log('Error en Google Sign-In: $e', error: e);
      return false;
    }
  }

  // ── Refresh ──────────────────────────────────────────────────────────────

  /// Intenta renovar el token silenciosamente.
  /// Devuelve true si lo logró, false si necesita re-login manual.
  Future<bool> refreshToken() async {
    developer.log('Renovando token de Google...');
    try {
      _currentUser ??= await _googleSignIn.signInSilently();
      if (_currentUser == null) return false;
      return await _fetchAndStoreToken();
    } catch (e) {
      developer.log('Error al renovar token: $e');
      return false;
    }
  }

  // ── Logout ───────────────────────────────────────────────────────────────

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
      await _clearSession();
      developer.log('Usuario desconectado');
    } catch (e) {
      developer.log('Error al desconectar: $e');
    }
  }

  Future<void> revokeAccess() async {
    try {
      await _googleSignIn.disconnect();
      await _clearSession();
      developer.log('Acceso revocado');
    } catch (e) {
      developer.log('Error al revocar acceso: $e');
    }
  }

  // ── Persistencia ─────────────────────────────────────────────────────────

  /// Carga el token y su expiración guardados en disco.
  Future<String?> getSavedToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _authToken = prefs.getString('google_auth_token');
      final expiryStr = prefs.getString('google_token_expiry');
      _tokenExpiry =
          expiryStr != null ? DateTime.tryParse(expiryStr) : null;
      return _authToken;
    } catch (e) {
      developer.log('Error al obtener token guardado: $e');
      return null;
    }
  }

  Future<String?> getSavedUserEmail() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('google_user_email');
    } catch (e) {
      developer.log('Error al obtener email guardado: $e');
      return null;
    }
  }

  // ── Internos ─────────────────────────────────────────────────────────────

  Future<bool> _fetchAndStoreToken() async {
    final auth = await _currentUser!.authentication;
    final token = auth.accessToken;

    if (token == null || token.isEmpty) {
      _lastError = 'No se pudo obtener el token de acceso.';
      developer.log('Error: Access token nulo o vacío');
      return false;
    }

    _authToken = token;
    _tokenExpiry = DateTime.now().add(_kTokenDuration);

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('google_auth_token', _authToken!);
    await prefs.setString('google_user_email', _currentUser!.email);
    await prefs.setString(
        'google_token_expiry', _tokenExpiry!.toIso8601String());

    // Imprimir en consola para pruebas con Swagger / backend
    // ignore: avoid_print
    print('\n╔══════════════════════════════════════╗');
    // ignore: avoid_print
    print('║  TOKEN GOOGLE (válido ~1 hora)       ║');
    // ignore: avoid_print
    print('╚══════════════════════════════════════╝');
    // ignore: avoid_print
    print(_authToken);
    // ignore: avoid_print
    print('Expira: $_tokenExpiry\n');
    developer.log('Token listo. Expira: $_tokenExpiry');

    if (kDebugMode) _pushTokenToBackend(_authToken!);

    return true;
  }

  Future<void> _clearSession() async {
    _currentUser = null;
    _authToken = null;
    _tokenExpiry = null;
    _lastError = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('google_auth_token');
    await prefs.remove('google_user_email');
    await prefs.remove('google_token_expiry');
  }

  Future<void> _pushTokenToBackend(String token) async {
    try {
      await http.post(
        Uri.parse('${AppConfig.backendUrl}/dev/token'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'token': token}),
      );
    } catch (e) {
      developer.log('No se pudo enviar token al backend (dev): $e');
    }
  }
}
