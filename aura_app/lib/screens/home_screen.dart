import 'dart:async';

import 'package:flutter/material.dart';
import '../services/tts.dart';

const Color kAuraRed = Color(0xFFE53935);

/// Texto del menú que el TTS repite periódicamente.
const String _kMenuSpeech =
    'Elige una opción: Qué ves, Buscar objeto, Mis objetos, o Toca para hablar.';
const String _kWelcomeSpeech = 'Hola, soy AURA. ¿Qué necesitas? $_kMenuSpeech';

/// Cada cuánto recordar el menú si el usuario está inactivo.
const Duration _kReminderInterval = Duration(seconds: 25);

/// Ventana de gracia para no pisar la voz del usuario después de tocar algo.
const Duration _kUserActionGrace = Duration(seconds: 8);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioFeedback _audio = AudioFeedback();
  Timer? _reminderTimer;
  DateTime _lastUserActionAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _audio.init();
    // Lectura inicial + loop de recordatorios. Pequeño delay para que el TTS
    // esté inicializado y no pisar la animación de entrada.
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      _audio.speak(_kWelcomeSpeech);
      _startReminderLoop();
    });
  }

  @override
  void dispose() {
    _reminderTimer?.cancel();
    _audio.stop();
    super.dispose();
  }

  void _startReminderLoop() {
    _reminderTimer?.cancel();
    _reminderTimer = Timer.periodic(_kReminderInterval, (_) {
      if (!mounted) return;
      // Pausar cuando la pantalla no está visible (usuario navegó a otra ruta).
      final route = ModalRoute.of(context);
      if (route == null || !route.isCurrent) return;
      // No pisar una acción reciente del usuario.
      final sinceAction = DateTime.now().difference(_lastUserActionAt);
      if (sinceAction < _kUserActionGrace) return;
      _audio.speak(_kMenuSpeech);
    });
  }

  Future<void> _handleMenuButtonTap(String label, String route) async {
    _lastUserActionAt = DateTime.now();
    await _audio.speak(label);
    if (!mounted) return;
    await Navigator.pushNamed(context, route);
    // De vuelta a home: re-saludar y reiniciar la ventana de gracia.
    if (!mounted) return;
    _lastUserActionAt = DateTime.now();
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    _audio.speak(_kMenuSpeech);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF2A2A2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF2A2A2A),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.menu, color: Colors.white, size: 28),
          onPressed: () {
          },
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline,
              color: Color(0xFFFFC107), size: 28),
            onPressed: () {
              Navigator.pushNamed(context, '/help');
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white, size: 28),
            onPressed: () {
              Navigator.pushNamed(context, '/settings');
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildMenuButton(
                label: '¿QUÉ\nVES?',
                icon: Icons.camera_alt,
                backgroundColor: const Color(0xFF1E88E5),
                onTap: () => _handleMenuButtonTap('¿Qué ves?', '/camera'),
              ),
              const SizedBox(height: 16),
              _buildMenuButton(
                label: 'BUSCAR\nOBJETO',
                icon: Icons.search,
                backgroundColor: const Color(0xFF00C853),
                onTap: () => _handleMenuButtonTap('Buscar objeto', '/search'),
              ),
              const SizedBox(height: 16),
              _buildMenuButton(
                label: 'MIS\nOBJETOS',
                icon: Icons.folder,
                backgroundColor: const Color(0xFF7C3AED),
                onTap: () => _handleMenuButtonTap('Mis objetos', '/my-objects'),
              ),
              const SizedBox(height: 16),
              _buildMenuButton(
                label: 'TOCA PARA\nHABLAR',
                icon: Icons.mic,
                backgroundColor: const Color(0xFF6D4C41),
                onTap: () {
                  _lastUserActionAt = DateTime.now();
                  _audio.speak('Función de voz disponible pronto');
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMenuButton({
    required String label,
    required IconData icon,
    required Color backgroundColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          height: 100,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 24),
                child: Container(
                  width: 70,
                  height: 70,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.25),
                  ),
                  child: Icon(
                    icon,
                    size: 40,
                    color: Colors.white,
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 24, right: 24),
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      height: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

