import 'dart:async';

import 'package:flutter/material.dart';
import '../services/tts.dart';
import '../services/voice_input_service.dart';
import '../services/voice_commands.dart';
import '../widgets/voice_text_fallback_sheet.dart';

const Color kAuraRed = Color(0xFFE53935);

/// Texto del menú que el TTS repite periódicamente.
const String _kMenuSpeech =
    'Elige una opción: Encontrar objeto, Leer texto, Buscar objeto, Mis objetos, '
    'o Toca para hablar.';
const String _kWelcomeSpeech = 'Hola, soy AURA. ¿Qué necesitas? $_kMenuSpeech';

/// Cada cuánto recordar el menú si el usuario está inactivo. A lo mucho una
/// vez por minuto, para no resultar repetitivo.
const Duration _kReminderInterval = Duration(minutes: 1);

/// Ventana de gracia para no pisar la voz del usuario después de tocar algo.
const Duration _kUserActionGrace = Duration(seconds: 8);

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioFeedback _audio = AudioFeedback();
  late final VoiceInputService _voice = VoiceInputService(_audio);
  Timer? _reminderTimer;
  DateTime _lastUserActionAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _isListening = false;
  bool _showVoiceHints = false;

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
    _voice.stop();
    _audio.stop();
    _audio.dispose();
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

  Future<void> _handleMenuButtonTap(String label, String route,
      {Object? arguments}) async {
    _lastUserActionAt = DateTime.now();
    await _audio.speak(label);
    if (!mounted) return;
    await Navigator.pushNamed(context, route, arguments: arguments);
    // De vuelta a home: re-saludar y reiniciar la ventana de gracia.
    if (!mounted) return;
    _lastUserActionAt = DateTime.now();
    await Future.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    _audio.speak(_kMenuSpeech);
  }

  // ── Comando de voz global ("TOCA PARA HABLAR") ─────────────────────────
  // Fallback de 3 niveles: Google/on-device STT → Vosk offline → campo de
  // texto (solo si ambos niveles de voz fallan).
  Future<void> _handleVoiceCommand() async {
    _lastUserActionAt = DateTime.now();
    if (_isListening) {
      await _voice.stop();
      if (mounted) {
        setState(() {
          _isListening = false;
          _showVoiceHints = false;
        });
      }
      return;
    }
    setState(() {
      _isListening = true;
      _showVoiceHints = true;
    });
    await _audio.speak('Te escucho. Di un comando.');
    // Pequeña pausa para que el TTS libere el foco de audio antes de escuchar.
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    final text = await _voice.listen();
    if (!mounted) return;
    setState(() {
      _isListening = false;
      _showVoiceHints = false;
    });

    if (text != null) {
      await _routeVoiceCommand(text);
      return;
    }
    if (_voice.permanentlyDenied) {
      await _audio.speak('Necesito permiso del micrófono. Te llevo a ajustes.');
      await _voice.openSettings();
      return;
    }
    // Tier 3: ambos niveles de voz fallaron, dicta el comando por teclado.
    await _audio.speak('Escribe tu comando.');
    if (!mounted) return;
    final typed = await showVoiceTextFallbackSheet(context, hint: 'Escribe tu comando');
    if (typed != null && typed.isNotEmpty) {
      await _routeVoiceCommand(typed);
    }
  }

  Future<void> _routeVoiceCommand(String text) async {
    _lastUserActionAt = DateTime.now();
    final cmd = VoiceCommandParser.parse(text);
    switch (cmd.type) {
      case AuraCommandType.describe:
        await _audio.speak('Abriendo la cámara.');
        if (!mounted) return;
        await Navigator.pushNamed(context, '/camera');
        break;
      case AuraCommandType.readText:
        await _audio.speak('Abriendo lectura de texto.');
        if (!mounted) return;
        // Argumento 'ocr' indica a la cámara que arranque en modo lectura.
        await Navigator.pushNamed(context, '/camera', arguments: 'ocr');
        break;
      case AuraCommandType.search:
        await _audio.speak(
            cmd.argument == null ? 'Abriendo búsqueda.' : 'Buscando ${cmd.argument}.');
        if (!mounted) return;
        await Navigator.pushNamed(context, '/search', arguments: cmd.argument);
        break;
      case AuraCommandType.save:
        await _audio.speak(cmd.argument == null
            ? 'Abriendo guardar objeto.'
            : 'Guardar ${cmd.argument}.');
        if (!mounted) return;
        await Navigator.pushNamed(context, '/save-object', arguments: cmd.argument);
        break;
      case AuraCommandType.stop:
        await _audio.stop();
        break;
      case AuraCommandType.unknown:
        await _audio.speak('No entendí, intenta de nuevo.');
        break;
    }
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
      // SingleChildScrollView evita el overflow (franja amarilla) si el
      // dispositivo es bajo o tiene fuentes grandes por accesibilidad.
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildMenuButton(
                label: 'ENCONTRAR\nOBJETO',
                icon: Icons.camera_alt,
                backgroundColor: const Color(0xFF1E88E5),
                onTap: () => _handleMenuButtonTap('Encontrar objeto', '/camera'),
              ),
              const SizedBox(height: 14),
              _buildMenuButton(
                label: 'LEER\nTEXTO',
                icon: Icons.text_fields,
                backgroundColor: const Color(0xFFFB8C00),
                onTap: () => _handleMenuButtonTap('Leer texto', '/camera',
                    arguments: 'ocr'),
              ),
              const SizedBox(height: 14),
              _buildMenuButton(
                label: 'BUSCAR\nOBJETO',
                icon: Icons.search,
                backgroundColor: const Color(0xFF00C853),
                onTap: () => _handleMenuButtonTap('Buscar objeto', '/search'),
              ),
              const SizedBox(height: 14),
              _buildMenuButton(
                label: 'MIS\nOBJETOS',
                icon: Icons.folder,
                backgroundColor: const Color(0xFF7C3AED),
                onTap: () => _handleMenuButtonTap('Mis objetos', '/my-objects'),
              ),
              const SizedBox(height: 14),
              _buildMenuButton(
                label: _isListening ? 'ESCUCHANDO...' : 'TOCA PARA\nHABLAR',
                icon: _isListening ? Icons.mic : Icons.mic_none,
                backgroundColor: _isListening
                    ? const Color(0xFFD84315)
                    : const Color(0xFF6D4C41),
                onTap: _handleVoiceCommand,
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _showVoiceHints
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: _buildVoiceHintsPanel(),
                      )
                    : const SizedBox.shrink(),
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
          height: 92,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity( 0.3),
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
                    color: Colors.white.withOpacity( 0.25),
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
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
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

  Widget _buildVoiceHintsPanel() {
    final hints = <String>[
      'Aura qué ves',
      'Aura lee texto',
      'Aura busca celular',
      'Aura guarda como libro',
      'Aura para',
      'Aura detecta objetos',
      'Aura busca lentes',
    ];

    return Container(
      key: const ValueKey('voice-hints-panel'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F1F),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withOpacity(0.10)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.22),
            blurRadius: 10,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.graphic_eq, color: Color(0xFFFFC107), size: 18),
              SizedBox(width: 8),
              Text(
                'Comandos rápidos',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: hints
                .map(
                  (hint) => Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2E2E2E),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.08),
                      ),
                    ),
                    child: Text(
                      hint,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

