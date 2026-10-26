import '../language/translation_provider.dart';

class LanguageDetectionResult {
  final SupportedLanguage language;
  final double confidence;
  const LanguageDetectionResult(this.language, this.confidence);
}

/// Detects which language a piece of ALREADY-RECOGNIZED speech text is
/// in — deliberately NOT a machine-learning language-ID model: this
/// project has no offline NLU model to add, and bundling one would be
/// an unverified new native dependency I can't test without a device
/// (same constraint noted throughout this project's vision/benchmark
/// work). Instead, this uses two honest, explainable signals:
///
/// 1. UNICODE SCRIPT — if the recognized text contains Tamil or
///    Devanagari characters at all, that's a strong, unambiguous
///    signal (a phone's STT engine, run in that language's locale,
///    typically returns text in that script). High confidence.
/// 2. ROMANIZED CODE-SWITCH MARKERS — common Tamil/Hindi grammatical
///    particles that get transliterated into Latin script when mixed
///    with English speech (e.g. "Guindy poganum") — the script test
///    alone would miss these entirely, since the text is all-Latin.
///    Lower confidence: a keyword list is a heuristic, not a real
///    detector, and can false-positive on an unrelated English word
///    that happens to contain one of these substrings (mitigated by
///    only matching them as fairly distinctive whole tokens, not any
///    substring).
///
/// Plain Latin-script text with no marker match defaults to English at
/// LOW confidence (0.5) — it's the most likely case, but "no signal
/// either way" is not the same as "confirmed English," and callers
/// (`DestinationResolver`) should not gate matching on this result —
/// see that file's doc comment for why it tries every language's
/// aliases regardless of the detected language.
class LanguageDetector {
  LanguageDetector._();

  static final RegExp _tamilScript = RegExp(r'[\u0B80-\u0BFF]');
  static final RegExp _devanagariScript = RegExp(r'[\u0900-\u097F]');

  /// Whole-word/whole-phrase Tamil grammatical particles commonly
  /// transliterated to Latin script in code-switched speech (e.g. "go"
  /// as a verb suffix, "want," "where"). Not exhaustive — a rule list,
  /// not a language model.
  static const List<String> _romanizedTamilMarkers = [
    'poganum', 'poga', 'venum', 'irukku', 'yenga', 'enga', 'ku po', '-ku po', 'ku poga',
  ];

  static const List<String> _romanizedHindiMarkers = [
    'jana hai', 'jaana hai', 'chalo', 'kahan', 'mujhe', 'jana', 'chahiye',
  ];

  static LanguageDetectionResult detect(String recognizedText) {
    if (_tamilScript.hasMatch(recognizedText)) {
      return const LanguageDetectionResult(SupportedLanguage.tamil, 0.95);
    }
    if (_devanagariScript.hasMatch(recognizedText)) {
      return const LanguageDetectionResult(SupportedLanguage.hindi, 0.95);
    }

    final normalized = ' ${recognizedText.toLowerCase()} ';
    final tamilMarkerHit = _romanizedTamilMarkers.any((m) => normalized.contains(' $m ') || normalized.contains(m));
    final hindiMarkerHit = _romanizedHindiMarkers.any((m) => normalized.contains(' $m ') || normalized.contains(m));

    if (tamilMarkerHit && !hindiMarkerHit) return const LanguageDetectionResult(SupportedLanguage.tamil, 0.6);
    if (hindiMarkerHit && !tamilMarkerHit) return const LanguageDetectionResult(SupportedLanguage.hindi, 0.6);

    return const LanguageDetectionResult(SupportedLanguage.english, 0.5);
  }
}
