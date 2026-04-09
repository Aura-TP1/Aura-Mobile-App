import 'package:flutter/material.dart';
import '../services/tts.dart';

class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  final AudioFeedback _audio = AudioFeedback();
  int _currentStep = 0;
  bool _isPlayingAudio = false;

  final List<Map<String, String>> _steps = [
    {
      'step': 'PASO 1',
      'title': 'Apunta tu cámara',
      'description': 'Asegúrate de que la cámara esté apuntando hacia los objetos que deseas detectar. Mantén una buena iluminación para mejores resultados.',
    },
    {
      'step': 'PASO 2',
      'title': 'Escucha la descripción',
      'description': 'La aplicación te describirá verbalmente los objetos que detecte. También verás un recuadro con información en pantalla.',
    },
    {
      'step': 'PASO 3',
      'title': 'Controla la detección',
      'description': 'Usa los botones de Pausa/Reproducir para controlar la detección. Presiona Reset para limpiar y Guardar para registrar detecciones.',
    },
    {
      'step': 'PASO 4',
      'title': 'Consejos útiles',
      'description': 'Mantén una distancia adecuada de los objetos. Evita luz directa en la cámara. Si la app es lenta, reduce el brillo de la pantalla.',
    },
  ];

  @override
  void initState() {
    super.initState();
    _audio.init();
  }

  @override
  void dispose() {
    _audio.stop();
    super.dispose();
  }

  void _playCurrentStepAudio() {
    if (!_isPlayingAudio) {
      setState(() => _isPlayingAudio = true);
      final step = _steps[_currentStep];
      _audio
          .speak('${step['step']}. ${step['title']}. ${step['description']}')
          .then((_) {
        if (mounted) {
          setState(() => _isPlayingAudio = false);
        }
      });
    }
  }

  void _nextStep() {
    if (_currentStep < _steps.length - 1) {
      setState(() {
        _currentStep++;
        _isPlayingAudio = false;
      });
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
        _isPlayingAudio = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      const SizedBox(height: 32),
                      _buildStepIndicator(),
                      const SizedBox(height: 40),
                      _buildStepContent(),
                      const SizedBox(height: 40),
                    ],
                  ),
                ),
              ),
            ),
            _buildControls(),
          ],
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
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.arrow_back, color: Colors.white, size: 20),
            ),
          ),
          const SizedBox(width: 16),
          const Text(
            'AYUDA Y TUTORIAL',
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

  Widget _buildStepIndicator() {
    return Column(
      children: [
        Container(
          width: 100,
          height: 100,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [
                const Color(0xFFFFD700).withValues(alpha: 0.8),
                const Color(0xFFFFA500),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFD700).withValues(alpha: 0.4),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
          child: Center(
            child: _buildStepIcon(),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          _steps[_currentStep]['step']!,
          style: const TextStyle(
            color: Color(0xFFFFD700),
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 1,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _steps[_currentStep]['title']!,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildStepIcon() {
    final icons = [
      Icons.camera_alt,
      Icons.volume_up,
      Icons.videogame_asset,
      Icons.lightbulb,
    ];
    return Icon(icons[_currentStep], color: Colors.black87, size: 48);
  }

  Widget _buildStepContent() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      padding: const EdgeInsets.all(20),
      child: Text(
        _steps[_currentStep]['description']!,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
          height: 1.6,
          letterSpacing: 0.3,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withValues(alpha: 0.95), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            onTap: _isPlayingAudio ? null : _playCurrentStepAudio,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                border: Border.all(
                  color: _isPlayingAudio
                      ? const Color(0xFFFFD700)
                      : Colors.white.withValues(alpha: 0.3),
                  width: 2,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    _isPlayingAudio ? Icons.pause : Icons.volume_up,
                    color: _isPlayingAudio
                        ? const Color(0xFFFFD700)
                        : Colors.white70,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _isPlayingAudio ? 'Reproduciendo...' : 'REPRODUCIR AUDIO',
                    style: TextStyle(
                      color: _isPlayingAudio
                          ? const Color(0xFFFFD700)
                          : Colors.white70,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _previousStep,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _currentStep == 0
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.arrow_back,
                      color: _currentStep == 0
                          ? Colors.white.withValues(alpha: 0.3)
                          : Colors.white70,
                      size: 20,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GestureDetector(
                  onTap: _nextStep,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _currentStep == _steps.length - 1
                          ? Colors.white.withValues(alpha: 0.05)
                          : Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.arrow_forward,
                      color: _currentStep == _steps.length - 1
                          ? Colors.white.withValues(alpha: 0.3)
                          : Colors.white70,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).pushNamed('/camera');
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFFFFD700).withValues(alpha: 0.9),
                    const Color(0xFFFFA500),
                  ],
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFFD700).withValues(alpha: 0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  Text(
                    'EMPEZAR TUTORIAL',
                    style: TextStyle(
                      color: Colors.black87,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.arrow_forward, color: Colors.black87, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

