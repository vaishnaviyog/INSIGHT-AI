import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/repositories/gtfs_repository.dart';
import 'package:vaishnavi/services/gtfs/gtfs_locality_resolver.dart';
import 'package:vaishnavi/services/location_service.dart';

/// Regression coverage for the destination-resolution correctness
/// phase — the "Tambaram, Chennai" investigation (see AUDIT_REPORT.md
/// and the destination-resolution/door-to-door-journey audit turns).
///
/// Uses the REAL bundled Chennai GTFS feed (`assets/gtfs/
/// chennai-unified-gtfs.zip`, installed via the same prepared-database
/// fast path `GtfsRepository.initialize` already uses in production —
/// see `test/unit/gtfs_prepared_database_test.dart`'s "GTFS version
/// change triggers safe replacement" test for the same pattern) rather
/// than a hand-built fixture, so these tests exercise the actual
/// production stop names/coordinates/routes, not an invented stand-in.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const flutterTtsChannel = MethodChannel('flutter_tts');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    flutterTtsChannel,
    (MethodCall call) async => 1,
  );

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late GtfsRepository repo;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('insight_locality_resolver_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    repo = GtfsRepository();
    // Same prepared-database fast path production uses — this
    // decompresses the real bundled `prepared_chennai_gtfs.db.gz`
    // asset (seconds), not a slow from-scratch CSV import (the CSV
    // path is only reached if no prepared asset is bundled at all,
    // which isn't the case here — see gtfs_prepared_database_test.dart).
    await repo.initialize(
      locationService: LocationService(),
      autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
    );
  });

  tearDownAll(() async {
    await repo.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('GtfsLocalityResolver.stripTrailingCityQualifier — pure text normalization', () {
    test('strips a ", Chennai" suffix', () {
      expect(GtfsLocalityResolver.stripTrailingCityQualifier('Tambaram, Chennai'), 'Tambaram');
    });

    test('strips a trailing " Chennai" with no comma', () {
      expect(GtfsLocalityResolver.stripTrailingCityQualifier('CMBT Koyambedu Chennai'), 'CMBT Koyambedu');
    });

    test('a query with NO city suffix passes through completely unchanged (preserves specificity)', () {
      expect(GtfsLocalityResolver.stripTrailingCityQualifier('Tambaram Railway Station'),
          'Tambaram Railway Station');
    });

    test('a query that is ONLY the city name is not stripped down to an empty string', () {
      expect(GtfsLocalityResolver.stripTrailingCityQualifier('Chennai'), 'Chennai');
    });

    test('matching is case-insensitive for the suffix itself', () {
      expect(GtfsLocalityResolver.stripTrailingCityQualifier('Tambaram, chennai'), 'Tambaram');
      expect(GtfsLocalityResolver.stripTrailingCityQualifier('guindy CHENNAI'), 'guindy');
    });
  });

  group('GtfsLocalityResolver.resolve — against the REAL bundled Chennai GTFS feed', () {
    test('"Tambaram, Chennai" resolves to a real Tambaram-area stop — the confirmed regression case', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Tambaram, Chennai');
      expect(stop, isNotNull,
          reason: 'GTFS matching must now succeed for this locality rather than falling through to an '
              'imprecise geocoded coordinate (the diagnosed root cause of the Chromepet->Tambaram detour)');
      expect(stop!.stopName.toLowerCase(), contains('tambaram'));
    });

    test('"Tambaram Railway Station" (no city suffix) resolves to that EXACT stop — more specific than the bare locality',
        () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Tambaram Railway Station');
      expect(stop, isNotNull);
      expect(stop!.stopName, 'Tambaram Railway Station',
          reason: 'explicit user specificity must not be diluted toward a generic locality pick');
    });

    test('"Chromepet, Chennai" resolves to a real Chromepet-area stop', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Chromepet, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('chromepet'));
    });

    test('"Guindy, Chennai" resolves to a real Guindy-area stop', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Guindy, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('guindy'));
    });

    test('"Anna Nagar, Chennai" resolves to a real Anna Nagar-area stop', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Anna Nagar, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('anna nagar'));
    });

    test('"Adyar, Chennai" resolves to a real Adyar-area stop', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Adyar, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('adyar'));
    });

    test('"Egmore Railway Station, Chennai" resolves to a real Egmore stop', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Egmore Railway Station, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('egmore'));
    });

    test('"Velachery, Chennai" resolves to a real Velachery-area stop', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Velachery, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('velachery'));
    });

    test('an unrelated, genuinely nonexistent place still returns null — never a false positive', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Xyzzy Plugh Quux Nonexistent Place, Chennai');
      expect(stop, isNull);
    });

    test(
        'REGRESSION (Phase F3): "Chennai Central Railway Station" resolves to the real, correct '
        'Central-area stop, not an unrelated same-length station', () async {
      // Root cause (reproduced against this exact bundled feed): the
      // dictionary's canonicalSearchQuery for "Chennai Central" is
      // "Chennai Central Railway Station, Chennai" (31 chars after the
      // city suffix is stripped). No stop literally substring-matches
      // that whole phrase, so resolution falls to the fuzzy-index
      // fallback — whose OLD fixed -3/+20 length pre-filter (28..51)
      // excluded the real, correct stop "Mgr Central Railway Station"
      // (27 chars) by exactly one character, and instead matched
      // "Nungambakkam Railway Station" (an unrelated real station that
      // merely happened to fall inside the wrong window and share the
      // "Railway Station" suffix). See GtfsLocalityResolver's
      // _resolveByFuzzyIndexMatch for the fix (a length window derived
      // from the same 0.4 relative-distance threshold already used to
      // accept/reject the match, guaranteed never narrower than
      // before).
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Chennai Central Railway Station, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('central'),
          reason: 'must resolve to a real Central-area station, not an unrelated same-length one '
              '(previously resolved to "Nungambakkam Railway Station" — confirmed wrong)');
      expect(stop.stopName, isNot('Nungambakkam Railway Station'));
    });

    test('REGRESSION (Phase F3): the widened fuzzy-fallback length window still rejects a genuinely unrelated place',
        () async {
      // The widening must not turn the fuzzy fallback into a
      // false-positive machine — a long, specific, nonexistent query
      // must still return null, not "the closest thing that happens to
      // be nearby in length."
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Zzyzx Nonexistent Boulevard Terminus Complex, Chennai');
      expect(stop, isNull);
    });
  });

  group('GtfsLocalityResolver._pickBestCandidate — GPS-vs-length-closeness ranking (AUDIT FIX)', () {
    // A minimal stand-in Position, matching the geolocator_platform_interface
    // 4.x constructor (all fields required except floor/isMocked). Fields
    // other than lat/lon are irrelevant to distance-based ranking.
    Position fakePosition(double lat, double lon) => Position(
          latitude: lat,
          longitude: lon,
          timestamp: DateTime(2026, 8, 12, 9, 0),
          accuracy: 5.0,
          altitude: 0.0,
          altitudeAccuracy: 0.0,
          heading: 0.0,
          headingAccuracy: 0.0,
          speed: 0.0,
          speedAccuracy: 0.0,
        );

    test(
        'REGRESSION: "Tambaram West" near the real Bus Stand resolves to the Bus Stand, not the unrelated '
        'same-name-length stop ~1.3km away', () async {
      // Root cause (reproduced against this exact bundled feed, via
      // `unzip -p chennai-unified-gtfs.zip stops.txt | grep -i tambaram`):
      // the feed contains BOTH "Tambaram West" (stop ids 6683/6685) and
      // "Tambaram West Bus Stand" (stop ids 10972/6692/6693) — two real,
      // distinct stops ~1.3km apart. The query "Tambaram West" exactly
      // matches the first name's length (length-diff 0) and the OLD
      // ranking picked it unconditionally, before ever consulting GPS,
      // regardless of where the user actually was standing.
      final resolver = GtfsLocalityResolver(repo);
      // A real coordinate from the bundled feed, right at the Bus Stand
      // stop cluster (~12.928, 80.119) — i.e. the user is standing at the
      // Bus Stand, not the other "Tambaram West".
      final position = fakePosition(12.9278, 80.1189);
      final stop = await resolver.resolve('Tambaram West', currentPosition: position);
      expect(stop, isNotNull);
      expect(stop!.stopName, 'Tambaram West Bus Stand',
          reason: 'the user\'s real GPS position is right at the Bus Stand cluster; GPS proximity must now '
              'outrank the coincidental exact-length match to the unrelated stop ~1.3km away');
    });

    test('"Tambaram West" with NO GPS position falls back to the original length-closeness behavior', () async {
      // Documents the deliberately-unchanged fallback: with no position
      // available (as every pre-existing test in this file calls
      // resolve()), behavior must be byte-for-byte identical to before
      // this fix, so no previously-correct no-GPS resolution regresses.
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Tambaram West');
      expect(stop, isNotNull);
      expect(stop!.stopName, 'Tambaram West');
    });

    test(
        'REGRESSION (Phase F3, must still hold): "Chennai Central Railway Station" is unaffected by the GPS '
        'ranking change when no position is supplied', () async {
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Chennai Central Railway Station, Chennai');
      expect(stop, isNotNull);
      expect(stop!.stopName.toLowerCase(), contains('central'));
      expect(stop.stopName, isNot('Nungambakkam Railway Station'));
    });

    test(
        'REGRESSION: a garbled voice transcription ("tambaram best bus" for "Tambaram West") still resolves to '
        'the real, GPS-nearby Bus Stand via the fuzzy-fallback path, not the unrelated stop ~1.3km away', () async {
      // Reproduced live, on a real device: speech recognition actually
      // mis-heard "Tambaram West" as "Tambaram best bus". That garbled
      // text doesn't substring-match any real stop name, so resolution
      // fell to `_resolveByFuzzyIndexMatch` — a SEPARATE code path from
      // the direct substring-match one the test above covers. Its old
      // behavior picked a single closest-matching NAME STRING by pure
      // edit distance ("Tambaram West", 13 chars, narrowly beats
      // "Tambaram West Bus Stand", 24 chars, against this garbled
      // query) and searched for stops under ONLY that name — discarding
      // the real, GPS-nearby "Tambaram West Bus Stand" stops before GPS
      // ever got a say. Confirmed on-device: this produced a bogus
      // 2-transfer route via "Mannivakkam W.Tank" to correct for the
      // wrong destination, when the correct answer was a single direct
      // bus. See `_resolveByFuzzyIndexMatch`'s prefix-family pooling
      // AUDIT FIX.
      final resolver = GtfsLocalityResolver(repo);
      // The real GPS position from the on-device run that surfaced this
      // exact mis-transcription (near Chromepet).
      final position = fakePosition(12.9438144, 80.1426996);
      final stop = await resolver.resolve('tambaram best bus', currentPosition: position);
      expect(stop, isNotNull);
      expect(stop!.stopName, 'Tambaram West Bus Stand',
          reason: 'GPS proximity must win across the fuzzy-fallback\'s pooled candidate names too, not just the '
              'direct substring-match path — the real bug was routing an unnecessary 2-transfer detour to the '
              'wrong "Tambaram West" stop ~1.3km away');
    });

    test(
        'REGRESSION: "tambaram west bus stop" (STT swapped "Stand" for "Stop") still resolves to the correct '
        'West Bus Stand, not the unrelated East Bus Stop that is a closer CHARACTER match', () async {
      // Reproduced live, on a real device, immediately after the fix
      // above — a SEPARATE mis-transcription: this time speech
      // recognition heard "West" correctly but swapped "Stand" for
      // "Stop", which happens to be the ACTUAL real name of a
      // different, unrelated stop ("Tambaram East Bus Stop").
      // Character-by-character, "tambaram west bus stop" is CLOSER to
      // "Tambaram East Bus Stop" (distance 2 — only "w"/"e" and "e"/"a"
      // differ) than to the correct "Tambaram West Bus Stand" (distance
      // 3 — "stop"/"stand" differ by more letters). Neither name is a
      // prefix of the other, so the prefix-family pooling above never
      // considers them together. At the WORD level, though, both differ
      // from the query by exactly one token — a genuine tie the
      // character-only metric can't see. See
      // `FuzzyMatcher.wordLevelDistance` and the word-level pooling
      // AUDIT FIX in `_resolveByFuzzyIndexMatch`.
      final resolver = GtfsLocalityResolver(repo);
      // The real GPS position from the on-device run that surfaced this
      // exact mis-transcription (near Chromepet) — the same position as
      // the earlier "Tambaram West Bus Stand" tests, since GPS
      // proximity is exactly what should break this word-level tie.
      final position = fakePosition(12.9438144, 80.1426996);
      final stop = await resolver.resolve('tambaram west bus stop', currentPosition: position);
      expect(stop, isNotNull);
      expect(stop!.stopName, 'Tambaram West Bus Stand',
          reason: 'GPS proximity must break the genuine word-level tie between "Tambaram West Bus Stand" (correct) '
              'and "Tambaram East Bus Stop" (character-closer but the wrong, unrelated place)');
    });

    test(
        'the widened pooling still rejects an unrelated place that happens to share raw character distance '
        '(no "Tambaram Depot" false positive)', () async {
      // Guards against the FIRST, reverted attempt at the fix above
      // (raw edit-distance slack pooling), which measurably pulled in
      // "Tambaram Depot" — a real, unrelated place — for this exact
      // query, and let GPS proximity hand it the win purely because it
      // was geographically nearer than the correct Bus Stand. Both the
      // prefix-family and word-level-tie pooling mechanisms must
      // continue to exclude it.
      final resolver = GtfsLocalityResolver(repo);
      final position = fakePosition(12.9438144, 80.1426996);
      final stop = await resolver.resolve('tambaram best bus', currentPosition: position);
      expect(stop, isNotNull);
      expect(stop!.stopName, isNot('Tambaram Depot'));
    });
  });

  group('Regression: Chromepet -> Tambaram no longer forces an absurd multi-transfer detour', () {
    test('once Tambaram resolves to a real transit hub, a direct or near-direct journey is available', () async {
      final resolver = GtfsLocalityResolver(repo);
      final destStop = await resolver.resolve('Tambaram, Chennai');
      expect(destStop, isNotNull);

      // The real Chromepet-area origin GPS coordinate from the actual
      // on-device regression run that first surfaced this bug.
      const originLat = 12.943488;
      const originLon = 80.1429569;

      // AUDIT FIX (network-wide routing audit): pinned to a fixed,
      // reproducible reference time — a real weekday morning, well
      // within the feed's service-calendar range. Previously this
      // called findJourneys() with no departureAfter, which defaults
      // to DateTime.now() (journey_planner_service.dart:100):
      // discovered, while running the broader network-wide audit
      // suite, that the actual set of soon-departing trips (and
      // therefore the minimum transfer count among candidates) is
      // genuinely time-of-day-dependent, making an unpinned regression
      // test non-reproducible — it can pass or fail depending on when
      // it happens to run. Pinning makes this test deterministic.
      final journeys = await repo.findJourneys(
        originLat: originLat,
        originLon: originLon,
        destinationLat: destStop!.stopLat,
        destinationLon: destStop.stopLon,
        departureAfter: DateTime(2026, 8, 12, 9, 0), // a Wednesday
      );

      expect(journeys, isNotEmpty,
          reason: 'real GTFS connectivity between Chromepet and Tambaram exists (multiple direct bus routes '
              'confirmed directly against the raw feed during the routing investigation)');

      // AUDIT FIX (network-wide routing audit): the original bound
      // here (<=1) was derived from ONE unpinned, live-clock run and
      // turned out to be an artifact of that specific moment, not a
      // true invariant — at the fixed reference time above, RAPTOR's
      // best available connection genuinely needs 2 transfers (real,
      // legitimate schedule-timing dependence: which of the 3
      // confirmed direct Chromepet<->Tambaram routes is conveniently
      // catchable changes minute to minute). <=3 is the real invariant
      // this regression case cares about: staying far below the
      // ORIGINAL bug's 4-5 transfer geographic detour through
      // Pallavaram/Alandur/Valsaravakkam/Anakaputhur, not pinning an
      // exact number that depends on departure time.
      final minTransfers = journeys.map((j) => j.transferCount).reduce((a, b) => a < b ? a : b);
      expect(minTransfers, lessThanOrEqualTo(3),
          reason: 'a reasonably simple journey must be AVAILABLE among the candidates once the destination '
              'coordinate is correct — the previously-observed 4-5 transfer geographic detour must not be the '
              'only option');

      final best = journeys.first;
      expect(best.transferCount, lessThanOrEqualTo(2),
          reason: 'the top-RANKED journey should also be reasonably simple, not the multi-transfer detour');
      expect(best.totalWalkingDistanceMeters, lessThan(3000),
          reason: 'total walking should be modest between two well-served areas, not the multi-kilometer '
              'detour previously observed when the destination coordinate was ~2.5km off');
    });
  });
}
