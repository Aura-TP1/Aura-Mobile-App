import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:vibration/vibration.dart';

/// Envoltorio simple sobre flutter_tts con cola anti‑repetición y feedback
/// háptico. Diseñado para una experiencia "voice-first" para adultos mayores.
class AudioFeedback {
  final FlutterTts _tts = FlutterTts();

  // Estado para announce(label) legacy (una sola etiqueta).
  String _lastSpoken = '';
  DateTime _lastSpokenAt = DateTime.fromMillisecondsSinceEpoch(0);

  // Estado para announceScene(...) — anuncio del conjunto de objetos.
  List<String> _lastAnnouncedSet = const [];
  DateTime _lastSceneAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Flag para no interrumpir un anuncio de escena en curso. Solo aplica a
  /// [announceScene]; [speak] sí puede interrumpir (instrucciones deliberadas).
  bool _isSpeaking = false;

  /// Tiempo mínimo entre anuncios (spec: ≥ 3 s).
  static const Duration repeatCooldown = Duration(seconds: 3);

  Future<void> init() async {
    // Idioma: es-PE (aceptado por el spec junto con es-MX). Se mantiene el
    // que ya funcionaba en los dispositivos de prueba.
    await _tts.setLanguage('es-PE');
    // Esperar a que termine cada locución evita que las siguientes la pisen.
    await _tts.awaitSpeakCompletion(true);
    // 0.45 ≈ 0.85x del ritmo normal en flutter_tts (0.5 = normal en Android):
    // claro y pausado para adultos mayores.
    await _tts.setSpeechRate(0.45);
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
  }

  /// Habla un texto arbitrario, cancelando lo anterior. Para instrucciones y
  /// mensajes de estado donde sí queremos interrumpir.
  Future<void> speak(String text) async {
    _isSpeaking = false; // un speak() deliberado anula un anuncio en curso
    await _tts.stop();
    await _tts.speak(text);
  }

  /// Anuncia el CONJUNTO de objetos detectados como una sola frase natural,
  /// p. ej. "Veo una mesa, una silla y un celular".
  ///
  /// Reglas (spec):
  /// - Solo habla cuando el conjunto cambia respecto al último anunciado.
  /// - Respeta un mínimo de [repeatCooldown] entre anuncios.
  /// - No interrumpe un anuncio que aún se está reproduciendo.
  Future<void> announceScene(List<String> labels) async {
    if (_isSpeaking) return;

    // Dedup preservando orden; máx 3 para no saturar al usuario.
    final unique = <String>[];
    for (final l in labels) {
      if (l.isEmpty) continue;
      if (!unique.contains(l)) unique.add(l);
      if (unique.length >= 3) break;
    }
    if (unique.isEmpty) return;

    final now = DateTime.now();
    final sameAsLast = _listEquals(unique, _lastAnnouncedSet);
    // Si no cambió nada, no repetir. Si cambió, igual respetar el cooldown.
    if (sameAsLast) return;
    if (now.difference(_lastSceneAt) < repeatCooldown) return;

    _lastAnnouncedSet = unique;
    _lastSceneAt = now;

    _isSpeaking = true;
    await _tts.stop();
    await _tts.speak(_buildScenePhrase(unique));
    _isSpeaking = false;
  }

  /// Anuncio de una sola etiqueta (legacy). Se conserva por compatibilidad.
  Future<void> announce(String label) async {
    final now = DateTime.now();
    if (label == _lastSpoken && now.difference(_lastSpokenAt) < repeatCooldown) {
      return;
    }
    _lastSpoken = label;
    _lastSpokenAt = now;
    await _tts.stop();
    await _tts.speak('Detectado: $label');
  }

  /// Feedback háptico breve (200 ms por defecto) al confirmar acciones.
  Future<void> haptic([int milliseconds = 200]) async {
    try {
      final hasVibrator = (await Vibration.hasVibrator()) == true;
      if (hasVibrator) {
        await Vibration.vibrate(duration: milliseconds);
      }
    } catch (e) {
      debugPrint('Haptic no disponible: $e');
    }
  }

  /// Reinicia la memoria de anuncios (útil al reanudar/cambiar de modo).
  void resetScene() {
    _lastAnnouncedSet = const [];
    _lastSceneAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  Future<void> stop() {
    _isSpeaking = false;
    return _tts.stop();
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  String _buildScenePhrase(List<String> items) {
    final withArticles = items.map(_withArticle).toList();
    if (withArticles.length == 1) return 'Veo ${withArticles.first}';
    final last = withArticles.removeLast();
    return 'Veo ${withArticles.join(', ')} y $last';
  }

  /// Artículo indefinido aproximado por terminación. Heurística simple pero
  /// suficiente para las etiquetas COCO ("mesa"→una, "celular"→un).
  String _withArticle(String label) {
    final l = label.trim();
    final feminine = l.endsWith('a') || l.endsWith('as');
    return '${feminine ? 'una' : 'un'} $l';
  }

  bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
