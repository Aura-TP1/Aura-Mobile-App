import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../models/saved_object.dart';
import '../services/app_settings.dart';
import '../services/backend_service.dart';
import '../services/camera_frame_converter.dart';
import '../services/detection_crop.dart';
import '../services/embedding_service.dart';
import '../services/google_auth_service.dart';
import '../services/metrics_logger.dart';
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
  late final VoiceInputService _voice = VoiceInputService(_audio);
  final GoogleAuthService _auth = GoogleAuthService();
  final BackendService _backend = BackendService();

  final TextEditingController _nameController = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  // Cámara (solo native)
  CameraController? _camera;
  bool _cameraReady = false;
  String? _cameraError;

  /// Último frame recibido del stream del preview. Es exactamente lo que el
  /// usuario está viendo en pantalla, así que recortarlo con el marco guía
  /// sí corresponde a lo que encuadró (ver _initCamera).
  CameraImage? _lastFrame;
  bool _streamActive = false;

  // Estado
  bool _modelLoaded = false;
  bool _isSaving = false;
  /// `true` desde que dispara el obturador hasta que terminan de extraerse
  /// los embeddings — sirve para que el botón diga "PROCESANDO..." en vez de
  /// quedarse en "GUARDANDO..." sin distinguir las dos fases.
  bool _isProcessing = false;
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
        : 'Apunta la cámara al objeto, colócalo dentro del marco, y di o escribe el nombre.'));
    if (!kIsWeb) {
      await Future.wait([
        _initCamera(),
        _embeddings.loadModel(),
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
      // Sin esto, algunos Android disparan el flash automático en poca luz al
      // llamar takePicture() — el plugin no fija FlashMode por defecto. Al
      // usuario le aparecía el flash de la nada al guardar un objeto. Mismo
      // bloque que ya estaba en camera_detection_view.dart.
      try {
        await controller.setFlashMode(FlashMode.off);
      } catch (e) {
        debugPrint('No se pudo forzar flash apagado: $e');
      }
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _cameraReady = true;
      });

      // Se abre el stream del preview y se guarda SOLO la referencia al
      // último frame (no se procesa nada acá: es barato). Ese frame es el
      // que se usa al capturar, en vez de takePicture().
      //
      // Motivo: en Android el preview y takePicture() son dos streams
      // distintos del sensor, y la foto suele tener un campo de visión más
      // ancho que el preview. Con el blister entero dentro del marco en
      // pantalla, en la foto ocupaba ~57% del ancho mientras el recorte
      // cubría ~43%, y se cortaba por los dos lados. Tomando el frame del
      // mismo stream que alimenta el preview, el marco guía deja de ser una
      // estimación sobre dos geometrías distintas.
      try {
        await controller.startImageStream((frame) => _lastFrame = frame);
        _streamActive = true;
      } catch (e) {
        // startImageStream no está soportado en web/desktop — ahí se sigue
        // usando takePicture() como fallback (ver _captureEmbedding).
        debugPrint('startImageStream no disponible, se usará takePicture: $e');
      }
    } catch (e) {
      if (mounted) setState(() => _cameraError = 'Error de cámara: $e');
    }
  }

  @override
  void dispose() {
    _voice.stop();
    if (_streamActive) {
      try { _camera?.stopImageStream(); } catch (_) {}
      _streamActive = false;
    }
    _camera?.dispose();
    _embeddings.dispose();
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
       if (mounted) {
         setState(() {
           _isSaving = false;
           _isProcessing = false;
         });
       }
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
    // Sin await: `speak` no retorna hasta que el TTS TERMINA de pronunciar
    // la frase (awaitSpeakCompletion(true) en tts.dart), así que esperarla
    // metía ~2 segundos muertos entre que el usuario tocaba el botón y el
    // obturador — sin ninguna señal de que algo estuviera pasando.
    unawaited(_audio.speak('Mantén firme.'));
    await Future.delayed(const Duration(milliseconds: 600));
    if (!_cameraReady || _camera == null) return const [];
    try {
      // Feedback en el INSTANTE de la captura. Antes el único háptico estaba
      // al final de todo el guardado, así que un usuario que no ve la
      // pantalla no tenía forma de saber cuándo se tomó la foto (ni si ya se
      // había tomado): movía el objeto creyendo que todavía no había
      // disparado. El háptico marca la captura y la voz avisa que ahora sí
      // puede bajar la mano mientras se procesa.
      unawaited(_audio.haptic(120));
      unawaited(_audio.speak('Listo. Procesando.'));
      if (mounted) setState(() => _isProcessing = true);

      // El frame del stream del preview es lo que el usuario tiene delante:
      // mismo campo de visión, misma escala. takePicture() queda solo como
      // fallback donde el stream no está soportado (web/desktop).
      img.Image? decoded;
      final frame = _lastFrame;
      if (_streamActive && frame != null) {
        decoded = await CameraFrameConverter.toDisplayImage(frame, _camera!);
      }
      if (decoded == null) {
        final xfile = await _camera!.takePicture();
        final bytes = await xfile.readAsBytes();
        decoded = img.decodeImage(bytes);
      }
      if (decoded == null) return const [];

      // Recorte determinístico al marco guía CUADRADO que se le mostró al
      // usuario (ver _buildCameraArea) — no depende de que YOLO reconozca
      // el objeto para elegir la región. Antes se usaba la detección de
      // YOLO de mayor puntaje, y falló dos veces con datos reales: al
      // guardar una pastilla (sin clase COCO, confianza siempre baja), YOLO
      // se quedaba con un objeto de fondo que SÍ tiene clase COCO (primero
      // "teclado", después "laptop"). No es un problema de calibrar el
      // puntaje: YOLO es un clasificador de 80 categorías fijas, no un
      // detector de objetos genéricos.
      //
      // El marco guía por sí solo tampoco alcanzaba, porque el recorte era
      // `centerCrop(decoded, fraction: 0.6)` — el 60% del ancho y el 60%
      // del alto de la foto CRUDA — que no es la región que el usuario
      // tenía dentro del marco: `img.decodeImage` no aplica la rotación
      // EXIF, así que la foto se procesaba apaisada mientras el preview se
      // veía vertical, y el recorte salía ancho y con medio teclado adentro
      // aunque la pastilla estuviera centrada en el marco.
      // `cropToGuideSquare` aplica la orientación y recorta un cuadrado
      // centrado, que es invariante a ese desfase (ver detection_crop.dart).
      final oriented = bakePhotoOrientation(decoded);
      var toEmbed = cropToGuideSquare(oriented);
      var cropMethod = 'guide_frame';

      // Sobre el recorte del marco guía, intentar ceñir aún más al objeto
      // con segmentación de primer plano sin clases (watershed): el marco
      // guía ya excluye el fondo lejano, pero dentro del cuadrado todavía
      // puede haber fondo (teclado, mesa) alrededor del objeto real. El
      // watershed no reconoce clases — solo separa por bordes/contraste —
      // así que no puede "confundir" el objeto con mobiliario cercano como
      // hacía YOLO. Si el resultado no es confiable, se conserva el
      // recorte del marco guía sin modificar (ver segmentForeground).
      if (AppSettings.instance.useWatershedSegmentation) {
        final segmented = segmentForeground(toEmbed);
        if (segmented != null) {
          toEmbed = segmented;
          cropMethod = 'watershed_segmentation';
        }
      }

      // YOLO ya no se corre acá. Dejó de decidir el recorte cuando entró el
      // marco guía, y seguía costando cientos de milisegundos en el hilo de
      // UI solo para anotar en las métricas qué clase COCO creía ver — parte
      // del lag que el usuario reportaba entre tocar el botón y tener el
      // objeto guardado.
      // ignore: discarded_futures
      // Se registran las dimensiones reales para no tener que volver a
      // deducir la geometría a partir de una foto: si el recorte vuelve a no
      // corresponder al marco, estos números dicen dónde está el desfase.
      final previewSize = _camera!.value.previewSize;
      MetricsLogger.instance.logCropSelection(
        screen: 'save_object',
        objectLabel: _nameController.text.trim(),
        cropMethod: cropMethod,
        frameSource: _streamActive && _lastFrame != null ? 'preview_stream' : 'take_picture',
        frameWidth: oriented.width,
        frameHeight: oriented.height,
        previewWidth: previewSize?.width.round(),
        previewHeight: previewSize?.height.round(),
        cropSide: toEmbed.width,
      );

      // Guardar el recorte real (antes de normalizar) para el visor
      // "Recortes recientes" de Ajustes — antes solo había metadata en
      // crop_metrics.jsonl, no la imagen, así que no había forma de
      // confirmar a simple vista si el recorte agarró el objeto correcto.
      // Fire-and-forget: no debe retrasar el guardado.
      // ignore: discarded_futures
      MetricsLogger.instance.saveCropDebugImage(
        img.encodeJpg(toEmbed, quality: 85),
        objectLabel: _nameController.text.trim(),
        cropMethod: cropMethod,
      );

      // Y además el encuadre COMPLETO con el marco guía dibujado encima. Es
      // lo que permite contestar a simple vista "¿lo que estaba dentro del
      // marco es de verdad lo que se recortó?" — con solo el recorte final
      // guardado, si salía mal no había forma de distinguir un problema de
      // encuadre del usuario de un problema de geometría del recorte. Se
      // reduce a 640px de lado mayor porque es solo para mirarlo.
      // ignore: discarded_futures
      MetricsLogger.instance.saveCropDebugImage(
        img.encodeJpg(
          img.copyResize(
            drawGuideSquareOverlay(oriented),
            width: oriented.width >= oriented.height ? 640 : null,
            height: oriented.height > oriented.width ? 640 : null,
          ),
          quality: 80,
        ),
        objectLabel: _nameController.text.trim(),
        cropMethod: 'guide_overlay',
      );

      // Normalizar brillo/contraste antes de generar las variantes: que
      // la luz del momento de guardar pese menos al comparar contra la
      // luz del momento de buscar (ver detection_crop.dart).
      toEmbed = normalizeForEmbedding(toEmbed);

      // Reducir UNA sola vez al tamaño de entrada del modelo antes de generar
      // las variantes. Antes cada una de las 12 rotaciones/espejos/brillos se
      // hacía sobre el recorte a resolución completa y recién
      // `embedding_service_native.dart` la reescalaba a 224x224 — o sea, 12
      // veces el trabajo de píxeles sobre imágenes grandes, en el hilo de UI,
      // para terminar en el mismo 224x224. El recorte ya es cuadrado, así que
      // reducirlo acá no deforma nada.
      toEmbed = img.copyResize(toEmbed, width: 224, height: 224);

      // Variantes sintéticas de la MISMA foto ya recortada — sin tomar
      // fotos nuevas ni pedirle nada más al usuario. Además de las
      // rotaciones/espejo originales: ángulos intermedios (en la vida
      // real nadie gira un objeto exactamente 90°), una versión con más
      // zoom (el objeto puede verse más cerca al buscarlo que al
      // guardarlo) y variantes de brillo (distinta luz entre guardar y
      // buscar).
      final variants = <String, img.Image>{
        'original': toEmbed,
        'flip': img.flipHorizontal(toEmbed),
        'zoom_in': centerCrop(toEmbed, fraction: 0.85),
        'bright_up': img.adjustColor(toEmbed, brightness: 1.25),
        'bright_down': img.adjustColor(toEmbed, brightness: 0.75),
      };

      // Las variantes ROTADAS se generan girando el ENCUADRE COMPLETO y
      // recortando el cuadrado guía después, no girando el recorte ya hecho.
      //
      // Antes era `img.copyRotate(toEmbed, angle: 45)` sobre el cuadrado ya
      // recortado: `copyRotate` expande el lienzo y rellena las esquinas de
      // negro, y medido da **50% de la imagen en negro** para 45/135/225/315
      // (0% para 90/180/270, que no necesitan expandir). Ese aspa negra no
      // existe en ninguna foto real, así que esas cuatro variantes no podían
      // coincidir con nada — confirmado en campo: el objeto se reconocía
      // girado a 90° pero NUNCA en diagonal. Girando el frame completo, las
      // esquinas del cuadrado caen sobre contenido real (ver
      // cropCenteredSquare en detection_crop.dart).
      //
      // El frame se reduce una vez para que el cuadrado guía salga cerca de
      // 224px, así las 7 rotaciones no trabajan sobre el encuadre a
      // resolución completa.
      final guideSideFull = kGuideFrameFraction * math.min(oriented.width, oriented.height);
      final rotScale = 224 / guideSideFull;
      final rotSource = rotScale < 1.0
          ? img.copyResize(
              oriented,
              width: (oriented.width * rotScale).round(),
              height: (oriented.height * rotScale).round(),
            )
          : oriented;
      final rotSide =
          (kGuideFrameFraction * math.min(rotSource.width, rotSource.height)).round();
      for (final angle in const [45, 90, 135, 180, 225, 270, 315]) {
        try {
          final rotated = img.copyRotate(rotSource, angle: angle);
          variants['rot$angle'] =
              normalizeForEmbedding(cropCenteredSquare(rotated, rotSide));
        } catch (e) {
          debugPrint('[save_object] No se pudo generar rot$angle: $e');
        }
      }

      final results = <ObjectEmbedding>[];
      for (final entry in variants.entries) {
        List<double> emb;
        try {
          emb = await _embeddings.extractEmbedding(entry.value);
        } catch (e) {
          // Una variante individual fallando (ej. imagen demasiado chica
          // tras el zoom) no debe tirar abajo el resto.
          debugPrint('[save_object] Variante "${entry.key}" falló: $e');
          continue;
        }
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
    // Sin `AspectRatio` externo y sin `StackFit.expand`: antes el preview se
    // metía a la fuerza en una caja con `_camera.value.aspectRatio` (la
    // relación APAISADA del sensor), mientras que `CameraPreview` en camera
    // 0.10.x quiere `1 / value.aspectRatio` cuando el teléfono está vertical.
    // Forzado a llenar esa caja, el preview se estiraba horizontalmente, así
    // que un cuadrado dibujado en pantalla ni siquiera correspondía a un
    // cuadrado del frame.
    //
    // Ahora el `Stack` se dimensiona según `CameraPreview` (que elige su
    // propia relación de aspecto, sin deformarse) y `Positioned.fill` hace
    // que el marco cubra exactamente esa área. Entre el preview y el frame
    // solo queda un escalado uniforme, así que el cuadrado de
    // `0.6 * min(ancho, alto)` en pantalla ES el mismo `0.6 * min(ancho,
    // alto)` que recorta cropToGuideSquare.
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
          children: [
            CameraPreview(_camera!),
            // Marco guía: el recorte que se guarda es EXACTAMENTE esta
            // región (ver kGuideFrameFraction en _captureEmbedding) — así
            // el usuario controla qué entra al recorte, en vez de
            // depender de que YOLO reconozca el objeto correctamente.
            // Antes, cuando había otro objeto reconocible (COCO) cerca
            // del objeto real, YOLO se quedaba con el objeto equivocado
            // (confirmado con datos reales: eligió "teclado" y luego
            // "laptop" en vez de la pastilla que se quería guardar).
            // El marco es CUADRADO (lado = 60% del lado más corto del
            // preview), no un 60%x60% del ancho y del alto — tiene que
            // coincidir exactamente con lo que recorta cropToGuideSquare.
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final side = kGuideFrameFraction *
                          math.min(constraints.maxWidth, constraints.maxHeight);
                      return Semantics(
                        label: 'Marco guía: coloca el objeto dentro de este recuadro',
                        child: SizedBox(
                          width: side,
                          height: side,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Colors.white, width: 3),
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ],
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
            // Sin esto el botón queda con DOS acciones de tap en el árbol de
            // accesibilidad (la del Semantics de arriba y la que el propio
            // GestureDetector publica), y con TalkBack el doble toque las
            // dispara a las dos: el micrófono arrancaba y se cortaba solo en
            // el mismo gesto.
            excludeFromSemantics: true,
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
     if (_isProcessing) {
       label = 'PROCESANDO...';
     } else if (_isSaving) {
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
