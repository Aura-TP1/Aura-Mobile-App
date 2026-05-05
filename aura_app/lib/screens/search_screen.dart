import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../models/saved_object.dart';
import '../services/saved_objects_repository.dart';
import '../services/tts.dart';
import 'real_search_screen.dart';

/// Color rojo de marca AURA.
const Color kAuraRed = Color(0xFFE53935);

/// Altura mínima de botones para accesibilidad (adultos mayores).
const double kMinButtonHeight = 64;

/// Pantalla "BUSCAR OBJETO": entrada de voz simulada, lista de objetos
/// guardados y activación de búsqueda.
class SearchObjectScreen extends StatefulWidget {
  const SearchObjectScreen({super.key});

  @override
  State<SearchObjectScreen> createState() => _SearchObjectScreenState();
}

class _SearchObjectScreenState extends State<SearchObjectScreen>
    with SingleTickerProviderStateMixin {
  static const List<String> _defaultObjects = [
    'Mi tomatodo',
    'Mis llaves',
    'Medicinas',
  ];

  final AudioFeedback _audio = AudioFeedback();
  final SpeechToText _speech = SpeechToText();
  final SavedObjectsRepository _repo = SavedObjectsRepository();
  late final AnimationController _pulseController;

  List<SavedObject> _savedObjects = const [];
  String? _currentTarget;
  bool _isListening = false;
  bool _isSearching = false;
  bool _sttAvailable = false;
  bool _gotResult = false;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _audio.init();
    _loadSavedObjects();
  }

  @override
  void dispose() {
    _speech.cancel();
    _pulseController.dispose();
    _audio.stop();
    super.dispose();
  }

  // ── Persistencia ──────────────────────────────────────────────────────
  Future<void> _loadSavedObjects() async {
    var stored = await _repo.getAll();
    // Si no hay nada en v2 ni en la lista migrada, siembra los defaults una
    // sola vez para no romper la UX que ya tenía la app antes del repo.
    if (stored.isEmpty) {
      for (final name in _defaultObjects) {
        await _repo.save(SavedObject(
          name: name,
          embedding: const [],
          createdAt: DateTime.now(),
        ));
      }
      stored = await _repo.getAll();
    }
    if (mounted) {
      setState(() => _savedObjects = stored);
    }
  }

  // ── Entrada de voz real (STT) ─────────────────────────────────────────
  Future<bool> _ensureSpeechReady() async {
    if (_sttAvailable) return true;
    if (!kIsWeb) {
      final status = await Permission.microphone.request();
      if (!status.isGranted) {
        await _audio.speak('Necesito permiso para usar el micrófono.');
        return false;
      }
    }
    _sttAvailable = await _speech.initialize(
      onStatus: _onSpeechStatus,
      onError: _onSpeechError,
    );
    if (!_sttAvailable) {
      await _audio.speak('Reconocimiento de voz no disponible.');
    }
    return _sttAvailable;
  }

  Future<void> _handleMicTap() async {
    if (_isListening) {
      await _speech.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }

    final ready = await _ensureSpeechReady();
    if (!ready) return;

    _gotResult = false;
    if (mounted) {
      setState(() {
        _isListening = true;
        _currentTarget = null;
      });
    }
    await _audio.speak('Te escucho.');

    await _speech.listen(
      onResult: _onSpeechResult,
      localeId: 'es-ES',
      listenFor: const Duration(seconds: 5),
      pauseFor: const Duration(seconds: 5),
      partialResults: false,
      cancelOnError: true,
    );
  }

  Future<void> _onSpeechResult(SpeechRecognitionResult result) async {
    // TODO: match STT result against saved objects list for fuzzy search (implement later)
    if (!result.finalResult) return;
    _gotResult = true;
    final text = result.recognizedWords.trim();
    if (text.isEmpty) {
      await _handleNoResult();
      return;
    }
    final target = _stripPossessive(text);
    if (!mounted) return;
    setState(() {
      _isListening = false;
      _currentTarget = target;
    });
    await _audio.speak('Entendí: $target. Presiona activar para buscar.');
  }

  void _onSpeechStatus(String status) {
    // When STT stops (timeout / end of speech) without a final result,
    // treat it as a silent timeout so the user gets feedback + reset.
    if (status == 'notListening' || status == 'done') {
      if (_isListening && !_gotResult) {
        _handleNoResult();
      }
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    if (_isListening) {
      _handleNoResult();
    }
  }

  Future<void> _handleNoResult() async {
    if (!mounted) return;
    setState(() => _isListening = false);
    await _audio.speak('No te escuché. Intenta de nuevo.');
  }

  // ── Activar búsqueda ──────────────────────────────────────────────────
  Future<void> _activateSearch() async {
    final target = _currentTarget;
    if (target == null || target.isEmpty) {
      await _audio.speak('Primero di o elige un objeto.');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Primero selecciona un objeto.')),
      );
      return;
    }

    setState(() => _isSearching = true);
    await _audio.speak('Buscando tus $target. Apunta la cámara al objeto.');
    if (!mounted) return;

    final idx = _savedObjects.indexWhere(
      (o) => _stripPossessive(o.name) == target,
    );
    final obj = idx >= 0
        ? _savedObjects[idx]
        : SavedObject(name: target, embedding: const [], createdAt: DateTime.now());

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RealSearchScreen(target: target, savedObject: obj),
      ),
    );

    if (!mounted) return;
    setState(() => _isSearching = false);
  }

  // ── Selección directa desde la lista ──────────────────────────────────
  Future<void> _selectFromList(SavedObject obj) async {
    // Normaliza "Mis llaves" → "llaves" para el TTS.
    final target = _stripPossessive(obj.name);
    setState(() {
      _currentTarget = target;
      _isSearching = true;
    });
    await _audio.speak('Buscando $target. Apunta la cámara al objeto.');
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RealSearchScreen(target: target, savedObject: obj),
      ),
    );

    if (!mounted) return;
    setState(() => _isSearching = false);
  }

  String _stripPossessive(String label) {
    final lower = label.toLowerCase().trim();
    const prefixes = ['mi ', 'mis ', 'el ', 'la ', 'los ', 'las '];
    for (final p in prefixes) {
      if (lower.startsWith(p)) return lower.substring(p.length);
    }
    return lower;
  }

  Future<void> _removeObject(int index) async {
    final removed = _savedObjects[index];
    await _repo.delete(removed.name);
    if (!mounted) return;
    setState(() => _savedObjects.removeAt(index));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Eliminado: ${removed.name}')),
    );
  }

  // ── UI ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFAFAFA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.black),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'BUSCAR OBJETO',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Probar cámara real',
            icon: const Icon(Icons.videocam, color: Colors.black),
            onPressed: () => Navigator.pushNamed(context, '/camera'),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              _buildMicButton(),
              const SizedBox(height: 16),
              _buildInstructionText(),
              const SizedBox(height: 20),
              _buildActivateButton(),
              const SizedBox(height: 24),
              _buildSearchStatus(),
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'O selecciona:',
                  style: TextStyle(fontSize: 16, color: Colors.black87),
                ),
              ),
              // TODO: Adding objects will be done via camera command.
              // User will point camera at an object and say "Guarda esto."
              // This requires camera + speech recognition integration — implement later.
              const SizedBox(height: 8),
              Expanded(child: _buildObjectsList()),
            ],
          ),
        ),
      ),
    );
  }

  // Botón micrófono grande con indicador de "escuchando".
  Widget _buildMicButton() {
    return Center(
      child: GestureDetector(
        onTap: _handleMicTap,
        child: AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            final scale = _isListening
                ? 1.0 + (_pulseController.value * 0.15)
                : 1.0;
            return Transform.scale(
              scale: scale,
              child: Container(
                width: 120,
                height: 120,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _isListening
                      ? kAuraRed
                      : kAuraRed.withOpacity(0.1),
                  boxShadow: _isListening
                      ? [
                          BoxShadow(
                            color: kAuraRed.withOpacity(0.35),
                            blurRadius: 30,
                            spreadRadius: 6,
                          ),
                        ]
                      : [],
                ),
                child: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                  size: 64,
                  color: _isListening ? Colors.white : kAuraRed,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildInstructionText() {
    final String text;
    if (_isListening) {
      text = 'Escuchando...';
    } else if (_currentTarget != null) {
      text = 'Objetivo: ${_currentTarget!}';
    } else {
      text = 'Di el nombre del\nobjeto a buscar';
    }
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(
        fontSize: 18,
        color: Colors.black,
        fontWeight:
            _currentTarget != null ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  Widget _buildActivateButton() {
    final enabled = _currentTarget != null && !_isListening;
    return SizedBox(
      height: kMinButtonHeight,
      child: ElevatedButton(
        onPressed: enabled ? _activateSearch : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: kAuraRed,
          disabledBackgroundColor: Colors.grey.shade300,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: const Text(
          'ACTIVAR',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchStatus() {
    if (!_isSearching || _currentTarget == null) {
      return const SizedBox.shrink();
    }
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, child) {
        return Opacity(
          opacity: 0.6 + (_pulseController.value * 0.4),
          child: child,
        );
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        decoration: BoxDecoration(
          color: kAuraRed.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kAuraRed, width: 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search, color: kAuraRed),
            const SizedBox(width: 10),
            Text(
              'Buscando: ${_currentTarget!}...',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: kAuraRed,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildObjectsList() {
    if (_savedObjects.isEmpty) {
      return const Center(
        child: Text(
          'No tienes objetos guardados.\nVe a Mis objetos para añadir uno.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black54, fontSize: 16),
        ),
      );
    }
    return ListView.separated(
      itemCount: _savedObjects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final obj = _savedObjects[index];
        return Dismissible(
          key: ValueKey('saved_${index}_${obj.name}'),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            decoration: BoxDecoration(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => _removeObject(index),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _selectFromList(obj),
            child: Container(
              height: kMinButtonHeight,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: kAuraRed, width: 2.5),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      obj.name,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
