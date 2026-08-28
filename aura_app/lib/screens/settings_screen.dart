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
  late double _scanIntervalMs;
  late double _ocrDebounceMs;
  late double _ocrCooldownMs;
  late double _ttsRepeatCooldownMs;
  late double _sttListenForMs;
  late double _sttPauseForMs;
  late TextEditingController _testConditionController;
  late TextEditingController _testRunLabelController;
  late bool _useYoloInt8;
  late bool _useEmbeddingInt8;
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
    _scanIntervalMs = AppSettings.instance.scanIntervalMs;
    _ocrDebounceMs = AppSettings.instance.ocrDebounceMs;
    _ocrCooldownMs = AppSettings.instance.ocrCooldownMs;
    _ttsRepeatCooldownMs = AppSettings.instance.ttsRepeatCooldownMs;
    _sttListenForMs = AppSettings.instance.sttListenForMs;
    _sttPauseForMs = AppSettings.instance.sttPauseForMs;
    _testConditionController =
        TextEditingController(text: AppSettings.instance.testCondition);
    _testRunLabelController =
        TextEditingController(text: AppSettings.instance.testRunLabel);
    _useYoloInt8 = AppSettings.instance.useYoloInt8;
    _useEmbeddingInt8 = AppSettings.instance.useEmbeddingInt8;
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
    _testConditionController.dispose();
    _testRunLabelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: SingleChildScrollView(
          child: FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              _buildAudioSection(),
              const SizedBox(height: 24),
              _buildVisualSection(),
              const SizedBox(height: 24),
              _buildTimingSection(),
              const SizedBox(height: 24),
              _buildTestTaggingSection(),
              const SizedBox(height: 24),
              _buildModelSection(),
              const SizedBox(height: 24),
              _buildCameraSection(),
              const SizedBox(height: 24),
              _buildAdvancedSection(),
              const SizedBox(height: 40),
            ],
          ),
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
          Semantics(
            button: true,
            label: 'Volver',
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity( 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
              ),
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
                        max: 2.0,
                        divisions: 12,
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

  /// Sección "Tiempos y accesibilidad" (WCAG 2.2.1): permite ajustar los
  /// tiempos que antes estaban fijos en el código (intervalo de escaneo,
  /// debounce/cooldown de OCR y cooldown de repetición del TTS), para
  /// usuarios que necesitan más (o menos) tiempo.
  Widget _buildTimingSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.timer_outlined, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'TIEMPOS Y ACCESIBILIDAD',
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
          _buildTimingSlider(
            label: 'Velocidad de búsqueda (cámara)',
            value: _scanIntervalMs,
            min: 300,
            max: 1000,
            divisions: 7,
            unitSuffix: ' ms',
            onChanged: (value) {
              setState(() => _scanIntervalMs = value);
              AppSettings.instance.setScanIntervalMs(value);
            },
          ),
          const SizedBox(height: 16),
          _buildTimingSlider(
            label: 'Retraso antes de leer texto (OCR)',
            value: _ocrDebounceMs,
            min: 400,
            max: 2000,
            divisions: 8,
            unitSuffix: ' ms',
            onChanged: (value) {
              setState(() => _ocrDebounceMs = value);
              AppSettings.instance.setOcrDebounceMs(value);
            },
          ),
          const SizedBox(height: 16),
          _buildTimingSlider(
            label: 'Espera entre lecturas repetidas (OCR)',
            value: _ocrCooldownMs,
            min: 2000,
            max: 10000,
            divisions: 8,
            unitSuffix: ' ms',
            onChanged: (value) {
              setState(() => _ocrCooldownMs = value);
              AppSettings.instance.setOcrCooldownMs(value);
            },
          ),
          const SizedBox(height: 16),
          _buildTimingSlider(
            label: 'Espera antes de repetir un aviso de voz',
            value: _ttsRepeatCooldownMs,
            min: 1000,
            max: 8000,
            divisions: 7,
            unitSuffix: ' ms',
            onChanged: (value) {
              setState(() => _ttsRepeatCooldownMs = value);
              AppSettings.instance.setTtsRepeatCooldownMs(value);
            },
          ),
          const SizedBox(height: 16),
          _buildTimingSlider(
            label: 'Tiempo máximo para hablar un comando',
            value: _sttListenForMs,
            min: 10000,
            max: 60000,
            divisions: 10,
            unitSuffix: ' ms',
            onChanged: (value) {
              setState(() => _sttListenForMs = value);
              AppSettings.instance.setSttListenForMs(value);
            },
          ),
          const SizedBox(height: 16),
          _buildTimingSlider(
            label: 'Silencio permitido antes de dejar de escuchar',
            value: _sttPauseForMs,
            min: 2000,
            max: 10000,
            divisions: 8,
            unitSuffix: ' ms',
            onChanged: (value) {
              setState(() => _sttPauseForMs = value);
              AppSettings.instance.setSttPauseForMs(value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTimingSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String unitSuffix,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  label: label,
                  value: '${value.round()}$unitSuffix',
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: divisions,
                    onChanged: onChanged,
                    activeColor: const Color(0xFF2196F3),
                    inactiveColor: Colors.white.withOpacity(0.1),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 64,
                child: Text(
                  '${value.round()}$unitSuffix',
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Sección "Etiquetas de prueba (para métricas)": permite marcar cada
  /// intento de búsqueda con una condición de prueba (ej. fondo distinto,
  /// objetos similares) y un identificador de lote, para poder filtrar
  /// `search_metrics.jsonl` después del análisis.
  Widget _buildTestTaggingSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.science_outlined, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'ETIQUETAS DE PRUEBA (PARA MÉTRICAS)',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            'Se guarda en cada intento de búsqueda para poder filtrar los '
            'resultados después.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 16),
          _buildTestTaggingField(
            label: 'Condición de prueba',
            helperText:
                'Ej: same_background, different_background, similar_item_test',
            controller: _testConditionController,
            onChanged: (value) {
              AppSettings.instance.setTestCondition(value);
            },
          ),
          const SizedBox(height: 16),
          _buildTestTaggingField(
            label: 'Identificador de lote de pruebas',
            helperText: 'Ej: sesion_2026_07_11_a',
            controller: _testRunLabelController,
            onChanged: (value) {
              AppSettings.instance.setTestRunLabel(value);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTestTaggingField({
    required String label,
    required String helperText,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        const SizedBox(height: 8),
        Semantics(
          label: label,
          hint: helperText,
          textField: true,
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white.withOpacity(0.05),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          helperText,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ],
    );
  }

  /// Toggle para comparar el detector YOLOv8n float32 vs. la variante INT8
  /// (más liviana, ~3.3MB vs ~12.7MB). Activo por defecto mientras se
  /// valida su precisión — si empeora notablemente la detección, apágalo
  /// aquí para volver al modelo float32 original sin tocar código.
  Widget _buildModelSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.memory, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'MODELO DE DETECCIÓN',
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
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Semantics(
              toggled: _useYoloInt8,
              label: 'Usar YOLOv8n cuantizado INT8',
              child: Row(
                children: [
                  const Icon(Icons.speed, color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Usar YOLOv8n INT8',
                            style: TextStyle(color: Colors.white, fontSize: 14)),
                        Text(
                          'Modelo más liviano/rápido. Requiere reiniciar la cámara '
                          'para aplicarse. Si notas peor detección, apágalo.',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _useYoloInt8,
                    onChanged: (value) {
                      setState(() => _useYoloInt8 = value);
                      AppSettings.instance.setUseYoloInt8(value);
                    },
                    activeColor: const Color(0xFF2196F3),
                    inactiveTrackColor: Colors.white24,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Semantics(
              toggled: _useEmbeddingInt8,
              label: 'Usar embedding MobileNetV2 cuantizado INT8',
              child: Row(
                children: [
                  const Icon(Icons.blur_on, color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Usar embedding INT8',
                            style: TextStyle(color: Colors.white, fontSize: 14)),
                        Text(
                          'Reconocimiento de objetos guardados. Requiere volver a '
                          'guardar tus objetos si cambias esto luego de tenerlos '
                          'guardados con el otro modelo.',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _useEmbeddingInt8,
                    onChanged: (value) {
                      setState(() => _useEmbeddingInt8 = value);
                      AppSettings.instance.setUseEmbeddingInt8(value);
                    },
                    activeColor: const Color(0xFF2196F3),
                    inactiveTrackColor: Colors.white24,
                  ),
                ],
              ),
            ),
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
