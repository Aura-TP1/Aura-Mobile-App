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
      'step': 'BIENVENIDA',
      'title': '¿Qué es AURA?',
      'description': 'AURA es tu asistente. Te ayuda a encontrar objetos, '
          'leer textos en voz alta y recordar dónde dejaste tus cosas. '
          'Puedes usarla tocando los botones grandes, o hablando.',
    },
    {
      'step': 'PASO 1',
      'title': 'Encontrar objeto y Leer texto',
      'description': 'Con el botón Encontrar objeto, la cámara te dice qué '
          'cosas ve. Con el botón Leer texto, la cámara lee en voz alta lo '
          'que esté escrito, como una carta o una etiqueta.',
    },
    {
      'step': 'PASO 2',
      'title': 'Buscar objeto y Mis objetos',
      'description': 'Con el botón Buscar objeto puedes pedirle a AURA que '
          'te ayude a encontrar algo. Con el botón Mis objetos puedes ver '
          'la lista de las cosas que ya guardaste antes.',
    },
    {
      'step': 'PASO 3',
      'title': 'Habla con AURA',
      'description': 'Toca el botón Toca para hablar y di lo que quieres. '
          'Por ejemplo: "Aura, qué ves", "Aura, lee", "Aura, busca mis '
          'llaves", "Aura, guarda esto como mis llaves", o "Aura, para" '
          'para detener.',
    },
    {
      'step': 'PASO 4',
      'title': 'Ajustes y ayuda',
      'description': 'El ícono de engranaje abre los Ajustes, donde puedes '
          'cambiar la velocidad de la voz, el volumen y el tamaño de '
          'letra. El ícono de signo de pregunta abre este tutorial cuando '
          'lo necesites.',
    },
  ];

  @override
  void initState() {
    super.initState();
    _audio.init();
    // Lee el primer paso automáticamente al abrir el tutorial.
    Future.delayed(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      _playCurrentStepAudio();
    });
  }

  @override
  void dispose() {
    _audio.stop();
    _audio.dispose();
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
      _playCurrentStepAudio();
    }
  }

  void _previousStep() {
    if (_currentStep > 0) {
      setState(() {
        _currentStep--;
        _isPlayingAudio = false;
      });
      _playCurrentStepAudio();
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
                color: Colors.white.withOpacity( 0.1),
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
                const Color(0xFFFFD700).withOpacity( 0.8),
                const Color(0xFFFFA500),
              ],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFD700).withOpacity( 0.4),
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
      Icons.front_hand,
      Icons.camera_alt,
      Icons.folder,
      Icons.mic,
      Icons.settings,
    ];
    return Icon(icons[_currentStep], color: Colors.black87, size: 48);
  }

  Widget _buildStepContent() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withOpacity( 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withOpacity( 0.1)),
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
          colors: [Colors.black.withOpacity( 0.95), Colors.transparent],
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
                      : Colors.white.withOpacity( 0.3),
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
                          ? Colors.white.withOpacity( 0.05)
                          : Colors.white.withOpacity( 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.arrow_back,
                      color: _currentStep == 0
                          ? Colors.white.withOpacity( 0.3)
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
                          ? Colors.white.withOpacity( 0.05)
                          : Colors.white.withOpacity( 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.arrow_forward,
                      color: _currentStep == _steps.length - 1
                          ? Colors.white.withOpacity( 0.3)
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
            onTap: () => Navigator.of(context).pop(),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFFFFD700).withOpacity( 0.9),
                    const Color(0xFFFFA500),
                  ],
                ),
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFFFD700).withOpacity( 0.3),
                    blurRadius: 12,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'ENTENDIDO, VOLVER',
                    style: TextStyle(
                      color: Colors.black87,
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                  SizedBox(width: 8),
                  Icon(Icons.check, color: Colors.black87, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

