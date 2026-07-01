import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../services/tts.dart';

/// Pantalla TEMPORAL de diagnóstico para entender por qué el STT offline
/// falla en un equipo específico (caso original: Samsung Galaxy A30s con
/// `error_language_unavailable`). Muestra en pantalla y narra por voz:
/// conectividad, motor de reconocimiento nativo, locales disponibles y el
/// resultado crudo de intentar reconocer con distintos locales.
class SttDiagnosticsScreen extends StatefulWidget {
  const SttDiagnosticsScreen({super.key});

  @override
  State<SttDiagnosticsScreen> createState() => _SttDiagnosticsScreenState();
}

class _SttDiagnosticsScreenState extends State<SttDiagnosticsScreen> {
  static const MethodChannel _nativeChannel =
      MethodChannel('aura/stt_diagnostics');

  final AudioFeedback _audio = AudioFeedback();
  final SpeechToText _speech = SpeechToText();

  final List<String> _lines = [];
  bool _running = true;
  bool _liveTestRunning = false;
  Completer<String>? _pendingTest;

  @override
  void initState() {
    super.initState();
    _audio.init();
    _speech.initialize(onStatus: _onStatus, onError: _onError, debugLogging: true);
    _runDiagnostics();
  }

  @override
  void dispose() {
    _speech.stop();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _report(String line) async {
    if (!mounted) return;
    setState(() => _lines.add(line));
    await _audio.speak(line);
  }

  void _onStatus(String status) {
    final pending = _pendingTest;
    if (pending != null &&
        !pending.isCompleted &&
        (status == 'notListening' || status == 'done')) {
      // Si llegamos hasta acá sin que _onError haya disparado, el locale fue
      // ACEPTADO por el reconocedor (no hubo error_language_unavailable ni
      // similar); simplemente no se detectó/reconoció voz en la ventana
      // corta de esta prueba puntual.
      pending.complete(
          'locale aceptado sin error, pero sin voz reconocida en la ventana '
          'de prueba (status: $status)');
    }
  }

  void _onError(SpeechRecognitionError error) {
    final pending = _pendingTest;
    if (pending != null && !pending.isCompleted) {
      pending.complete(
          'error: ${error.errorMsg} (permanent: ${error.permanent})');
    }
  }

  Future<void> _runDiagnostics() async {
    await _report('Iniciando diagnóstico de reconocimiento de voz.');

    final hasInternet = await _checkInternet();
    await _report(
        '1. Internet disponible: ${hasInternet ? "sí" : "no"}.');

    final native = await _nativeInfo();
    await _report(
        '2. Equipo: ${native['manufacturer'] ?? "?"} ${native['model'] ?? "?"}, '
        'Android API ${native['sdkInt'] ?? "?"}.');
    await _report(
        'App que resolvería el reconocimiento de voz: '
        '${native['recognizerActivityPackage'] ?? "ninguna encontrada"}.');
    final services = (native['recognitionServices'] as List?) ?? const [];
    await _report(
        'Servicios RecognitionService instalados: '
        '${services.isEmpty ? "ninguno" : services.join(', ')}.');
    final onDeviceAvailable = native['onDeviceAvailable'];
    await _report(
        'Reconocimiento on-device disponible a nivel de equipo: '
        '${onDeviceAvailable == null ? "no aplica (Android menor a 12)" : (onDeviceAvailable == true ? "sí" : "no")}.');

    final available = await _speech.initialize(
        onStatus: _onStatus, onError: _onError, debugLogging: true);
    await _report(
        '3. Motor speech_to_text inicializado correctamente: '
        '${available ? "sí" : "no"}.');

    if (available) {
      final locales = await _speech.locales();
      await _report(
          '4. Locales que reporta el equipo (${locales.length}): '
          '${locales.isEmpty ? "ninguno" : locales.map((l) => l.localeId).join(', ')}.');
    }

    await _report(
        '5. Nota: Android no ofrece una API pública para saber si el '
        'paquete offline de un locale específico está descargado; el único '
        'dato de disponibilidad on-device es a nivel de equipo (punto 2).');

    for (final locale in ['es_PE', 'es_ES', 'es_US']) {
      final res = await _tryLocale(locale);
      await _report('Intento de escucha con locale "$locale": $res');
    }

    await _report(
        'Diagnóstico inicial completo. Podés usar el botón de abajo para '
        'una prueba de reconocimiento en vivo de 3 segundos.');
    if (mounted) setState(() => _running = false);
  }

  Future<bool> _checkInternet() async {
    if (kIsWeb) return true; // No aplica: en Web el permiso/red los maneja el navegador.
    try {
      final result = await InternetAddress.lookup('google.com')
          .timeout(const Duration(seconds: 4));
      return result.isNotEmpty && result.first.rawAddress.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> _nativeInfo() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return {
        'recognitionServices': const [],
        'recognizerActivityPackage': 'N/A (no es Android)',
        'onDeviceAvailable': null,
      };
    }
    try {
      final result = await _nativeChannel.invokeMethod('diagnostics');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {
        'recognitionServices': const [],
        'recognizerActivityPackage': 'error: $e',
        'onDeviceAvailable': null,
      };
    }
  }

  /// Intenta escuchar 2s con [localeId] forzado y devuelve el resultado o
  /// error crudo que reporte el motor.
  Future<String> _tryLocale(String localeId) async {
    if (_speech.isListening) await _speech.stop();
    final completer = Completer<String>();
    _pendingTest = completer;
    try {
      await _speech.listen(
        onResult: (_) {},
        localeId: localeId,
        listenFor: const Duration(seconds: 2),
        listenOptions: SpeechListenOptions(
          partialResults: false,
          cancelOnError: true,
          onDevice: true,
        ),
      );
    } catch (e) {
      if (!completer.isCompleted) completer.complete('excepción: $e');
    }
    final result = await completer.future.timeout(
      const Duration(seconds: 4),
      onTimeout: () => 'sin respuesta (timeout)',
    );
    await _speech.stop();
    _pendingTest = null;
    return result;
  }

  Future<void> _runLiveTest() async {
    if (_liveTestRunning) return;
    setState(() => _liveTestRunning = true);
    await _report('6. Prueba en vivo: hablá algo durante los próximos 3 segundos.');

    if (_speech.isListening) await _speech.stop();
    final completer = Completer<String>();
    _pendingTest = completer;
    String? partial;
    try {
      await _speech.listen(
        onResult: (SpeechRecognitionResult r) {
          if (r.recognizedWords.isNotEmpty) partial = r.recognizedWords;
          if (r.finalResult && !completer.isCompleted) {
            completer.complete('texto reconocido: "${r.recognizedWords}"');
          }
        },
        localeId: null,
        listenFor: const Duration(seconds: 3),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: true,
          onDevice: true,
        ),
      );
    } catch (e) {
      if (!completer.isCompleted) completer.complete('excepción: $e');
    }
    final result = await completer.future.timeout(
      const Duration(seconds: 6),
      onTimeout: () => partial != null
          ? 'texto parcial (sin resultado final): "$partial"'
          : 'sin resultado (timeout)',
    );
    await _speech.stop();
    _pendingTest = null;
    await _report('Resultado de la prueba en vivo: $result');
    if (mounted) setState(() => _liveTestRunning = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('Diagnóstico STT',
            style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _lines.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _lines[i],
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              ),
            ),
            if (_running)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: CircularProgressIndicator(color: Colors.white70),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_running || _liveTestRunning) ? null : _runLiveTest,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2196F3),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: Text(
                    _liveTestRunning
                        ? 'Escuchando...'
                        : 'Probar reconocimiento ahora (3s)',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
