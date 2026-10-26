import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/language/onboarding_phrases.dart';
import 'package:vaishnavi/services/language/translation_provider.dart';

/// Phase F10 regression coverage: the permissions-intro onboarding
/// phrase must disclose that the "describe what's around me" feature
/// sends a camera photo to an online (Gemini) service — previously
/// undisclosed anywhere in the app. Checks every supported language
/// carries SOME form of this disclosure, not just English, since a
/// disclosure only some users can understand isn't a real disclosure.
void main() {
  group('Phase F10 — camera-to-cloud privacy disclosure', () {
    test('English permissionsIntro discloses the online photo-sharing feature', () {
      final phrase = OnboardingPhrases.of(OnboardingPhraseKey.permissionsIntro, SupportedLanguage.english);
      expect(phrase.toLowerCase(), contains('photo'));
      expect(phrase.toLowerCase(), contains('online'));
      expect(phrase.toLowerCase(), contains('describe'));
      // Must clearly convey this is trigger-based, not continuous.
      expect(phrase.toLowerCase(), contains('only happens when you ask'));
    });

    test('every supported language has a permissionsIntro phrase at least as long as the pre-disclosure baseline',
        () {
      // A weak, non-brittle proxy for "the disclosure sentence was
      // actually appended, not just present in English" — every
      // language's string must be meaningfully longer than it was
      // before this addition (each original string was under 260
      // characters; the disclosure sentence adds well over 60).
      for (final language in SupportedLanguage.values) {
        final phrase = OnboardingPhrases.of(OnboardingPhraseKey.permissionsIntro, language);
        expect(phrase.length, greaterThan(260),
            reason: '$language permissionsIntro should carry the appended privacy-disclosure sentence, '
                'not just the original camera/location/microphone/notification explanation');
      }
    });
  });
}
