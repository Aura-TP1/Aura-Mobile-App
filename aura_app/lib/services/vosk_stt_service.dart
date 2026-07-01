import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:vosk_flutter/vosk_flutter.dart';

const String _kLogTag = 'VoskSTT';

/// Tier 2 del fallback de voz: reconocimiento offline con el modelo Vosk
/// chico de español (`assets/vosk-model-small-es-0.42.zip`), bundleado en la
/// app para que funcione sin haber tenido internet nunca (a diferencia de
/// descargar el modelo la primera vez, que sería inútil justo cuando no hay
/// conexión). Solo soportado en Android — `vosk_flutter` no tiene build de
/// iOS/Web.
class VoskSttService {
  static const String _modelAsset = 'assets/vosk-model-small-es-0.42.zip';
  static const int _sampleRate = 16000;

  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  final ModelLoader _modelLoader = ModelLoader();

  Model? _model;
  Recognizer? _recognizer;
  SpeechService? _speechService;
  Completer<String?>? _pending;
  StreamSubscription<String>? _resultSub;
  StreamSubscription<String>? _partialSub;

  bool get isSupported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// `true` si el modelo todavía no fue descomprimido en este dispositivo
  /// (para avisar por TTS antes de la primera espera larga).
  Future<bool> needsFirstTimeSetup() async {
    if (!isSupported || _model != null) return false;
    try {
      final loaded = await _modelLoader.isModelAlreadyLoaded('vosk-model-small-es-0.42');
      debugPrint('$_kLogTag: ¿modelo ya cargado?: $loaded');
      return !loaded;
    } catch (e) {
      debugPrint('$_kLogTag: error chequeando si el modelo está cargado: $e');
      return true;
    }
  }

  Future<bool> _ensureReady() async {
    if (!isSupported) {
      debugPrint('$_kLogTag: plataforma no soportada, salteando Vosk.');
      return false;
    }
    final sw = Stopwatch()..start();
    try {
      if (_model == null) {
        debugPrint('$_kLogTag: cargando modelo desde assets...');
        final modelPath = await _modelLoader.loadFromAssets(_modelAsset);
        debugPrint('$_kLogTag: modelo descomprimido en ${sw.elapsedMilliseconds}ms → $modelPath');
        _model = await _vosk.createModel(modelPath);
        debugPrint('$_kLogTag: Model creado en ${sw.elapsedMilliseconds}ms');
      }
      if (_recognizer == null) {
        _recognizer = await _vosk.createRecognizer(model: _model!, sampleRate: _sampleRate);
        debugPrint('$_kLogTag: Recognizer creado en ${sw.elapsedMilliseconds}ms');
      }
      if (_speechService == null) {
        _speechService = await _vosk.initSpeechService(_recognizer!);
        debugPrint('$_kLogTag: SpeechService inicializado en ${sw.elapsedMilliseconds}ms');
      }
      return true;
    } catch (e, st) {
      debugPrint('$_kLogTag: no disponible tras ${sw.elapsedMilliseconds}ms: $e\n$st');
      return false;
    }
  }

  /// Escucha hasta obtener un resultado o hasta [timeout]. Devuelve `null`
  /// si Vosk no está disponible, no se entendió nada, o se llamó [stop].
  ///
  /// [timeout] cuenta solo desde que el micrófono efectivamente arranca (no
  /// incluye la carga del modelo, que ya se resuelve en [_ensureReady]).
  Future<String?> listen({Duration timeout = const Duration(seconds: 8)}) async {
    if (!await _ensureReady()) return null;

    final completer = Completer<String?>();
    _pending = completer;
    _resultSub = _speechService!.onResult().listen((jsonResult) {
      debugPrint('$_kLogTag: onResult crudo: $jsonResult');
      final text = _extractText(jsonResult);
      if (text != null && !completer.isCompleted) completer.complete(text);
    });
    _partialSub = _speechService!.onPartial().listen((jsonResult) {
      debugPrint('$_kLogTag: onPartial crudo: $jsonResult');
    });

    try {
      debugPrint('$_kLogTag: arrancando SpeechService.start()...');
      final started = await _speechService!.start();
      debugPrint('$_kLogTag: start() devolvió $started, escuchando hasta ${timeout.inSeconds}s...');
      final result = await completer.future.timeout(
        timeout,
        onTimeout: () {
          debugPrint('$_kLogTag: timeout sin resultado final.');
          return null;
        },
      );
      await _speechService!.stop();
      debugPrint('$_kLogTag: resultado devuelto: $result');
      return result;
    } catch (e, st) {
      debugPrint('$_kLogTag: error durante el reconocimiento: $e\n$st');
      if (!completer.isCompleted) completer.complete(null);
      return null;
    } finally {
      await _resultSub?.cancel();
      await _partialSub?.cancel();
      _resultSub = null;
      _partialSub = null;
      _pending = null;
    }
  }

  Future<void> stop() async {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    await _speechService?.stop();
  }

  String? _extractText(String json) {
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      final text = (map['text'] as String?)?.trim();
      return (text == null || text.isEmpty) ? null : text;
    } catch (e) {
      debugPrint('$_kLogTag: no se pudo parsear el JSON de resultado: $e');
      return null;
    }
  }
}
