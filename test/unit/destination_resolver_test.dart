import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/voice_understanding/destination_resolution.dart';
import 'package:vaishnavi/services/voice_understanding/destination_resolver.dart';
import 'package:vaishnavi/services/voice_understanding/fuzzy_matcher.dart';

void main() {
  group('FuzzyMatcher.levenshtein', () {
    test('identical strings have distance 0', () {
      expect(FuzzyMatcher.levenshtein('guindy', 'guindy'), 0);
    });

    test('a single substitution has distance 1', () {
      expect(FuzzyMatcher.levenshtein('guindy', 'guindi'), 1);
    });

    test('distance against an empty string equals the other string\'s length', () {
      expect(FuzzyMatcher.levenshtein('', 'tambaram'), 8);
      expect(FuzzyMatcher.levenshtein('tambaram', ''), 8);
    });
  });

  group('FuzzyMatcher.bestMatch', () {
    test('returns null for an empty candidate list', () {
      expect(FuzzyMatcher.bestMatch('guindy', []), isNull);
    });

    test('finds the closest candidate, case-insensitively', () {
      final result = FuzzyMatcher.bestMatch('GUNDY', ['central', 'guindy', 'tambaram']);
      expect(result, isNotNull);
      expect(result!.match, 'guindy');
    });
  });

  group('DestinationResolver.resolve — exact alias matching', () {
    final resolver = DestinationResolver();

    test('an exact known alias resolves with high confidence and no confirmation needed', () {
      final result = resolver.resolve('guindy');
      expect(result.matchType, DestinationMatchType.exactAlias);
      expect(result.displayName, 'Guindy');
      expect(result.needsConfirmation, isFalse);
    });

    test('Tambaram resolves exactly', () {
      final result = resolver.resolve('tambaram');
      expect(result.matchType, DestinationMatchType.exactAlias);
      expect(result.displayName, 'Tambaram');
    });
  });

  group('DestinationResolver.resolve — fuzzy STT-mistake correction', () {
    final resolver = DestinationResolver();

    test('a common STT mishearing of Guindy still resolves to Guindy', () {
      // 'gundy' is one of the dictionary's own documented STT-mistake
      // aliases for Guindy, so this should be an EXACT alias match,
      // not merely a fuzzy one.
      final result = resolver.resolve('gundy');
      expect(result.displayName, 'Guindy');
    });

    test('a novel misspelling close to a known alias still resolves via fuzzy matching', () {
      // Not literally in the alias list, but close enough in edit
      // distance to 'tambaram'/'tambram'.
      final result = resolver.resolve('tambarm');
      expect(result.displayName, 'Tambaram');
      expect(result.matchType, anyOf(DestinationMatchType.exactAlias, DestinationMatchType.fuzzyAlias));
    });
  });

  group('DestinationResolver.resolve — code-switching', () {
    final resolver = DestinationResolver();

    test('Tamil-English code-switched phrasing strips the particle and still resolves', () {
      final result = resolver.resolve('guindy poganum');
      expect(result.displayName, 'Guindy');
    });

    test('a plain English carrier phrase is stripped before matching', () {
      final result = resolver.resolve('take me to central');
      expect(result.displayName, 'Chennai Central');
    });
  });

  group('DestinationResolver.resolve — no match', () {
    final resolver = DestinationResolver();

    test('an unrelated destination falls through as noMatch with low confidence', () {
      final result = resolver.resolve('some random unlisted place hjkxyz');
      expect(result.matchType, DestinationMatchType.noMatch);
      expect(result.confidence, lessThan(DestinationResolution.confirmationThreshold));
    });

    test('empty/whitespace-only input is handled without throwing', () {
      final result = resolver.resolve('   ');
      expect(result.matchType, DestinationMatchType.noMatch);
    });
  });

  group('DestinationResolver.collapseImmediateRepetition', () {
    // Regression coverage for the real, live-observed STT artifacts
    // this session: "Anna Nagar Anna" and "T Nagar T" — a self-repeat
    // at the end of the recognized text, most likely from a user
    // repeating themselves within the 3s destination-capture pauseFor
    // window. See the function's own doc comment for the algorithm
    // and why it must NOT collapse a genuinely different multi-word
    // destination that merely shares a leading word.
    test('a trailing one-word echo is dropped', () {
      expect(DestinationResolver.collapseImmediateRepetition('anna nagar anna'), 'anna nagar');
      expect(DestinationResolver.collapseImmediateRepetition('t nagar t'), 't nagar');
    });

    test('a full trailing multi-word repeat is dropped, preferring the largest match', () {
      expect(DestinationResolver.collapseImmediateRepetition('anna nagar anna nagar'), 'anna nagar');
    });

    test('a genuinely different destination that merely shares a leading word is left unchanged', () {
      expect(DestinationResolver.collapseImmediateRepetition('anna nagar anna salai'), 'anna nagar anna salai');
    });

    test('text with no repetition is left unchanged', () {
      expect(DestinationResolver.collapseImmediateRepetition('chennai central'), 'chennai central');
      expect(DestinationResolver.collapseImmediateRepetition('guindy'), 'guindy');
    });

    test('is case-insensitive when detecting the repeat but preserves original casing of the kept words', () {
      expect(DestinationResolver.collapseImmediateRepetition('Anna Nagar anna'), 'Anna Nagar');
    });

    test('resolve() benefits from the collapse — a garbled repeat still resolves cleanly', () {
      final resolver = DestinationResolver();
      final result = resolver.resolve('guindy guindy');
      expect(result.matchType, DestinationMatchType.exactAlias);
      expect(result.displayName, 'Guindy');
    });
  });
}
