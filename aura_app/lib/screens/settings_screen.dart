import 'dart:convert';

import 'package:flutter/material.dart';
import '../models/saved_object.dart';
import '../services/app_settings.dart';
import '../services/backend_service.dart';
import '../services/google_auth_service.dart';
import '../services/saved_objects_repository.dart';
import '../services/tts.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AudioFeedback _audio = AudioFeedback();
  final GoogleAuthService _googleAuth = GoogleAuthService();
  final BackendService _backend = BackendService();
  final SavedObjectsRepository _repo = SavedObjectsRepository();

  late double _voiceSpeed;
  late double _volume;
  late double _fontScale;
  final String _appVersion = '7.1.0 (VISTA)';
  bool _isSignedIn = false;
  String? _userEmail;
  bool _isSyncing = false;
  String? _syncStatusMessage;

  @override
  void initState() {
    super.initState();
    _voiceSpeed = AppSettings.instance.voiceSpeed;
    _volume = AppSettings.instance.volume;
    _fontScale = AppSettings.instance.fontScale;
    _audio.init();
    _checkAuthStatus();
  }

  Future<void> _checkAuthStatus() async {
    final token = await _googleAuth.getSavedToken();
    final email = await _googleAuth.getSavedUserEmail();
    setState(() {
      _isSignedIn = token != null;
      _userEmail = email;
    });
  }

  Future<void> _handleGoogleSignIn() async {
    if (_isSignedIn) {
      // Si ya está firmado, mostrar opciones
      _showSignOutDialog();
    } else {
      // Realizar login
      setState(() => _isSyncing = true);
      await _audio.speak('Iniciando sesión con Google');

      final success = await _googleAuth.signIn();

      if (mounted) {
        setState(() => _isSyncing = false);
        if (success) {
          final email = _googleAuth.currentUser?.email ?? '';
          setState(() {
            _isSignedIn = true;
            _userEmail = email;
          });
          await _audio.speak('¡Sesión iniciada exitosamente con $email!');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Sesión iniciada como $email'),
                duration: const Duration(seconds: 3),
              ),
            );
          }
        } else {
          final errorMessage = _googleAuth.lastError ?? 'Error desconocido';
          await _audio.speak('No se pudo iniciar sesión');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error: $errorMessage'),
                duration: const Duration(seconds: 4),
                backgroundColor: Colors.red.shade700,
              ),
            );
          }
        }
      }
    }
  }

  void _showSignOutDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e1e),
        title: const Text(
          'Sesión Activa',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Sesión iniciada como: $_userEmail\n\n¿Qué deseas hacer?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Cancelar',
              style: TextStyle(color: Colors.white70),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _isSyncing = true);
              await _audio.speak('Cerrando sesión');
              await _googleAuth.signOut();
              if (mounted) {
                setState(() {
                  _isSignedIn = false;
                  _userEmail = null;
                  _isSyncing = false;
                });
                await _audio.speak('Sesión cerrada');
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Sesión cerrada'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text(
              'Cerrar Sesión',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _audio.stop();
    _audio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              _buildAudioSection(),
              const SizedBox(height: 24),
              _buildVisualSection(),
              const SizedBox(height: 24),
              _buildCameraSection(),
              const SizedBox(height: 24),
              _buildAdvancedSection(),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity( 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(width: 16),
          const Text(
            'CONFIGURACIÓN',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.mic, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'AUDIO Y VOZ',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Velocidad de Voz',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity( 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity( 0.1)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _voiceSpeed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 6,
                        onChanged: (value) {
                          setState(() => _voiceSpeed = value);
                          AppSettings.instance.setVoiceSpeed(value);
                        },
                        onChangeEnd: (_) {
                          _audio.speak('Así sonará mi voz');
                        },
                        activeColor: const Color(0xFF2196F3),
                        inactiveColor: Colors.white.withOpacity( 0.1),
                      ),
                    ),
                    Text(
                      '${_voiceSpeed.toStringAsFixed(1)}x',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Volumen',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity( 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity( 0.1)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.volume_down, color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        min: 0,
                        max: 1.0,
                        onChanged: (value) {
                          setState(() => _volume = value);
                          AppSettings.instance.setVolume(value);
                        },
                        onChangeEnd: (_) {
                          _audio.speak('Así de fuerte se escuchará');
                        },
                        activeColor: const Color(0xFF2196F3),
                        inactiveColor: Colors.white.withOpacity( 0.1),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.volume_up, color: Colors.white70, size: 18),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVisualSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.text_fields, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'VISUAL',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tamaño de Letra',
                style: TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity( 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity( 0.1)),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    const Icon(Icons.text_decrease, color: Colors.white70, size: 18),
                    Expanded(
                      child: Slider(
                        value: _fontScale,
                        min: 0.8,
                        max: 1.6,
                        divisions: 8,
                        onChanged: (value) {
                          setState(() => _fontScale = value);
                          AppSettings.instance.setFontScale(value);
                        },
                        onChangeEnd: (_) {
                          _audio.speak('Este es el nuevo tamaño de letra');
                        },
                        activeColor: const Color(0xFF2196F3),
                        inactiveColor: Colors.white.withOpacity( 0.1),
                      ),
                    ),
                    const Icon(Icons.text_increase, color: Colors.white70, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      '${(_fontScale * 100).round()}%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity( 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white.withOpacity( 0.1)),
                ),
                padding: const EdgeInsets.all(12),
                child: const Text(
                  'Así se ve el texto',
                  style: TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCameraSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.help_outline, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'AYUDA',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () {
              Navigator.of(context).pushNamed('/help');
            },
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity( 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withOpacity( 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.info, color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Ver Tutorial',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  Icon(Icons.arrow_forward_ios, color: Colors.white.withOpacity( 0.5), size: 16),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          // TEMPORAL: diagnóstico de por qué el STT offline falla en ciertos
          // equipos (ver stt_diagnostics_screen.dart). Quitar cuando ya no
          // haga falta investigar dispositivos específicos.
          GestureDetector(
            onTap: () {
              Navigator.of(context).pushNamed('/stt-diagnostics');
            },
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity( 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withOpacity( 0.1)),
              ),
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.bug_report, color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'Diagnóstico STT',
                      style: TextStyle(color: Colors.white, fontSize: 14),
                    ),
                  ),
                  Icon(Icons.arrow_forward_ios, color: Colors.white.withOpacity( 0.5), size: 16),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedSection() {
    final syncOn = AppSettings.instance.syncEnabled;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Encabezado ─────────────────────────────────────────────────
          const Row(
            children: [
              Icon(Icons.cloud_sync, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'SINCRONIZACIÓN EN LA NUBE',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Toggle "Activar Sync" ───────────────────────────────────────
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.sync, color: Colors.white70, size: 20),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Activar sincronización',
                          style: TextStyle(color: Colors.white, fontSize: 14)),
                      Text('Guarda tus objetos en la nube vinculados a tu cuenta',
                          style: TextStyle(color: Colors.white54, fontSize: 11)),
                    ],
                  ),
                ),
                Switch(
                  value: syncOn,
                  onChanged: _isSignedIn ? _onSyncToggle : null,
                  activeColor: const Color(0xFF4CAF50),
                  inactiveTrackColor: Colors.white24,
                ),
              ],
            ),
          ),

          if (!_isSignedIn) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.orange.withOpacity(0.3)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange, size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Inicia sesión con Google para habilitar la sincronización.',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 16),

          // ── Botón Google Sign-In / cuenta activa ───────────────────────
          GestureDetector(
            onTap: _isSyncing ? null : _handleGoogleSignIn,
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: _isSignedIn
                      ? [const Color(0xFF4CAF50).withOpacity(0.8),
                         const Color(0xFF45a049).withOpacity(0.8)]
                      : [const Color(0xFF2196F3).withOpacity(0.8),
                         const Color(0xFF1976D2).withOpacity(0.8)],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isSyncing)
                    const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                        strokeWidth: 2,
                      ),
                    )
                  else
                    Icon(_isSignedIn ? Icons.check_circle : Icons.login,
                        color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    _isSyncing
                        ? 'PROCESANDO...'
                        : _isSignedIn
                            ? 'CUENTA ACTIVA'
                            : 'INICIAR SESIÓN CON GOOGLE',
                    style: const TextStyle(
                      color: Colors.white, fontSize: 14,
                      fontWeight: FontWeight.w600, letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── Info de cuenta ─────────────────────────────────────────────
          if (_isSignedIn) ...[
            const SizedBox(height: 10),
            Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withOpacity(0.1)),
              ),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.person, color: Colors.white70, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Conectado como:',
                            style: TextStyle(color: Colors.white70, fontSize: 12)),
                        Text(_userEmail ?? 'Usuario',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14,
                                fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Botón "Sincronizar ahora" — sube todos los objetos locales
            if (syncOn) ...[
              const SizedBox(height: 10),
              if (_syncStatusMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(_syncStatusMessage!,
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                ),
              OutlinedButton.icon(
                onPressed: _isSyncing ? null : _syncNow,
                icon: _isSyncing
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2,
                            color: Colors.white70))
                    : const Icon(Icons.upload_rounded, size: 18, color: Colors.white70),
                label: Text(
                  _isSyncing ? 'Sincronizando...' : 'Sincronizar ahora',
                  style: const TextStyle(color: Colors.white70),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: Colors.white.withOpacity(0.2)),
                  minimumSize: const Size(double.infinity, 44),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ],

          const SizedBox(height: 24),
          Center(
            child: Text(_appVersion,
                style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _onSyncToggle(bool value) async {
    await AppSettings.instance.setSyncEnabled(value);
    setState(() {});
    await _audio.speak(value ? 'Sincronización activada' : 'Sincronización desactivada');
  }

  /// Convierte los embeddings de un objeto al formato base64 que espera el backend.
  String _encodeEmbedding(SavedObject o) {
    final data = o.embeddings.isNotEmpty
        ? o.embeddings.map((e) => e.toJson()).toList()
        : [
            {'embedding': o.embedding, 'angleDescription': 'legacy',
             'capturedAt': o.createdAt.toIso8601String()}
          ];
    return base64Encode(utf8.encode(jsonEncode(data)));
  }

  /// Sincroniza en ambos sentidos: sube los objetos locales al backend y
  /// descarga los que ya estén en la nube (p.ej. subidos desde otro
  /// teléfono con la misma cuenta), fusionándolos localmente.
  /// Este es el único momento en que la app descarga objetos del backend.
  Future<void> _syncNow() async {
    setState(() { _isSyncing = true; _syncStatusMessage = null; });
    try {
      final localObjects = await _repo.getAll();
      if (localObjects.isNotEmpty) {
        final payload = localObjects.map((o) => {
          'id': o.id,
          'name': o.name,
          'embedding': _encodeEmbedding(o),
          'thumbnail': null,
          'created_at': o.createdAt.toIso8601String(),
        }).toList();
        await _backend.syncObjectsUpload(payload);
      }

      final downloaded = await _downloadCloudObjects();
      final total = (await _repo.getAll()).length;

      if (mounted) {
        setState(() => _syncStatusMessage = total == 0
            ? 'No hay objetos para sincronizar.'
            : '✓ $total objetos en total ($downloaded descargados de la nube).');
      }
      await _audio.speak('Sincronización completada.');
    } catch (e) {
      if (mounted) setState(() => _syncStatusMessage = 'Error: $e');
      await _audio.speak('Error al sincronizar.');
    } finally {
      if (mounted) setState(() => _isSyncing = false);
    }
  }

  /// Descarga los objetos guardados en el backend y los fusiona (upsert por
  /// nombre) con el repositorio local. Devuelve cuántos objetos se bajaron.
  Future<int> _downloadCloudObjects() async {
    final raw = await _backend.getSyncedObjects();
    final cloudObjects = <SavedObject>[];
    for (final e in raw) {
      List<ObjectEmbedding> embeddings = const [];
      final embeddingB64 = e['embedding'] as String?;
      if (embeddingB64 != null && embeddingB64.isNotEmpty) {
        try {
          final bytes = base64Decode(embeddingB64);
          final jsonList = jsonDecode(utf8.decode(bytes)) as List<dynamic>;
          embeddings = jsonList
              .map((item) => ObjectEmbedding.fromJson(item as Map<String, dynamic>))
              .toList();
        } catch (_) {
          // Embedding corrupto: se omite ese objeto en la fusión.
        }
      }
      cloudObjects.add(SavedObject(
        id: e['id'] as int?,
        name: e['name'] as String,
        embeddings: embeddings,
        createdAt: DateTime.tryParse(e['created_at'] ?? '') ?? DateTime.now(),
      ));
    }
    if (cloudObjects.isNotEmpty) {
      await _repo.mergeAll(cloudObjects);
    }
    return cloudObjects.length;
  }
}
