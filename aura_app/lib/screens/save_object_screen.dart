import 'dart:async';
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
import '../theme/aura_colors.dart';

const Color _kAuraRed = AuraColors.red;
const double _kMinButtonHeight = kAuraMinButtonHeight;

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
    // Antes esto esperaba (await) a que el mensaje de voz terminara de
    // hablar ANTES de siquiera empezar a inicializar la cámara — con el
    // TTS tardando unos segundos en pronunciar la frase, la cámara ni
    // arrancaba a cargar hasta que se cortaba de hablar, y encima cámara
    // y modelo se cargaban uno después del otro (no en paralelo). El
    // usuario veía la cámara en gris mucho más tiempo del necesario.
    // Fire-and-forget: el aviso se sigue escuchando, pero ya no bloquea
    // nada.
    unawaited(_audio.speak(kIsWeb
        ? 'Guardar objeto. Escribe o dicta el nombre.'
        : 'Apunta la cámara al objeto y di o escribe el nombre.'));
    if (!kIsWeb) {
      await Future.wait([
        _initCamera(),
        _embeddings.loadModel(),
        _detector.loadModel(),
      ]);
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
    if (!mounted) return;

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

     // Antes esto se saltaba en silencio si la cámara o el modelo no
     // estaban listos, y el objeto se guardaba igual con 0 embeddings —
     // quedaba imposible de encontrar después en una búsqueda, sin que el
     // usuario supiera por qué. Avisamos y no guardamos en ese caso.
     if (!kIsWeb && (!_cameraReady || !_modelLoaded)) {
       final reason =
           !_cameraReady ? 'la cámara no está lista' : 'el modelo de reconocimiento no cargó';
       await _audio.speak('No puedo guardar todavía: $reason. Intenta de nuevo en un momento.');
       if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text('No se pudo guardar: $reason.')),
         );
       }
       return;
     }

     setState(() => _isSaving = true);

     try {
       List<ObjectEmbedding> embeddings = [];

       if (!kIsWeb) {
         // Una sola foto en vez del flujo multi-ángulo: menos pasos para
         // el usuario. _captureEmbedding ya devuelve varios ObjectEmbedding
         // (original + rotaciones + espejo) generados de esa única foto.
         embeddings = await _captureEmbedding();
         if (embeddings.isEmpty) {
           await _audio.speak('No pude capturar la foto. Intenta de nuevo.');
           if (mounted) {
             setState(() => _isSaving = false);
             ScaffoldMessenger.of(context).showSnackBar(
               const SnackBar(content: Text('No se pudo capturar la foto. Intenta de nuevo.')),
             );
           }
           return;
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
     } finally {
       if (mounted) setState(() => _isSaving = false);
     }
   }

  /// Captura una sola foto y extrae VARIOS embeddings de ella (original +
  /// rotaciones 90/180/270 + espejo horizontal), en vez de pedirle al
  /// usuario más fotos desde distintos ángulos.
  ///
  /// MobileNetV2 no es invariante a rotación: un objeto guardado de frente
  /// y buscado girado 90° puede dar una similitud coseno muy por debajo
  /// del umbral de match (0.75) aunque sea el mismo objeto — confirmado en
  /// campo con una pastilla que no se reconocía tras girarla. La búsqueda
  /// (`embedding_service_common.dart` → `findBestMatch`, y también
  /// `real_search_screen.dart`) ya compara contra TODOS los embeddings de
  /// un objeto y toma el máximo, así que agregar estas variantes sintéticas
  /// aquí no requiere ningún cambio del lado de la búsqueda.
  Future<List<ObjectEmbedding>> _captureEmbedding() async {
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
      String? cropFallbackReason;
      double? discardedBoxWidth;
      double? discardedBoxHeight;
      if (_detector.isLoaded) {
        final detections =
            await _detector.detect(decoded, confThreshold: kCropConfThreshold);
        final best = bestCropCandidate(detections);
        if (best != null) {
          toEmbed = cropToDetection(decoded, best);
          cropMethod = 'yolo_detection';
          cropClassId = cocoLabels.indexOf(best.label);
          cropLabel = best.label;
          cropConfidence = best.confidence;
        } else {
          toEmbed = centerCrop(decoded);
          cropMethod = 'center_crop_fallback';
          if (detections.isEmpty) {
            cropFallbackReason = 'no_detection';
          } else {
            cropFallbackReason = 'box_too_small';
            final discarded = highestConfidence(detections);
            discardedBoxWidth = discarded?.rect.width;
            discardedBoxHeight = discarded?.rect.height;
          }
          debugPrint('[save_object] Sin detección ≥$kCropConfThreshold; usando center-crop como fallback ($cropFallbackReason).');
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
        cropFallbackReason: cropFallbackReason,
        discardedBoxWidth: discardedBoxWidth,
        discardedBoxHeight: discardedBoxHeight,
      );

      // Variantes sintéticas de la MISMA foto ya recortada — sin tomar
      // fotos nuevas ni pedirle nada más al usuario.
      final variants = <String, img.Image>{
        'original': toEmbed,
        'rot90': img.copyRotate(toEmbed, angle: 90),
        'rot180': img.copyRotate(toEmbed, angle: 180),
        'rot270': img.copyRotate(toEmbed, angle: 270),
        'flip': img.flipHorizontal(toEmbed),
      };

      final results = <ObjectEmbedding>[];
      for (final entry in variants.entries) {
        final emb = await _embeddings.extractEmbedding(entry.value);
        if (emb.isNotEmpty) {
          results.add(ObjectEmbedding.create(embedding: emb, angleDescription: entry.key));
        }
      }
      return results;
    } catch (e) {
      debugPrint('Error capturando foto: $e');
      return const [];
    }
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
          'GUARDAR OBJETO',
          style: TextStyle(
            color: Colors.white,
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
        color: AuraColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFB74D), width: 1.5),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, color: Color(0xFFFFB74D)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Detección no disponible en este dispositivo',
                  style: TextStyle(
                    color: Color(0xFFFFB74D),
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
            style: TextStyle(color: Colors.white70, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildCameraPlaceholder(String message) {
    return Container(
      height: 220,
      decoration: BoxDecoration(
        color: AuraColors.surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 14),
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
            style: const TextStyle(fontSize: 24, color: Colors.white),
            decoration: InputDecoration(
              hintText: 'Nombre del objeto',
              hintStyle: const TextStyle(color: Colors.white54),
              filled: true,
              fillColor: AuraColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
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
          onTap: _handleMicTap,
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
     // Antes el botón se podía tocar apenas se abría la pantalla, aunque la
     // cámara/el modelo todavía estuvieran cargando (siempre tardan un
     // poco) — eso disparaba el aviso de "no está lista todavía" apenas el
     // usuario tocaba, que se sentía como que la app fallaba. Ahora el
     // botón queda deshabilitado (con su propio label) hasta que de verdad
     // esté listo, en vez de dejar tocar y recién ahí avisar.
     final notReady = !kIsWeb && (!_cameraReady || !_modelLoaded);
     final String label;
     if (_isSaving) {
       label = 'GUARDANDO...';
     } else if (notReady) {
       label = 'PREPARANDO CÁMARA...';
     } else if (kIsWeb) {
       label = 'GUARDAR NOMBRE';
     } else {
       label = 'TOMAR FOTO';
     }
     return SizedBox(
       height: _kMinButtonHeight,
       child: ElevatedButton(
         onPressed: (_isSaving || notReady) ? null : _handleSaveTap,
         style: ElevatedButton.styleFrom(
           backgroundColor: _kAuraRed,
           disabledBackgroundColor: Colors.grey.shade800,
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
