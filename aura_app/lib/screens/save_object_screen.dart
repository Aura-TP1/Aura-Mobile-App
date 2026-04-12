import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/saved_object.dart';
import '../services/embedding_service.dart';
import '../services/saved_objects_repository.dart';
import '../services/stt_service.dart';
import '../services/tts.dart';

/// Color rojo de marca AURA (mismo que usan search/home).
const Color _kAuraRed = Color(0xFFE53935);
const double _kMinButtonHeight = 64;

/// Pantalla para guardar un objeto personal.
///
/// En native: usa la cámara, captura una foto y extrae el embedding con
/// MobileNetV2 antes de persistir.
///
/// En Chrome (`kIsWeb == true`): no hay cámara ni TFLite disponibles en
/// nuestro target, así que se muestra un formulario simple (nombre +
/// dictado por voz) que guarda el objeto con embedding vacío. Sigue la
/// regla del spec: "if web, show 'Detección no disponible en este
/// dispositivo' and disable inference buttons, but keep all other screens
/// functional".
class SaveObjectScreen extends StatefulWidget {
  const SaveObjectScreen({super.key});

  @override
  State<SaveObjectScreen> createState() => _SaveObjectScreenState();
}

class _SaveObjectScreenState extends State<SaveObjectScreen> {
  final AudioFeedback _audio = AudioFeedback();
  final SavedObjectsRepository _repo = SavedObjectsRepository();
  final EmbeddingService _embeddings = EmbeddingService();
  final SttService _stt = SttService();

  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  // Cámara (solo native)
  CameraController? _camera;
  bool _cameraReady = false;
  String? _cameraError;

  // Estado
  bool _modelLoaded = false;
  bool _isSaving = false;
  bool _isListeningMic = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _audio.init();
    await _audio.speak(kIsWeb
        ? 'Guardar objeto. Escribe o dicta el nombre.'
        : 'Apunta la cámara al objeto y di o escribe el nombre.');
    if (!kIsWeb) {
      await _initCamera();
      await _embeddings.loadModel();
      if (mounted) setState(() => _modelLoaded = _embeddings.isLoaded);
    }
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _cameraError = 'No se encontró cámara.');
        return;
      }
      final controller = CameraController(
        cams.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraReady = true;
      });
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'Error de cámara: $e');
    }
  }

  @override
  void dispose() {
    _camera?.dispose();
    _embeddings.dispose();
    _audio.stop();
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  // ── Voz: dictar nombre ───────────────────────────────────────────────
  Future<void> _handleMicTap() async {
    if (_isListeningMic) {
      await _stt.stop();
      if (mounted) setState(() => _isListeningMic = false);
      return;
    }
    setState(() => _isListeningMic = true);
    await _audio.speak('Te escucho.');
    await _stt.startListening(onResult: (text) {
      if (!mounted) return;
      setState(() => _isListeningMic = false);
      if (text == null || text.isEmpty) {
        _audio.speak('No te escuché. Intenta de nuevo.');
        return;
      }
      // TODO: future voice trigger — "Guarda esto como <name>" from
      // search_screen should navigate here pre-filled (implement later).
      _nameController.text = text;
      _audio.speak('Nombre: $text. Presiona guardar.');
    });
  }

  // ── Guardar ──────────────────────────────────────────────────────────
  Future<void> _handleSaveTap() async {
    if (_isSaving) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      await _audio.speak('Escribe o dicta un nombre primero.');
      return;
    }

    setState(() => _isSaving = true);
    List<double> embedding = const [];

    try {
      if (!kIsWeb && _cameraReady && _modelLoaded) {
        final xfile = await _camera!.takePicture();
        final bytes = await xfile.readAsBytes();
        final decoded = img.decodeImage(bytes);
        if (decoded != null) {
          embedding = await _embeddings.extractEmbedding(decoded);
        }
      }
      await _repo.save(SavedObject(
        name: name,
        embedding: embedding,
        createdAt: DateTime.now(),
      ));
      await _audio.speak('Guardé $name.');
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      debugPrint('Error guardando: $e');
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al guardar: $e')),
        );
      }
    }
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
          'GUARDAR OBJETO',
          style: TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.bold,
            fontSize: 18,
          ),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildCameraArea(),
              const SizedBox(height: 16),
              _buildNameInput(),
              const SizedBox(height: 20),
              _buildSaveButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCameraArea() {
    if (kIsWeb) {
      return _buildWebNotice();
    }
    if (_cameraError != null) {
      return _buildCameraPlaceholder(_cameraError!);
    }
    if (!_cameraReady || _camera == null) {
      return _buildCameraPlaceholder('Iniciando cámara...');
    }
    return AspectRatio(
      aspectRatio: _camera!.value.aspectRatio,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: CameraPreview(_camera!),
      ),
    );
  }

  Widget _buildWebNotice() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFB74D), width: 1.5),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Color(0xFFEF6C00)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Detección no disponible en este dispositivo',
                  style: TextStyle(
                    color: Color(0xFFEF6C00),
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 8),
          Text(
            'Puedes guardar solo el nombre. La búsqueda visual estará '
            'disponible cuando abras AURA en tu celular.',
            style: TextStyle(color: Colors.black87, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPlaceholder(String message) {
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 14),
          ),
        ),
      ),
    );
  }

  Widget _buildNameInput() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: TextField(
            controller: _nameController,
            focusNode: _nameFocus,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 18),
            decoration: InputDecoration(
              hintText: 'Nombre del objeto',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 16,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        GestureDetector(
          onTap: _handleMicTap,
          child: Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _isListeningMic ? _kAuraRed : _kAuraRed.withOpacity(0.1),
              boxShadow: _isListeningMic
                  ? [
                      BoxShadow(
                        color: _kAuraRed.withOpacity(0.35),
                        blurRadius: 18,
                        spreadRadius: 3,
                      ),
                    ]
                  : [],
            ),
            child: Icon(
              _isListeningMic ? Icons.mic : Icons.mic_none,
              color: _isListeningMic ? Colors.white : _kAuraRed,
              size: 28,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveButton() {
    final String label;
    if (_isSaving) {
      label = 'GUARDANDO...';
    } else if (kIsWeb) {
      label = 'GUARDAR NOMBRE';
    } else {
      label = 'CAPTURAR Y GUARDAR';
    }
    return SizedBox(
      height: _kMinButtonHeight,
      child: ElevatedButton(
        onPressed: _isSaving ? null : _handleSaveTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _kAuraRed,
          disabledBackgroundColor: Colors.grey.shade300,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          elevation: 0,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}
