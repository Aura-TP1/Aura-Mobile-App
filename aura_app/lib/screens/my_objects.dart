import 'package:flutter/material.dart';

import '../models/saved_object.dart';
import '../services/saved_objects_repository.dart';
import '../theme/aura_colors.dart';

/// Pantalla "MIS OBJETOS": lista los objetos personales del usuario
/// directamente desde [SavedObjectsRepository]. Permite navegar a
/// `/save-object` para añadir uno nuevo y eliminar los existentes.
///
/// Siempre lee de almacenamiento local (SharedPreferences) — no depende de
/// internet ni del backend. La sincronización con la nube es un flujo
/// aparte, explícito, desde "Sincronizar ahora" en Ajustes.
class MyObjectsScreen extends StatefulWidget {
  const MyObjectsScreen({super.key});

  @override
  State<MyObjectsScreen> createState() => _MyObjectsScreenState();
}

class _MyObjectsScreenState extends State<MyObjectsScreen> {
  final SavedObjectsRepository _repo = SavedObjectsRepository();

  List<SavedObject> _objects = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _repo.getAll();
    if (!mounted) return;
    setState(() {
      _objects = items;
      _loading = false;
    });
  }

  Future<void> _openSaveObject() async {
    await Navigator.pushNamed(context, '/save-object');
    if (!mounted) return;
    await _load();
  }

  Future<void> _deleteObject(SavedObject obj) async {
    await _repo.delete(obj.name);
    if (!mounted) return;
    setState(() => _objects.removeWhere((o) => o.name == obj.name));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Eliminado: ${obj.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    // FocusTraversalGroup + orden explícito en "volver" y "+": sin esto,
    // TalkBack no tiene garantizado que el botón "volver" sea lo primero
    // que enfoca al explorar la pantalla (a diferencia de home_screen.dart,
    // que sí ordena sus botones así) — para evitar que alguien active por
    // error "Guardar nuevo objeto" pensando que estaba tocando "volver".
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Scaffold(
      backgroundColor: AuraColors.background,
      appBar: AppBar(
        backgroundColor: AuraColors.surface,
        elevation: 0,
        leading: FocusTraversalOrder(
          order: const NumericFocusOrder(1),
          child: IconButton(
            tooltip: 'Volver',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            icon: const Icon(Icons.arrow_back, color: Colors.white, size: 32),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        title: const Text(
          'MIS OBJETOS',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
        actions: [
          FocusTraversalOrder(
            order: const NumericFocusOrder(2),
            child: Container(
              margin: const EdgeInsets.only(right: 16),
              decoration: BoxDecoration(
                color: AuraColors.green,
                borderRadius: BorderRadius.circular(12),
              ),
              child: IconButton(
                icon: const Icon(Icons.add, color: Colors.white, size: 28),
                tooltip: 'Guardar nuevo objeto',
                onPressed: _openSaveObject,
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : _buildList(),
      ),
    );
  }

  Widget _buildList() {
    if (_objects.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined,
                  color: Colors.white70, size: 64),
              const SizedBox(height: 16),
              const Text(
                'Aún no tienes objetos guardados.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 8),
              const Text(
                'Presiona + para guardar tu primero.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _openSaveObject,
                icon: const Icon(Icons.add),
                label: const Text('GUARDAR OBJETO'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AuraColors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 14,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _objects.length,
      itemBuilder: (context, index) {
        final obj = _objects[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AuraColors.surface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  obj.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_outline,
                  color: AuraColors.red,
                  size: 26,
                ),
                tooltip: 'Eliminar',
                onPressed: () => _deleteObject(obj),
              ),
            ],
          ),
        );
      },
    );
  }
}
