import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import '../models/saved_object.dart';
import '../services/app_settings.dart';
import '../services/backend_service.dart';
import '../services/google_auth_service.dart';
import '../services/metrics_logger.dart';
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
  late bool _useWatershed;
  final String _appVersion = '7.1.0 (VISTA)';
  bool _isSignedIn = false;
  String? _userEmail;
  bool _isSyncing = false;
  String? _syncStatusMessage;
  List<MetricsFileInfo>? _metricsInfo;
  List<File>? _cropImages;
  bool _isClearingMetrics = false;

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
    _useWatershed = AppSettings.instance.useWatershedSegmentation;
    _audio.init();
    _checkAuthStatus();
    _loadMetricsInfo();
    _loadCropImages();
  }

  Future<void> _loadMetricsInfo() async {
    final info = await MetricsLogger.instance.listMetricsFiles();
    if (mounted) setState(() => _metricsInfo = info);
  }

  Future<void> _loadCropImages() async {
    final images = await MetricsLogger.instance.listCropDebugImages();
    if (mounted) setState(() => _cropImages = images);
  }

  Future<void> _shareMetrics() async {
    final paths = await MetricsLogger.instance.allFilePaths();
    final existing = <XFile>[];
    for (final p in paths) {
      final f = File(p);
      if (await f.exists() && await f.length() > 0) {
        existing.add(XFile(p));
      }
    }
    if (existing.isEmpty) {
      await _audio.speak('Todavía no hay métricas guardadas para compartir.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Todavía no hay métricas guardadas.')),
        );
      }
      return;
    }
    await Share.shareXFiles(existing, text: 'Métricas de AURA');
  }

  /// Muestra las últimas líneas de un archivo de métricas directo en
  /// pantalla, con el JSON de cada registro formateado legible — antes la
  /// única forma de ver esto era compartir el archivo y abrirlo en otra
  /// app (o por cable/ADB).
  Future<void> _showMetricsFile(String fileName) async {
    final lines = await MetricsLogger.instance.readLastLines(fileName, maxLines: 20);
    if (!mounted) return;
    const encoder = JsonEncoder.withIndent('  ');
    final formatted = lines.map((line) {
      try {
        return encoder.convert(json.decode(line));
      } catch (_) {
        return line; // línea corrupta/parcial: mostrarla cruda en vez de fallar
      }
    }).toList();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e1e),
        title: Text(fileName, style: const TextStyle(color: Colors.white, fontSize: 16)),
        content: SizedBox(
          width: double.maxFinite,
          height: 420,
          child: lines.isEmpty
              ? const Text('Sin registros todavía.', style: TextStyle(color: Colors.white54))
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Últimos registros (más reciente primero):',
                        style: TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      for (final entry in formatted) ...[
                        SelectableText(
                          entry,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        const Divider(color: Colors.white24, height: 20),
                      ],
                    ],
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  void _confirmClearMetrics() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e1e),
        title: const Text('Borrar métricas', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Esto borra los 3 archivos de métricas guardados en este celular. '
          'No se puede deshacer — si querés conservarlos, compartilos primero.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              setState(() => _isClearingMetrics = true);
              await MetricsLogger.instance.deleteAllMetrics();
              await _loadMetricsInfo();
              await _loadCropImages();
              if (mounted) {
                setState(() => _isClearingMetrics = false);
                await _audio.speak('Métricas borradas.');
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Métricas borradas.')),
                );
              }
            },
            child: const Text('Borrar', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
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
              const SizedBox(height: 24),
              _buildMetricsSection(),
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
            onTap: () => Navigator.of(context).pop(),
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity( 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
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

  /// Sección "Métricas": antes la única forma de ver los .jsonl era
  /// conectar el celular por cable y leerlos a mano (ADB) — ahora se
  /// pueden compartir (share sheet nativo) o borrar directamente desde acá.
  Widget _buildMetricsSection() {
    final info = _metricsInfo;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.query_stats, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'MÉTRICAS',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            child: info == null
                ? const Text('Cargando...', style: TextStyle(color: Colors.white54))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final f in info)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '${f.fileName}: ${f.lineCount} registros',
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                ),
                              ),
                              TextButton(
                                onPressed: f.lineCount == 0
                                    ? null
                                    : () => _showMetricsFile(f.fileName),
                                child: const Text('Ver'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _shareMetrics,
            icon: const Icon(Icons.share, size: 18, color: Colors.white70),
            label: const Text('Compartir métricas', style: TextStyle(color: Colors.white70)),
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: Colors.white.withOpacity(0.2)),
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: _isClearingMetrics ? null : _confirmClearMetrics,
            icon: _isClearingMetrics
                ? const SizedBox(
                    width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.redAccent))
                : const Icon(Icons.delete_outline, size: 18, color: Colors.redAccent),
            label: Text(
              _isClearingMetrics ? 'Borrando...' : 'Borrar métricas',
              style: const TextStyle(color: Colors.redAccent),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.redAccent),
              minimumSize: const Size(double.infinity, 44),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Recortes recientes',
            style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            'Lo que realmente se recortó al guardar cada objeto — para '
            'confirmar a simple vista si agarró el objeto correcto o algo '
            'de fondo.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 10),
          _buildCropImagesGrid(),
        ],
      ),
    );
  }

  Widget _buildCropImagesGrid() {
    final images = _cropImages;
    if (images == null) {
      return const Text('Cargando...', style: TextStyle(color: Colors.white54));
    }
    if (images.isEmpty) {
      return const Text(
        'Todavía no hay recortes guardados — se guardan al guardar un objeto.',
        style: TextStyle(color: Colors.white38, fontSize: 12),
      );
    }
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: images.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final file = images[index];
          return Semantics(
            button: true,
            label: 'Ver recorte ${index + 1}',
            onTap: () => _showCropImage(file),
            child: GestureDetector(
              onTap: () => _showCropImage(file),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  file,
                  width: 84,
                  height: 84,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stack) => Container(
                    width: 84,
                    height: 84,
                    color: Colors.white10,
                    child: const Icon(Icons.broken_image, color: Colors.white38),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showCropImage(File file) {
    final name = file.uri.pathSegments.last;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1e1e1e),
        title: Text(name, style: const TextStyle(color: Colors.white, fontSize: 13)),
        content: SizedBox(
          width: double.maxFinite,
          child: Image.file(file, fit: BoxFit.contain),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cerrar', style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
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
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withOpacity(0.1)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Semantics(
              toggled: _useWatershed,
              label: 'Ceñir el recorte al objeto con watershed',
              child: Row(
                children: [
                  const Icon(Icons.crop_free, color: Colors.white70, size: 20),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Ceñir recorte (watershed)',
                            style: TextStyle(color: Colors.white, fontSize: 14)),
                        Text(
                          'Separa el objeto del fondo dentro del marco guía, sin '
                          'usar clases. Se aplica igual al guardar y al buscar. '
                          'Apágalo para comparar contra el marco guía solo.',
                          style: TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: _useWatershed,
                    onChanged: (value) {
                      setState(() => _useWatershed = value);
                      AppSettings.instance.setUseWatershedSegmentation(value);
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
