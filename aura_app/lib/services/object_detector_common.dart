import 'dart:ui' show Rect;

/// Una deteccion de YOLOv8 con caja en coordenadas normalizadas [0..1].
class Detection {
  final String label;
  final double confidence;
  final Rect rect;

  Detection({
    required this.label,
    required this.confidence,
    required this.rect,
  });
}

/// Etiquetas COCO en espanol (80 clases, en el orden oficial de YOLOv8).
const List<String> cocoLabels = [
  'persona', 'bicicleta', 'auto', 'moto', 'avion',
  'bus', 'tren', 'camion', 'bote', 'semaforo',
  'hidrante', 'senal de alto', 'parquimetro', 'banca', 'ave',
  'gato', 'perro', 'caballo', 'oveja', 'vaca',
  'elefante', 'oso', 'cebra', 'jirafa', 'mochila',
  'paraguas', 'bolso', 'corbata', 'maleta', 'frisbee',
  'esquis', 'snowboard', 'pelota', 'cometa', 'bate',
  'guante', 'patineta', 'tabla de surf', 'raqueta', 'botella',
  'copa', 'taza', 'tenedor', 'cuchillo', 'cuchara',
  'tazon', 'platano', 'manzana', 'sandwich', 'naranja',
  'brocoli', 'zanahoria', 'hot dog', 'pizza', 'donut',
  'pastel', 'silla', 'sofa', 'planta', 'cama',
  'mesa', 'inodoro', 'televisor', 'laptop', 'mouse',
  'control remoto', 'teclado', 'celular', 'microondas', 'horno',
  'tostadora', 'lavabo', 'refrigerador', 'libro', 'reloj',
  'jarron', 'tijeras', 'oso de peluche', 'secador', 'cepillo de dientes',
];
