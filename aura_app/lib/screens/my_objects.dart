import 'package:flutter/material.dart';

import '../models/saved_object.dart';
import '../services/saved_objects_repository.dart';

/// Pantalla "MIS OBJETOS": lista los objetos personales del usuario
/// directamente desde [SavedObjectsRepository]. Permite navegar a
/// `/save-object` para añadir uno nuevo y eliminar los existentes.
///
/// Reemplaza el mock con emojis hardcodeado anterior — ahora es la
/// vista oficial de los datos persistidos compartidos con search_screen.
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

  String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A3A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F2922),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
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
          Container(
            margin: const EdgeInsets.only(right: 16),
            decoration: BoxDecoration(
              color: Colors.green,
              borderRadius: BorderRadius.circular(12),
            ),
            child: IconButton(
              icon: const Icon(Icons.add, color: Colors.white, size: 28),
              tooltip: 'Guardar nuevo objeto',
              onPressed: _openSaveObject,
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white),
            )
          : Column(
              children: [
                _buildCounter(),
                Expanded(child: _buildList()),
              ],
            ),
    );
  }

  Widget _buildCounter() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: const Color(0xFF2E5F4F),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Text(
            '${_objects.length} objetos guardados',
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
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
                  color: Color(0xFF9FC5B8), size: 64),
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
                style: TextStyle(color: Color(0xFF9FC5B8), fontSize: 14),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _openSaveObject,
                icon: const Icon(Icons.add),
                label: const Text('GUARDAR OBJETO'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
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
            color: const Color(0xFF2A4A3D),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              Container(
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A3A2E),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  obj.hasEmbedding
                      ? Icons.image_search
                      : Icons.label_outline,
                  color: const Color(0xFF9FC5B8),
                  size: 28,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      obj.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Guardado el ${_formatDate(obj.createdAt)}',
                      style: const TextStyle(
                        color: Color(0xFF9FC5B8),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_outline,
                  color: Colors.red,
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
