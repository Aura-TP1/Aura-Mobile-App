import 'package:flutter/material.dart';

class MyObjectsScreen extends StatelessWidget {
  const MyObjectsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final objects = [
      {
        'icon': '🥤',
        'name': 'Mi tomatodo',
        'description': 'Botella roja en la mesa',
      },
      {
        'icon': '🔑',
        'name': 'Mis llaves',
        'description': 'Llavero de cuero negro',
      },
      {
        'icon': '💊',
        'name': 'Medicinas',
        'description': 'Pastillero diario AM/PM',
      },
    ];

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
              onPressed: () {
                // TODO: Agregar objeto
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Contador
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            color: const Color(0xFF2E5F4F),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  color: Colors.white,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '${objects.length} objetos guardados',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),

          // Lista
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: objects.length,
              itemBuilder: (context, index) {
                final obj = objects[index];
                return Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A4A3D),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      // Icono
                      Container(
                        width: 60,
                        height: 60,
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A3A2E),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Center(
                          child: Text(
                            obj['icon']!,
                            style: const TextStyle(fontSize: 32),
                          ),
                        ),
                      ),

                      const SizedBox(width: 16),

                      // Texto
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              obj['name']!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              obj['description']!,
                              style: const TextStyle(
                                color: Color(0xFF9FC5B8),
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 12),

                      // Botones
                      Column(
                        children: [
                          Row(
                            children: [
                              // Eliminar
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: Colors.red,
                                  size: 22,
                                ),
                                onPressed: () {
                                  // TODO: Eliminar
                                },
                              ),
                              
                              // Editar
                              IconButton(
                                icon: const Icon(
                                  Icons.edit_outlined,
                                  color: Colors.yellow,
                                  size: 22,
                                ),
                                onPressed: () {
                                  // TODO: Editar
                                },
                              ),
                            ],
                          ),
                          
                          // Ver/Buscar
                          ElevatedButton(
                            onPressed: () {
                              // TODO: Buscar objeto
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 8,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.visibility, size: 18),
                                SizedBox(width: 4),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}