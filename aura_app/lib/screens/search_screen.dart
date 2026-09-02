import 'package:flutter/material.dart';

import '../models/saved_object.dart';
import '../services/saved_objects_repository.dart';
import '../services/tts.dart';
import '../theme/aura_colors.dart';
import 'real_search_screen.dart';

const Color kAuraRed = AuraColors.red;

/// Altura mínima de botones para accesibilidad (adultos mayores).
const double kMinButtonHeight = kAuraMinButtonHeight;

/// Pantalla "BUSCAR MI OBJETO": SOLO la lista de objetos guardados.
///
/// Antes tenía además un botón de micrófono, un campo de texto y un botón
/// ACTIVAR, y había que elegir el objeto y después pulsar ACTIVAR. En prueba
/// con adultos mayores eso resultó confuso: demasiados elementos en pantalla,
/// y con TalkBack cada movimiento de la mano cambiaba el foco y cortaba lo
/// que se estaba leyendo.
///
/// Ahora hay un solo tipo de elemento —una tarjeta por objeto— y tocarla
/// abre la búsqueda directamente. Menos elementos significa menos saltos de
/// foco accidentales, y las etiquetas son cortas para que, si TalkBack enfoca
/// el elemento equivocado, no se ponga a leer un texto largo.
///
/// Borrar objetos NO está acá a propósito: el gesto de deslizar para eliminar
/// es peligroso para este público y ya existe en "Mis objetos".
class SearchObjectScreen extends StatefulWidget {
  const SearchObjectScreen({super.key});

  @override
  State<SearchObjectScreen> createState() => _SearchObjectScreenState();
}

class _SearchObjectScreenState extends State<SearchObjectScreen> {
  static const List<String> _defaultObjects = [
    'Mi tomatodo',
    'Mis llaves',
    'Medicinas',
  ];

  final AudioFeedback _audio = AudioFeedback();
  final SavedObjectsRepository _repo = SavedObjectsRepository();

  List<SavedObject> _savedObjects = const [];
  bool _handledArgs = false;

  @override
  void initState() {
    super.initState();
    _audio.init();
    _loadSavedObjects();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_handledArgs) return;
    _handledArgs = true;
    // Comando de voz "Aura busca X": antes esto solo pre-seleccionaba el
    // objeto y decía "presiona activar para buscar". Como ya no hay botón
    // ACTIVAR, ahora abre la búsqueda directamente.
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is String && args.trim().isNotEmpty) {
      final target = _stripPossessive(args);
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        // Esperar a que la lista esté cargada para poder emparejar el nombre.
        if (_savedObjects.isEmpty) await _loadSavedObjects();
        if (!mounted) return;
        _openSearch(_matchObject(target), target);
      });
    }
  }

  @override
  void dispose() {
    _audio.stop();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _loadSavedObjects() async {
    var stored = await _repo.getAll();
    // Si no hay nada guardado, siembra los defaults una sola vez para no
    // romper la UX que ya tenía la app antes del repo.
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
    if (mounted) setState(() => _savedObjects = stored);
  }

  /// Empareja el texto dictado con un objeto guardado: primero exacto (sin
  /// artículos), después por substring, así "llaves" encuentra "Mis llaves".
  SavedObject _matchObject(String target) {
    int idx = _savedObjects.indexWhere((o) => _stripPossessive(o.name) == target);
    if (idx < 0) {
      idx = _savedObjects.indexWhere(
        (o) =>
            _stripPossessive(o.name).contains(target) ||
            target.contains(_stripPossessive(o.name)),
      );
    }
    return idx >= 0
        ? _savedObjects[idx]
        : SavedObject(name: target, embedding: const [], createdAt: DateTime.now());
  }

  /// Abre la búsqueda. NO habla acá: `RealSearchScreen` ya anuncia "Buscando
  /// X" al iniciarse, y decirlo en los dos lados hacía que la frase se
  /// escuchara dos veces. Tampoco se espera al TTS antes de navegar: con
  /// `awaitSpeakCompletion(true)`, esperar dejaba la pantalla trabada varios
  /// segundos después del toque.
  void _openSearch(SavedObject obj, String target) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => RealSearchScreen(target: target, savedObject: obj),
      ),
    );
  }

  String _stripPossessive(String label) {
    final lower = label.toLowerCase().trim();
    const prefixes = ['mi ', 'mis ', 'el ', 'la ', 'los ', 'las '];
    for (final p in prefixes) {
      if (lower.startsWith(p)) return lower.substring(p.length);
    }
    return lower;
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Toca el objeto que quieres encontrar',
                style: TextStyle(fontSize: 18, color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Expanded(child: _buildObjectsList()),
              const SizedBox(height: 12),
              _buildBackButton(),
            ],
          ),
        ),
      ),
    );
  }

  /// Botón VOLVER grande abajo, además de la flecha del AppBar.
  ///
  /// La flecha de arriba es chica y queda lejos del pulgar; en prueba con
  /// adultos mayores directamente no la veían. Abajo es donde llega la mano y
  /// donde se mira. La flecha del AppBar se mantiene porque es lo que TalkBack
  /// y el gesto de "atrás" del sistema esperan encontrar.
  Widget _buildBackButton() {
    return SizedBox(
      height: 64,
      child: OutlinedButton.icon(
        onPressed: () => Navigator.maybePop(context),
        icon: const Icon(Icons.arrow_back, size: 28, color: Colors.white),
        label: const Text(
          'VOLVER',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1,
          ),
        ),
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Colors.white54, width: 2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
          style: TextStyle(color: Colors.white70, fontSize: 18),
        ),
      );
    }
    return ListView.separated(
      itemCount: _savedObjects.length,
      separatorBuilder: (_, __) => const SizedBox(height: 14),
      itemBuilder: (context, index) {
        final obj = _savedObjects[index];
        return Semantics(
          button: true,
          // Etiqueta corta a propósito: si TalkBack enfoca el elemento
          // equivocado porque se movió la mano, termina de leerlo enseguida.
          label: obj.name,
          onTap: () => _openSearch(obj, _stripPossessive(obj.name)),
          excludeSemantics: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openSearch(obj, _stripPossessive(obj.name)),
              child: Container(
                constraints: const BoxConstraints(minHeight: 88),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: AuraColors.surface,
                  border: Border.all(color: kAuraRed, width: 3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.search, color: kAuraRed, size: 32),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        obj.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ),
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
