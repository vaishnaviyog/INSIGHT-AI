import '../../services/language/translation_provider.dart';

enum DestinationMatchType { exactAlias, fuzzyAlias, noMatch }

/// Result of resolving raw recognized speech into something the
/// EXISTING geocoder (`LocationService.getCoordinatesFromAddress`) can
/// use. Never carries a coordinate itself — see
/// `DestinationAliasDictionary`'s doc comment for why that's a
/// deliberate boundary, not a missing feature.
class DestinationResolution {
  final String originalText;
  final String searchQuery;
  final String displayName;
  final DestinationMatchType matchType;
  final double confidence; // 0.0-1.0
  final SupportedLanguage detectedLanguage;
  final double languageDetectionConfidence;

  const DestinationResolution({
    required this.originalText,
    required this.searchQuery,
    required this.displayName,
    required this.matchType,
    required this.confidence,
    required this.detectedLanguage,
    required this.languageDetectionConfidence,
  });

  /// Per Phase 1 requirement 8: below this, the app should ask the
  /// user to confirm rather than assume. Not private — the voice
  /// onboarding-adjacent UI flow that will eventually consume this
  /// (see this file's own doc comment on scope) needs to check it.
  static const double confirmationThreshold = 0.75;

  bool get needsConfirmation => confidence < confirmationThreshold;
}
