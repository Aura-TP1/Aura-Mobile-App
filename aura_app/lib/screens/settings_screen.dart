import 'package:flutter/material.dart';
import '../services/app_settings.dart';
import '../services/tts.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AudioFeedback _audio = AudioFeedback();

  late double _voiceSpeed;
  late double _volume;
  late double _fontScale;
  final String _appVersion = '7.1.0 (VISTA)';

  @override
  void initState() {
    super.initState();
    _voiceSpeed = AppSettings.instance.voiceSpeed;
    _volume = AppSettings.instance.volume;
    _fontScale = AppSettings.instance.fontScale;
    _audio.init();
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
        ],
      ),
    );
  }

  Widget _buildAdvancedSection() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.settings, color: Colors.white70, size: 20),
              SizedBox(width: 8),
              Text(
                'AVANZADO',
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Datos sincronizados correctamente'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF2196F3).withOpacity( 0.8),
                    const Color(0xFF1976D2).withOpacity( 0.8),
                  ],
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 14),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.cloud_sync, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'SINCRONIZAR DATOS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: Text(
              _appVersion,
              style: TextStyle(
                color: Colors.white.withOpacity( 0.5),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
