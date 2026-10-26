import '../../models/voice_understanding/destination_resolution.dart';
import 'destination_alias_dictionary.dart';
import 'fuzzy_matcher.dart';
import 'language_detector.dart';

/// Converts raw recognized speech ("Gundy poganum," "Tambram," "CMBT")
/// into a [DestinationResolution] carrying a search query the EXISTING
/// geocoder can use — never a coordinate, never a guess dressed up as
/// certainty (see [DestinationResolution.needsConfirmation]).
///
/// TRIES EVERY LANGUAGE'S ALIASES REGARDLESS OF DETECTED LANGUAGE: code-
/// switched speech ("Guindy poganum," "Central-ku po") mixes an English
/// place name with Tamil grammar, so gating alias matching on the
/// detected language would miss exactly the cases this phase named as
/// examples. `LanguageDetector`'s result is attached to the resolution
/// for logging/instrumentation, not used to filter which aliases are
/// considered.
///
/// CODE-SWITCH HANDLING IS RULE-BASED, NOT A REAL PARSER: a fixed list
/// of common filler phrases/particles is stripped before matching.
/// This covers the specific examples given ("poganum," "-ku po," "I
/// want to go to") — it is not a general code-switching NLU system,
/// and doesn't claim to be.
class DestinationResolver {
  static const List<String> _fillerPhrases = [
    // Tamil-English code-switch particles (checked longest-first so
    // "ku poga" doesn't get partially eaten by a shorter "poga" match
    // leaving a stray "ku").
    'ku poganum', 'poga venum', 'ku poga', 'poganum', 'venum', 'ku po',
    // Hindi-English code-switch particles.
    'jana hai', 'jaana hai', 'chahiye', 'chalo',
    // Plain English carrier phrases.
    'i want to go to', 'i want to go', 'take me to', 'navigate me to', 'navigate to', 'go to',
  ];

  static const int _maxFuzzyEditDistance = 3;
  static const double _maxRelativeFuzzyDistance = 0.4;

  String _stripFillerPhrases(String text) {
    var result = ' ${text.toLowerCase().trim()} ';
    for (final phrase in _fillerPhrases) {
      result = result.replaceAll(phrase, ' ');
    }
    result = result.replaceAll('-', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return result;
  }

  /// AUDIT FIX (engineering-hardening phase — voice false-capture
  /// investigation): real, live-observed STT artifacts this session —
  /// "Anna Nagar Anna" and "T Nagar T" — are a self-repeated phrase at
  /// the END of the recognized text, not a truncation. The likely
  /// cause is the destination-capture `pauseFor` (3s, see
  /// `home_screen.dart`/`navigation_screen.dart`): a user unsure
  /// whether they were heard sometimes repeats themselves within that
  /// window, and the STT engine concatenates both attempts into one
  /// "final" result rather than treating them as separate utterances.
  ///
  /// This does NOT replace the existing destination-confirmation
  /// safety net (`NavigationScreen._confirmDestinationWithUser`,
  /// bounded, requires an explicit affirmative answer) — that remains
  /// the actual safety guarantee. This exists because a garbled
  /// confirmation prompt ("I understood your destination as Anna
  /// Nagar Anna. Is that correct?") is a real trust/usability problem
  /// even when it's never silently accepted, AND because a cleaner
  /// query measurably improves how well [resolve] can match it against
  /// the alias dictionary/GTFS stops in the first place.
  ///
  /// ALGORITHM: checks whether the trailing `k` words are an EXACT,
  /// case-insensitive repeat of the leading `k` words, for the LARGEST
  /// `k` up to half the word count — largest-first so a genuine
  /// multi-word repeat ("anna nagar anna nagar") is caught by its own
  /// full match before a shorter coincidental one-word match could
  /// mis-fire. If found, the trailing repeated words are dropped.
  /// Deliberately requires an EXACT word-for-word prefix match, not
  /// just a shared first word — "Anna Nagar Anna Salai" is a
  /// genuinely different (if unusual) 4-word destination, not a
  /// repetition artifact, and must NOT be collapsed: checking k=2
  /// there compares ["anna","salai"] against ["anna","nagar"], which
  /// does not match, so the text passes through unchanged.
  static String collapseImmediateRepetition(String text) {
    final words = text.trim().split(RegExp(r'\s+'));
    final n = words.length;
    if (n < 2) return text;
    for (int k = n ~/ 2; k >= 1; k--) {
      final leading = words.sublist(0, k);
      final trailing = words.sublist(n - k);
      var isRepeat = true;
      for (int i = 0; i < k; i++) {
        if (leading[i].toLowerCase() != trailing[i].toLowerCase()) {
          isRepeat = false;
          break;
        }
      }
      if (isRepeat) return words.sublist(0, n - k).join(' ');
    }
    return text;
  }

  DestinationResolution resolve(String recognizedText) {
    final languageResult = LanguageDetector.detect(recognizedText);
    final cleaned = collapseImmediateRepetition(_stripFillerPhrases(recognizedText));

    if (cleaned.isEmpty) {
      return DestinationResolution(
        originalText: recognizedText,
        searchQuery: recognizedText,
        displayName: recognizedText,
        matchType: DestinationMatchType.noMatch,
        confidence: 0.2,
        detectedLanguage: languageResult.language,
        languageDetectionConfidence: languageResult.confidence,
      );
    }

    // 1. Exact alias match.
    for (final (alias, entry) in DestinationAliasDictionary.flattenedAliases) {
      if (alias.toLowerCase() == cleaned) {
        return DestinationResolution(
          originalText: recognizedText,
          searchQuery: entry.canonicalSearchQuery,
          displayName: entry.canonicalDisplayName,
          matchType: DestinationMatchType.exactAlias,
          confidence: 0.97,
          detectedLanguage: languageResult.language,
          languageDetectionConfidence: languageResult.confidence,
        );
      }
    }

    // 2. Fuzzy match — corrects STT mistakes like "Tambram"/"Gundy"/
    // "Kindy" against the dictionary's known aliases.
    final allAliasTexts = DestinationAliasDictionary.flattenedAliases.map((e) => e.$1).toList();
    final fuzzy = FuzzyMatcher.bestMatch(cleaned, allAliasTexts);
    if (fuzzy != null) {
      final relativeDistance = fuzzy.match.isEmpty ? 1.0 : fuzzy.distance / fuzzy.match.length;
      if (fuzzy.distance <= _maxFuzzyEditDistance && relativeDistance <= _maxRelativeFuzzyDistance) {
        final entry = DestinationAliasDictionary.flattenedAliases.firstWhere((e) => e.$1 == fuzzy.match).$2;
        final confidence = (1.0 - relativeDistance).clamp(0.5, 0.9);
        return DestinationResolution(
          originalText: recognizedText,
          searchQuery: entry.canonicalSearchQuery,
          displayName: entry.canonicalDisplayName,
          matchType: DestinationMatchType.fuzzyAlias,
          confidence: confidence,
          detectedLanguage: languageResult.language,
          languageDetectionConfidence: languageResult.confidence,
        );
      }
    }

    // 3. No confident match in the dictionary — pass the CLEANED text
    // (filler phrases stripped, but otherwise unmodified) straight to
    // the geocoder. Low confidence: this is genuinely uncertain, not
    // silently treated as correct.
    return DestinationResolution(
      originalText: recognizedText,
      searchQuery: cleaned,
      displayName: recognizedText.trim(),
      matchType: DestinationMatchType.noMatch,
      confidence: 0.3,
      detectedLanguage: languageResult.language,
      languageDetectionConfidence: languageResult.confidence,
    );
  }
}
