package com.example.aura_app

import android.content.Intent
import android.os.Build
import android.speech.RecognitionService
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Diagnóstico temporal de STT ("aura/stt_diagnostics"): expone datos que el
/// plugin speech_to_text no publica hacia Dart (paquete del motor de
/// reconocimiento, disponibilidad on-device a nivel de equipo).
class MainActivity : FlutterActivity() {
    private val diagnosticsChannel = "aura/stt_diagnostics"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, diagnosticsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "diagnostics") {
                    result.success(collectDiagnostics())
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun collectDiagnostics(): Map<String, Any?> {
        val pm = packageManager

        // Servicios que implementan RecognitionService: son los candidatos que
        // SpeechRecognizer.createSpeechRecognizer() puede terminar usando.
        val services = pm.queryIntentServices(Intent(RecognitionService.SERVICE_INTERFACE), 0)
        val servicePackages = services.mapNotNull { it.serviceInfo?.packageName }.distinct()

        // App que resolvería el intent clásico de reconocimiento (normalmente
        // la app de Google, si está instalada).
        val recognizerActivityPackage =
            pm.resolveActivity(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH), 0)
                ?.activityInfo?.packageName

        val onDeviceAvailable: Boolean? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                SpeechRecognizer.isOnDeviceRecognitionAvailable(applicationContext)
            } else {
                null // La API pública de Android no existe antes de API 31.
            }

        return mapOf(
            "recognitionServices" to servicePackages,
            "recognizerActivityPackage" to recognizerActivityPackage,
            "onDeviceAvailable" to onDeviceAvailable,
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
        )
    }
}
