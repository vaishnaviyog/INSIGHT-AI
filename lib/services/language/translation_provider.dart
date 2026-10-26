/// Languages the architecture supports today. Adding a new language
/// means adding an enum value here plus dictionary entries in a
/// translation provider — no other file needs to change, since
/// everything else consumes language only through
/// [ITranslationProvider] and [LanguageService].
enum SupportedLanguage { english, tamil, hindi, malayalam, telugu }

/// Maps each [SupportedLanguage] to the locale code
/// `flutter_tts`/the OS speech engine expects.
extension SupportedLanguageLocale on SupportedLanguage {
  String get ttsLocaleCode => switch (this) {
        SupportedLanguage.english => 'en-US',
        SupportedLanguage.tamil => 'ta-IN',
        SupportedLanguage.hindi => 'hi-IN',
        SupportedLanguage.malayalam => 'ml-IN',
        SupportedLanguage.telugu => 'te-IN',
      };

  /// Locale id passed to `AudioService.listen(localeId: ...)` for
  /// voice onboarding (Stage 1). Uses the SAME code as
  /// [ttsLocaleCode] — `speech_to_text`'s `localeId` is conventionally
  /// BCP-47-style like TTS locales, but this hasn't been verified
  /// against every real device's installed STT language pack; if a
  /// device lacks the matching STT locale, `AudioService.listen` will
  /// fail via its `onError` callback, which `VoiceOnboardingController`
  /// already treats as a recognition failure — re-asking the current
  /// question (see its doc comment) rather than crashing.
  String get sttLocaleId => ttsLocaleCode;
}

/// Contract for turning English text (as generated elsewhere in the
/// app — route instructions, hazard warnings) into text in a target
/// language.
///
/// THIS IS THE SEAM THAT SEPARATES THE THREE PIPELINE STAGES the
/// milestone asks for: text generation (existing code, unchanged) →
/// translation (this interface) → speech synthesis
/// ([LanguageService.speak], via the existing, unmodified
/// `AudioService.speak`). A future real machine-translation API
/// (Google Cloud Translation, ML Kit Translation, etc.) becomes usable
/// by implementing this interface and swapping it into
/// [LanguageService]'s constructor — nothing else in the app changes.
abstract class ITranslationProvider {
  Future<TranslationResult> translate(String englishText, SupportedLanguage targetLanguage);
}

/// [text] is what should actually be spoken. [wasTranslated] tells the
/// caller whether [text] is genuinely in [SupportedLanguage] script
/// (so the TTS locale should switch to match) or is an honest
/// pass-through of the original English (so the TTS locale should
/// stay English, rather than mispronouncing English words under a
/// non-English voice). See [LanguageService.speak].
class TranslationResult {
  final String text;
  final bool wasTranslated;
  const TranslationResult(this.text, {required this.wasTranslated});
}
