import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/saved_object.dart';
import '../services/app_settings.dart';
import '../services/backend_service.dart';
import '../services/detection_crop.dart';
import '../services/embedding_service.dart';
import '../services/google_auth_service.dart';
import '../services/metrics_logger.dart';
import '../services/object_detector.dart';
import '../services/saved_objects_repository.dart';
import '../services/voice_input_service.dart';
import '../services/tts.dart';
import 'multi_angle_capture_screen.dart' show MultiAngleCaptureScreen, CaptureAngle;

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
  final EmbeddingService _embeddings =
      EmbeddingService(useInt8: AppSettings.instance.useEmbeddingInt8);
  final ObjectDetector _detector =
      ObjectDetector(useInt8: AppSettings.instance.useYoloInt8);
  late final VoiceInputService _voice = VoiceInputService(_audio);
  final GoogleAuthService _auth = GoogleAuthService();
  final BackendService _backend = BackendService();

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
  bool _handledArgs = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Prefill por comando de voz "Aura guarda esto como X".
    if (_handledArgs) return;
    _handledArgs = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is String && args.trim().isNotEmpty) {
      _nameController.text = args.trim();
    }
  }

  Future<void> _init() async {
    await _audio.init();
    await _audio.speak(kIsWeb
        ? 'Guardar objeto. Escribe o dicta el nombre.'
        : 'Apunta la cámara al objeto y di o escribe el nombre.');
    if (!kIsWeb) {
      await _initCamera();
      await _embeddings.loadModel();
      await _detector.loadModel();
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
    _voice.stop();
    _camera?.dispose();
    _embeddings.dispose();
    _detector.dispose();
    _audio.stop();
    _audio.dispose();
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  // ── Voz: dictar nombre (fallback de 3 niveles: Google → Vosk → texto) ──
  Future<void> _handleMicTap() async {
    if (_isListeningMic) {
      await _voice.stop();
      if (mounted) setState(() => _isListeningMic = false);
      return;
    }
    setState(() => _isListeningMic = true);
    await _audio.speak('Te escucho.');
    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) { setState(() => _isListeningMic = false); return; }

    final text = await _voice.listen();
    if (!mounted) return;
    setState(() => _isListeningMic = false);

    if (text != null) {
      // TODO: future voice trigger — "Guarda esto como <name>" from
      // search_screen should navigate here pre-filled (implement later).
      _nameController.text = text;
      await _audio.speak('Nombre: $text. Presiona guardar.');
      return;
    }
    if (_voice.permanentlyDenied) {
      await _audio.speak('Necesito permiso del micrófono. Te llevo a ajustes.');
      await _voice.openSettings();
      return;
    }
    // Tier 3: ambos niveles de voz fallaron, dicta por teclado.
    await _audio.speak('Escribe el nombre del objeto.');
    if (mounted) FocusScope.of(context).requestFocus(_nameFocus);
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

     try {
       List<ObjectEmbedding> embeddings = [];

       if (!kIsWeb && _cameraReady && _modelLoaded) {
         // Ir a la pantalla de captura multi-ángulo
         await _audio.speak('Capturaremos el objeto desde diferentes ángulos para mejor reconocimiento.');
         await Future.delayed(const Duration(seconds: 1));

         if (!mounted) return;
         final capturedAngles = await Navigator.push<Map<CaptureAngle, List<double>>>(
           context,
           MaterialPageRoute(
             builder: (_) => MultiAngleCaptureScreen(objectName: name),
           ),
         );

         if (capturedAngles != null && capturedAngles.isNotEmpty) {
           // Convertir los ángulos capturados a ObjectEmbedding
           embeddings = capturedAngles.entries
               .map((entry) => ObjectEmbedding.create(
                     embedding: entry.value,
                     angleDescription: entry.key.label,
                   ))
               .toList();
         }
       }

       final obj = SavedObject(
         name: name,
         embeddings: embeddings,
         createdAt: DateTime.now(),
       );

       // Guardar localmente siempre
       await _repo.save(obj);

       // Subir al backend si la sync está habilitada y hay sesión activa
       if (AppSettings.instance.syncEnabled && _auth.isAuthenticated) {
         try {
           final embeddingBase64 = base64Encode(
             utf8.encode(jsonEncode(embeddings.map((e) => e.toJson()).toList())),
           );
           await _backend.syncObjectsUpload([
             {
               'id': obj.id,
               'name': obj.name,
               'embedding': embeddingBase64,
               'thumbnail': null,
               'created_at': obj.createdAt.toIso8601String(),
             }
           ]);
         } catch (e) {
           // Fallo silencioso: el objeto ya está guardado localmente
           debugPrint('Advertencia: no se pudo sincronizar con el backend: $e');
         }
       }

       await _audio.haptic(200); // confirmación háptica
       await _audio.speak('Guardé $name con ${embeddings.length} ángulos capturados.');
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
     } finally {
       if (mounted) setState(() => _isSaving = false);
     }
   }

  /// Captura una sola foto y extrae su embedding. Sin pedir reposicionar la
  /// cámara: más simple y digno para un usuario con baja visión.
  Future<List<double>> _captureEmbedding() async {
    await _audio.speak('Mantén firme. Capturando.');
    await Future.delayed(const Duration(milliseconds: 400));
    if (!_cameraReady || _camera == null) return const [];
    try {
      final xfile = await _camera!.takePicture();
      final bytes = await xfile.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return const [];

      // Recortar antes de extraer el embedding, en vez de pasar el frame
      // completo: el embedding debe representar el objeto, no la escena que
      // lo rodea. Usa kCropConfThreshold (bajo, solo localización) — varios
      // objetos de prueba (llaves, pastillas, lentes) no son clases COCO y
      // casi nunca cruzan el umbral de detección en vivo (0.4). Si ni con
      // el umbral bajo hay nada, recorte central en vez de imagen entera.
      var toEmbed = decoded;
      String cropMethod;
      int? cropClassId;
      String? cropLabel;
      double? cropConfidence;
      if (_detector.isLoaded) {
        final detections =
            await _detector.detect(decoded, confThreshold: kCropConfThreshold);
        final best = highestConfidence(detections);
        if (best != null) {
          toEmbed = cropToDetection(decoded, best);
          cropMethod = 'yolo_detection';
          cropClassId = cocoLabels.indexOf(best.label);
          cropLabel = best.label;
          cropConfidence = best.confidence;
        } else {
          toEmbed = centerCrop(decoded);
          cropMethod = 'center_crop_fallback';
          debugPrint('[save_object] Sin detección ≥$kCropConfThreshold; usando center-crop como fallback.');
        }
      } else {
        cropMethod = 'full_frame_no_model';
        debugPrint('[save_object] Detector YOLO no cargado; usando imagen completa como fallback.');
      }

      // ignore: discarded_futures
      MetricsLogger.instance.logCropSelection(
        screen: 'save_object',
        objectLabel: _nameController.text.trim(),
        cropMethod: cropMethod,
        detectionClassId: cropClassId,
        detectionLabel: cropLabel,
        detectionConfidence: cropConfidence,
      );

      return await _embeddings.extractEmbedding(toEmbed);
    } catch (e) {
      debugPrint('Error capturando foto: $e');
      return const [];
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
          tooltip: 'Volver',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
        child: SingleChildScrollView(
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
            style: const TextStyle(fontSize: 24),
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
        Semantics(
          button: true,
          label: _isListeningMic ? 'Escuchando' : 'Dictar nombre por voz',
          child: GestureDetector(
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
       label = 'CAPTURAR DESDE ÁNGULOS';
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
