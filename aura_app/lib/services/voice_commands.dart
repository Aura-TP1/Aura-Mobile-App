/// Parser de comandos de voz "voice-first" para AURA.
///
/// Reconoce los comandos clave del spec, tolerando el prefijo opcional
/// "Aura" y variaciones comunes de transcripción del STT:
///
///   - "Aura qué ves"            → describe (modo detección de objetos)
///   - "Aura lee" / "lee esto"   → readText (modo OCR)
///   - "Aura guarda esto como X" → save (argument = X)
///   - "Aura busca X"            → search (argument = X)
///   - "Aura para"               → stop
///
/// Es lógica pura (sin dependencias de Flutter) para poder testearse y
/// reutilizarse desde cualquier pantalla.
enum AuraCommandType { describe, readText, save, search, stop, unknown }

class AuraCommand {
  final AuraCommandType type;

  /// Nombre del objeto a guardar/buscar. `null` si el comando no lleva
  /// argumento o no se pudo extraer.
  final String? argument;

  const AuraCommand(this.type, [this.argument]);
}

class VoiceCommandParser {
  static AuraCommand parse(String raw) {
    final lower = raw.toLowerCase().trim();
    if (lower.isEmpty) return const AuraCommand(AuraCommandType.unknown);

    // Quitar el prefijo de activación "aura" aunque venga seguido de coma,
    // dos puntos o guion, algo común en transcripciones Android.
    final s = lower.replaceFirst(RegExp(r'^aura[\s,.:;-]+'), '').trim();

    // "para" / "detente" / "alto" / "silencio" → detener.
    if (RegExp(r'\b(para|det[eé]nte|detener|alto|silencio|c[aá]llate|calla|silencia|pausa)\b')
        .hasMatch(s)) {
      return const AuraCommand(AuraCommandType.stop);
    }

    // OCR: "lee", "leer", "texto", "qué dice", "modo lectura".
    if (RegExp(r'\b(lee|leer|lectura|texto|que dice|qu[eé] dice|lectura de texto)\b')
        .hasMatch(s)) {
      return const AuraCommand(AuraCommandType.readText);
    }

    // "guarda esto como X" / "guarda X" / "guardar X".
    final saveMatch = RegExp(
      r'guarda(?:r)?\s+(?:esto|este|esta)?\s*(?:como|llamado|llamada)?\s*(.*)$',
    ).firstMatch(s);
    if (s.contains('guarda')) {
      final name = saveMatch?.group(1)?.trim();
      return AuraCommand(
        AuraCommandType.save,
        (name == null || name.isEmpty) ? null : name,
      );
    }

    // "busca X" / "buscar X" / "encuentra X" / "localiza X".
    final searchMatch =
      RegExp(r'(?:busca(?:r)?|encuentra|localiza)\s+(.*)$').firstMatch(s);
    if (searchMatch != null) {
      final obj = searchMatch.group(1)?.trim();
      return AuraCommand(
        AuraCommandType.search,
        (obj == null || obj.isEmpty) ? null : obj,
      );
    }

    // "qué ves" / "que ves" / "describe" / "qué hay" / "muestra".
    // "vez" se acepta como alternativa a "ves": son homófonos en seseo
    // (Latinoamérica) y el modelo chico de Vosk los confunde seguido.
    if (RegExp(r'qu[eé]\s+(ves|vez|hay|es)|describe|describir|muestra|muéstrame|veo')
        .hasMatch(s)) {
      return const AuraCommand(AuraCommandType.describe);
    }

    // "modo objetos" / "detecta" → volver a detección.
    if (RegExp(r'\b(objetos|detecta|detectar)\b').hasMatch(s)) {
      return const AuraCommand(AuraCommandType.describe);
    }

    return const AuraCommand(AuraCommandType.unknown);
  }
}
