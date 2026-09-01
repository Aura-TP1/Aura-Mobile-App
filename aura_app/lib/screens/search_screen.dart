import 'dart:async';

import 'package:flutter/material.dart';

import '../models/saved_object.dart';
import '../services/saved_objects_repository.dart';
import '../services/voice_input_service.dart';
import '../services/tts.dart';
import '../theme/aura_colors.dart';
import 'real_search_screen.dart';

const Color kAuraRed = AuraColors.red;

/// Altura mínima de botones para accesibilidad (adultos mayores).
const double kMinButtonHeight = kAuraMinButtonHeight;

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
  late final VoiceInputService _voice = VoiceInputService(_audio);
  final SavedObjectsRepository _repo = SavedObjectsRepository();
  late final AnimationController _pulseController;
  final TextEditingController _targetController = TextEditingController();
  final FocusNode _targetFocus = FocusNode();

  List<SavedObject> _savedObjects = const [];
  String? _currentTarget;
  bool _isListening = false;
  bool _isSearching = false;
  bool _handledArgs = false;

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Si llegamos por comando de voz "Aura busca X", pre-seleccionamos X.
    if (_handledArgs) return;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is String && args.trim().isNotEmpty) {
      _handledArgs = true;
      final target = _stripPossessive(args);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _currentTarget = target);
        _audio.speak('Entendí: $target. Presiona activar para buscar.');
      });
    } else {
      _handledArgs = true;
    }
  }

  @override
  void dispose() {
    _voice.stop();
    _pulseController.dispose();
    _targetController.dispose();
    _targetFocus.dispose();
    _audio.stop();
    _audio.dispose();
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

  // ── Entrada de voz (fallback de 3 niveles: Google → Vosk → texto) ─────
  Future<void> _handleMicTap() async {
    if (_isListening) {
      await _voice.stop();
      if (mounted) setState(() => _isListening = false);
      return;
    }
    if (mounted) {
      setState(() {
        _isListening = true;
        _currentTarget = null;
      });
    }
    await _audio.speak('Te escucho.');
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;

    final text = await _voice.listen();
    if (!mounted) return;
    setState(() => _isListening = false);

    if (text != null) {
      final target = _stripPossessive(text);
      setState(() => _currentTarget = target);
      await _audio.speak('Entendí: $target. Presiona activar para buscar.');
      return;
    }
    if (_voice.permanentlyDenied) {
      await _audio.speak('Necesito permiso del micrófono. Te llevo a ajustes.');
      await _voice.openSettings();
      return;
    }
    // Tier 3: ambos niveles de voz fallaron, dicta por teclado.
    await _audio.speak('Escribe el nombre del objeto.');
    if (mounted) FocusScope.of(context).requestFocus(_targetFocus);
  }

  // ── Confirmar objetivo escrito a mano (Tier 3) ─────────────────────────
  Future<void> _handleTargetTyped(String value) async {
    final v = value.trim();
    if (v.isEmpty) return;
    final target = _stripPossessive(v);
    setState(() => _currentTarget = target);
    await _audio.speak('Entendí: $target. Presiona activar para buscar.');
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

    // Primero busca coincidencia exacta (sin artículos), luego por substring.
    // Así "llaves" encuentra "Mis llaves", y "tomatodo" encuentra "Mi tomatodo".
    int idx = _savedObjects.indexWhere(
      (o) => _stripPossessive(o.name) == target,
    );
    if (idx < 0) {
      idx = _savedObjects.indexWhere(
        (o) => _stripPossessive(o.name).contains(target) ||
               target.contains(_stripPossessive(o.name)),
      );
    }
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
      backgroundColor: AuraColors.background,
      appBar: AppBar(
        backgroundColor: AuraColors.surface,
        elevation: 0,
        leading: IconButton(
          tooltip: 'Volver',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
          onPressed: () => Navigator.maybePop(context),
        ),
        title: const Text(
          'BUSCAR MI OBJETO',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: FocusTraversalGroup(
            policy: OrderedTraversalPolicy(),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: _buildMicButton(),
              ),
              const SizedBox(height: 16),
              _buildInstructionText(),
              const SizedBox(height: 16),
              FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: _buildTargetInput(),
              ),
              const SizedBox(height: 20),
              FocusTraversalOrder(
                order: const NumericFocusOrder(3),
                child: _buildActivateButton(),
              ),
              const SizedBox(height: 24),
              _buildSearchStatus(),
              const SizedBox(height: 16),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'O selecciona:',
                  style: TextStyle(fontSize: 16, color: Colors.white70),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: FocusTraversalOrder(
                  order: const NumericFocusOrder(4),
                  child: _buildObjectsList(),
                ),
              ),
            ],
          ),
          ),
        ),
      ),
    );
  }

  // Botón micrófono grande con indicador de "escuchando".
  Widget _buildMicButton() {
    return Center(
      child: Semantics(
        button: true,
        label: _isListening ? 'Escuchando' : 'Toca para hablar el nombre del objeto',
        // Ver comentario equivalente en home_screen.dart: sin onTap aquí,
        // TalkBack necesita varios dobles toques para activar el botón.
        onTap: _handleMicTap,
        child: GestureDetector(
        onTap: _handleMicTap,
        // Sin esto quedan DOS acciones de tap en el árbol de accesibilidad
        // (la del Semantics y la del propio GestureDetector) y el doble
        // toque de TalkBack dispara las dos: el micrófono arrancaba y se
        // cortaba solo en el mismo gesto.
        excludeFromSemantics: true,
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
        color: Colors.white,
        fontWeight:
            _currentTarget != null ? FontWeight.bold : FontWeight.normal,
      ),
    );
  }

  // Campo de texto (Tier 3): escribir el nombre a mano si la voz falla.
  Widget _buildTargetInput() {
    return TextField(
      controller: _targetController,
      focusNode: _targetFocus,
      textCapitalization: TextCapitalization.sentences,
      textInputAction: TextInputAction.done,
      style: const TextStyle(fontSize: 24, color: Colors.white),
      decoration: InputDecoration(
        hintText: 'O escribe el nombre',
        hintStyle: const TextStyle(color: Colors.white54),
        filled: true,
        fillColor: AuraColors.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      onSubmitted: _handleTargetTyped,
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
          disabledBackgroundColor: Colors.grey.shade800,
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
          style: TextStyle(color: Colors.white70, fontSize: 16),
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
          child: Semantics(
            button: true,
            label: obj.name,
            onTapHint: 'Buscar este objeto',
            onTap: () => _selectFromList(obj),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _selectFromList(obj),
              child: Container(
                constraints: const BoxConstraints(minHeight: kMinButtonHeight),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: AuraColors.surface,
                  border: Border.all(color: kAuraRed, width: 2.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        obj.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right, color: Colors.white54),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
