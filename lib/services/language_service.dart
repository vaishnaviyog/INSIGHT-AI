import 'package:hive_flutter/hive_flutter.dart';

import 'audio_service.dart';
import 'language/static_translation_provider.dart';
import 'language/translation_provider.dart';

/// Coordinates the translation → speech-synthesis pipeline.
///
/// PIPELINE SEPARATION (the milestone's core requirement): TEXT
/// GENERATION stays exactly where it already lives — the existing
/// code in `navigation_screen.dart` / `AdaptiveGuidanceService` that
/// builds English sentences is completely unchanged. This class only
/// owns the two stages after that: TRANSLATION (delegated to an
/// injected [ITranslationProvider] — swappable, see that interface's
/// doc comment) and triggering SPEECH SYNTHESIS (via AudioService's
/// existing, unmodified `speak()` — the only new capability added to
/// AudioService is `setLanguage()`, a locale switch, not a change to
/// how speech itself works).
///
/// NO HARDCODED LANGUAGE LOGIC ELSEWHERE: any call site that wants
/// localized speech calls `LanguageService.speak(...)` instead of
/// `AudioService.speak(...)` directly. Everything language-specific
/// — which locale, which dictionary, which languages exist at all —
/// is contained here and in `language/`. Adding a 6th language means
/// adding an enum value to [SupportedLanguage] and dictionary entries
/// to a provider; no call site changes.
class LanguageService {
  static const String _boxName = 'language_preference_box';
  static const String _languageKey = 'selectedLanguage';

  final ITranslationProvider _translationProvider;

  late Box _box;
  bool _initialized = false;
  SupportedLanguage _currentLanguage = SupportedLanguage.english;

  /// [translationProvider] defaults to the offline
  /// [StaticTranslationProvider]. Pass a different implementation
  /// (e.g. a future real MT API client) to swap it — see
  /// [ITranslationProvider].
  LanguageService({ITranslationProvider? translationProvider})
      : _translationProvider = translationProvider ?? StaticTranslationProvider();

  SupportedLanguage get currentLanguage => _currentLanguage;

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    final stored = _box.get(_languageKey) as String?;
    if (stored != null) {
      _currentLanguage = SupportedLanguage.values.firstWhere(
        (l) => l.name == stored,
        orElse: () => SupportedLanguage.english,
      );
    }
    _initialized = true;
  }

  Future<void> setLanguage(SupportedLanguage language) async {
    _currentLanguage = language;
    if (_initialized) {
      await _box.put(_languageKey, language.name);
    }
  }

  /// Translates [englishText] to the current language and speaks it
  /// via [audioService]. Behavior-preserving by construction: with the
  /// default language (English), `translate()` returns the input
  /// unchanged and the locale is already "en-US" — so this is a no-op
  /// difference from calling `audioService.speak()` directly until a
  /// non-English language is actually selected.
  ///
  /// IMPORTANT: the TTS locale only switches to [_currentLanguage] when
  /// [_translationProvider] reports the text was genuinely translated
  /// ([TranslationResult.wasTranslated]). For text it couldn't
  /// translate (honest pass-through, e.g. free-form scene descriptions
  /// or unrecognized phrasing), this keeps the English voice — reading
  /// English text under, say, a Tamil TTS voice mispronounces it badly,
  /// which is worse than just speaking it in English.
  Future<void> speak(AudioService audioService, String englishText) async {
    final result = await _translationProvider.translate(englishText, _currentLanguage);
    final locale = result.wasTranslated
        ? _currentLanguage.ttsLocaleCode
        : SupportedLanguage.english.ttsLocaleCode;
    await audioService.setLanguage(locale);
    await audioService.speak(result.text);
  }

  Future<void> dispose() async {
    if (_initialized) {
      await _box.close();
    }
  }
}
