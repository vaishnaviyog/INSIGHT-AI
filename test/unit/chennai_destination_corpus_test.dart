import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/voice_understanding/fuzzy_matcher.dart';

/// 50 REAL stop names sampled directly from the bundled
/// `assets/gtfs/chennai-unified-gtfs.zip` feed's `stops.txt` (fixed
/// random seed, not hand-picked/curated) — NOT invented for this
/// test. Deliberately spans neighbourhoods, colleges, hospitals,
/// railway stations, bus terminals, and junctions, per the explicit
/// "at least 50 destinations... include neighbourhoods, bus stops,
/// railway stations, landmarks, hospitals, colleges" requirement.
///
/// PURPOSE: proves the fuzzy-matching MECHANISM (the same
/// `FuzzyMatcher` the production destination resolver uses — see
/// `GtfsLocalityResolver` in `lib/services/gtfs/gtfs_locality_resolver.dart`)
/// generalizes across the WHOLE destination index, not just the
/// Guindy/Chromepet/Tambaram smoke-test names. This does NOT prove
/// real-world speech-recognition accuracy — it proves the STRING
/// matching a corrected/typo'd spelling would be resolved to the
/// correct canonical name once STT/normalization has already produced
/// some text, which is the actual scope of this algorithm.
const List<String> _realChennaiDestinationCorpus = [
  'Travellers Bangalow Or Pattunool Chatram',
  'Chinna Kandigai',
  'Alpha Medicals',
  'Kothaval Chavadi Corner',
  'Karishma Nagar Water Bridge',
  'Kalashetra Road',
  'Dog Cannal',
  'Central Bank Of India',
  'Vengal College',
  'Semmenchery Depot',
  'Besant Nagar',
  'T.V.K Nagar',
  'Oragadam Road Junction',
  'Ambedkar Statue Mettukuppam',
  'Ambatture Oragadam',
  'Booth S5 Pallavaram Police Station',
  'Kailankadai',
  'Kandanchavadi',
  'Rajakulipettai',
  'Thaiyur Koman Nagar',
  'Amarambedu Chatram',
  'Sivan Kovil Pozhichalur',
  'Indira Nagar 1st Avenue',
  'Vadakarai High School',
  'Wheels India Road Junction',
  'Semmancheri Bus Terminus',
  'Omayal Achi College',
  'Kakkavakkam',
  'Pattipulam Colony',
  'T R Studio',
  'Kovilanchery',
  "Adambakkam A.G.S.Officer'S Colony",
  'Erikkarai Rk Nursery',
  'Walajabad Railway Station',
  'Othikkadu',
  'Manthoppu Hr Sec School',
  'Kovilambakkam',
  'Ellaiamman Kovil',
  'Josiyar Street',
  'Manjampakkam Or Petrol Pump',
  'Cemetery Road',
  'Blue Factory',
  'Murugappa Polytechnic',
  'Budur Hospital',
  'Mettukadai Samathuvapuram',
  'Mary World Or Mgm',
  'Thamaraipakkam',
  'Kilven Road',
  'Anna Adarsh College',
  'Periyapalayam Bus Stand',
];

/// Deterministic, simple corruptions standing in for common STT/typo
/// patterns — NOT claiming to model real acoustic confusion, just
/// exercising the same edit-distance mechanism a real mishearing
/// would also produce (a small number of character-level changes).
String _dropOneInteriorCharacter(String s) {
  final mid = s.length ~/ 2;
  if (mid <= 0 || mid >= s.length) return s;
  return s.substring(0, mid) + s.substring(mid + 1);
}

String _removeSpaces(String s) => s.replaceAll(' ', '');

String _swapAdjacentInteriorChars(String s) {
  final mid = s.length ~/ 2;
  if (mid <= 0 || mid + 1 >= s.length) return s;
  final chars = s.split('');
  final tmp = chars[mid];
  chars[mid] = chars[mid + 1];
  chars[mid + 1] = tmp;
  return chars.join();
}

void main() {
  group('Real Chennai destination corpus — corpus integrity', () {
    test('the corpus has at least 50 unique real destination names', () {
      expect(_realChennaiDestinationCorpus.toSet().length, greaterThanOrEqualTo(50));
    });

    test('the corpus spans multiple destination categories, not just transit hubs', () {
      final lower = _realChennaiDestinationCorpus.map((s) => s.toLowerCase()).toList();
      expect(lower.any((s) => s.contains('college')), isTrue, reason: 'no college found');
      expect(lower.any((s) => s.contains('hospital')), isTrue, reason: 'no hospital found');
      expect(lower.any((s) => s.contains('school')), isTrue, reason: 'no school found');
      expect(lower.any((s) => s.contains('railway') || s.contains('station')), isTrue, reason: 'no railway/station found');
      expect(lower.any((s) => s.contains('nagar')), isTrue, reason: 'no neighbourhood (nagar) found');
      expect(lower.any((s) => s.contains('junction') || s.contains('road')), isTrue, reason: 'no junction/road found');
    });
  });

  group('FuzzyMatcher against the full real corpus — generalizes beyond the smoke-test names', () {
    test('a single interior character dropped from EVERY corpus entry still resolves correctly', () {
      int correct = 0;
      for (final name in _realChennaiDestinationCorpus) {
        final corrupted = _dropOneInteriorCharacter(name);
        if (corrupted == name) continue; // too short to corrupt meaningfully
        final result = FuzzyMatcher.bestMatch(corrupted, _realChennaiDestinationCorpus);
        if (result != null && result.match == name) correct++;
      }
      // Not claiming 100% — some short/similar-to-each-other names in
      // a real corpus can legitimately collide with a neighbour after
      // one character is removed. Require a strong majority.
      expect(correct / _realChennaiDestinationCorpus.length, greaterThan(0.85));
    });

    test('removing all spaces from a multi-word name still resolves correctly (spacing variation)', () {
      final multiWordNames = _realChennaiDestinationCorpus.where((n) => n.contains(' ')).toList();
      int correct = 0;
      for (final name in multiWordNames) {
        final corrupted = _removeSpaces(name);
        final result = FuzzyMatcher.bestMatch(corrupted, _realChennaiDestinationCorpus);
        if (result != null && result.match == name) correct++;
      }
      expect(correct / multiWordNames.length, greaterThan(0.85));
    });

    test('an adjacent-character swap (a common typo/STT-substitution shape) still resolves correctly', () {
      int correct = 0;
      int testable = 0;
      for (final name in _realChennaiDestinationCorpus) {
        final corrupted = _swapAdjacentInteriorChars(name);
        if (corrupted == name) continue;
        testable++;
        final result = FuzzyMatcher.bestMatch(corrupted, _realChennaiDestinationCorpus);
        if (result != null && result.match == name) correct++;
      }
      expect(correct / testable, greaterThan(0.85));
    });

    test('an exact match (no corruption) always resolves with distance 0', () {
      for (final name in _realChennaiDestinationCorpus.take(10)) {
        final result = FuzzyMatcher.bestMatch(name, _realChennaiDestinationCorpus);
        expect(result, isNotNull);
        expect(result!.match, name);
        expect(result.distance, 0);
      }
    });

    test('confidence signal (relative edit distance) is low for a close match, high for an unrelated query', () {
      const original = 'Besant Nagar';
      const closeQuery = 'Besant Ngar'; // one character dropped
      const unrelatedQuery = 'xyzzy plugh quux';

      final closeResult = FuzzyMatcher.bestMatch(closeQuery, _realChennaiDestinationCorpus);
      final unrelatedResult = FuzzyMatcher.bestMatch(unrelatedQuery, _realChennaiDestinationCorpus);

      expect(closeResult!.match, original);
      final closeRelative = closeResult.distance / closeQuery.length;
      final unrelatedRelative = unrelatedResult!.distance / unrelatedQuery.length;
      expect(closeRelative, lessThan(0.4)); // would pass the production 0.4 threshold
      expect(unrelatedRelative, greaterThan(closeRelative)); // meaningfully less confident
    });
  });

  group('Ambiguity — a genuinely ambiguous short query does not falsely resolve with high confidence', () {
    test('a very short, generic fragment matches SOMETHING but at low relative confidence', () {
      // "Road" is a fragment of many real entries in this corpus
      // (e.g. "Kalashetra Road", "Cemetery Road", "Kilven Road") —
      // this is inherently ambiguous, not a single correct answer.
      final result = FuzzyMatcher.bestMatch('Road', _realChennaiDestinationCorpus);
      expect(result, isNotNull);
      // Any legitimate match will still have a large relative
      // distance (the fragment is short relative to real full names),
      // which is exactly the signal a caller should use to require
      // confirmation rather than silently committing.
      final relative = result!.distance / result.match.length;
      expect(relative, greaterThan(0.3));
    });
  });
}
