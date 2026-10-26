import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/models/journey/journey_segment.dart';
import 'package:vaishnavi/repositories/gtfs_repository.dart';
import 'package:vaishnavi/services/gtfs/gtfs_database_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_locality_resolver.dart';
import 'package:vaishnavi/services/gtfs/gtfs_query_service.dart';
import 'package:vaishnavi/services/location_service.dart';

/// Regression coverage for two verified fixes from the "metro data
/// restoration + ranking fix" phase:
///
/// PART A — the 44 real CMRL metro station rows (stops.txt) and 3 CMRL
/// metro route rows (routes.txt) were corrected at the source-data
/// level (see assets/gtfs/chennai-unified-gtfs.zip and
/// GtfsDatabase.bundledGtfsDataVersion's "v2" bump) — they now import
/// successfully. `trips.txt`'s 96 CMRL rows were LEFT unfixed at that
/// time (a genuinely different, then-unproven column-reordering
/// problem, out of scope for that phase). Phase D proved the correct
/// column order by cross-referencing routes.txt/calendar.txt/
/// stop_times.txt (see GtfsDatabase.bundledGtfsDataVersion's "v3" bump
/// and assets/gtfs/README.md) and fixed it at the source-data level too
/// — metro STATIONS, ROUTES, and now TRIPS all import successfully, and
/// RAPTOR honestly considers metro trips like any other trip.
///
/// IMPORTANT — this does NOT mean metro journeys are now common or
/// "great": the same feed's `stop_times.txt` only records 2 stops per
/// metro trip (the line's two termini — see assets/gtfs/README.md
/// "Known remaining limitation") and its schedule values are
/// round-hour placeholders (2-6 hour headways, 1-8 hour "travel
/// times"), not a real timetable. Ranking correctly prefers realistic
/// buses over metro most of the time given those honest numbers — that
/// is working as intended, not a bug. Every assertion below reflects
/// this honestly; nothing here claims metro is a great practical
/// option today, only that it is structurally valid and honestly
/// considered.
///
/// PART B — `JourneyPlannerService._confidenceScore` no longer scores
/// the initial "waiting for your first bus" segment as transfer
/// slack — see `JourneySegment.isInitialWait`'s doc comment for the
/// full root-cause story (the Porur -> Velachery 472-minute journey).
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
  late GtfsDatabaseService rawDbService;
  late GtfsQueryService rawQueryService;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('insight_metro_ranking_fix_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    repo = GtfsRepository();
    await repo.initialize(
      locationService: LocationService(),
      autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
    );
    rawDbService = GtfsDatabaseService();
    await rawDbService.initialize();
    rawQueryService = GtfsQueryService(rawDbService);
  });

  tearDownAll(() async {
    await rawDbService.dispose();
    await repo.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Part A — CMRL metro station/route data now imports (real bundled feed)', () {
    test('all 44 real CMRL metro stops import successfully', () async {
      final rows = await rawDbService.database
          .rawQuery("SELECT stop_id, stop_name, stop_lat, stop_lon FROM stops WHERE stop_id LIKE 'CMRL%'");
      expect(rows.length, equals(44));
      final names = rows.map((r) => r['stop_name'] as String).toList();
      // A handful of real, recognizable Chennai Metro stations —
      // proves these are genuine imported records, not placeholders.
      for (final expectedName in ['Washermanpet', 'Koyambedu', 'St. Thomas Mount', 'Government Estate']) {
        expect(names, contains(expectedName), reason: 'expected real metro station "$expectedName" to be imported');
      }
    });

    test('all 3 CMRL metro routes import with correct route_type and agency_id', () async {
      final rows = await rawDbService.database.rawQuery(
          "SELECT route_id, route_short_name, route_long_name, route_type, agency_id FROM routes WHERE route_id LIKE 'CMRL%' ORDER BY route_id");
      expect(rows.length, equals(3));
      for (final row in rows) {
        expect(row['route_type'], equals(1), reason: '${row['route_id']}: route_type must be the real GTFS subway code (1)');
        expect(row['agency_id'], equals('CMRL'), reason: '${row['route_id']}: agency_id must match the real CMRL entry in agency.txt');
        expect(row['route_short_name'], isNotNull);
        expect((row['route_short_name'] as String).isNotEmpty, isTrue);
      }
      final shortNames = rows.map((r) => r['route_short_name'] as String).toSet();
      expect(shortNames, equals({'Blue Line', 'Green Line', 'Inter-Corridor'}));
    });

    test('Washermanpet (previously unresolvable — see prior audit) now resolves locally', () async {
      // AUDIT FIX CONFIRMATION: the network-wide routing audit found
      // "Washermanpet" failed destination resolution because its ONLY
      // GTFS record was a rejected CMRL stop row. Now that the stop
      // imports, resolution should succeed.
      final resolver = GtfsLocalityResolver(repo);
      final stop = await resolver.resolve('Washermanpet, Chennai') ?? await resolver.resolve('Washermanpet');
      expect(stop, isNotNull, reason: 'Washermanpet should now resolve now that its CMRL stop record imports');
      expect(stop!.stopName.toLowerCase(), contains('washermanpet'));
    });

    test('FIXED (Phase D): getNearestMetroStation now returns a real station — trips.txt is fixed', () async {
      // Phase D fix confirmation: trips.txt's 96 CMRL rows now import
      // (see assets/gtfs/README.md), so the full
      // stop->stop_times->trip->route chain this query requires is now
      // satisfiable. This test replaces the prior "HONEST LIMITATION"
      // assertion that this returned null — if this ever regresses to
      // null again, treat it as a real regression, not an expected gap.
      final nearestMetro =
          await rawQueryService.getNearestMetroStation(latitude: 13.081767, longitude: 80.27391); // near MGR Central
      expect(nearestMetro, isNotNull,
          reason: 'metro journey planning is now functional — trips.txt CMRL rows were corrected in Phase D');
      expect(nearestMetro!.stopId, startsWith('CMRL'));
    });

    test('FIXED (Phase D): metro trips exist — 96 real CMRL trips now import and are usable for journeys', () async {
      // AUDIT FIX (Southern Railway suburban-rail data merge): was
      // `route_type IN (1,2)` — this test's own name/reason strings
      // are explicitly about CMRL specifically, and route_type=2 now
      // means real (unrelated) SRR suburban-rail routes, not a second
      // flavor of metro. Scoped to route_type=1, which is exclusively
      // CMRL's 3 lines now that SRR's routes were correctly remapped
      // to route_type=2 at merge time.
      final metroTripRows = await rawDbService.database.rawQuery('''
        SELECT COUNT(*) AS c FROM trips t JOIN routes r ON r.route_id = t.route_id WHERE r.route_type = 1
      ''');
      expect(metroTripRows.first['c'], equals(96),
          reason: 'confirms all 96 CMRL trip rows from trips.txt now import and reference real metro routes');

      // Every metro trip must also have real stop_times rows (not just
      // a bare trip record) — otherwise it would be unusable by RAPTOR.
      final metroStopTimesRows = await rawDbService.database.rawQuery('''
        SELECT COUNT(DISTINCT t.trip_id) AS c FROM trips t
        JOIN routes r ON r.route_id = t.route_id
        JOIN stop_times st ON st.trip_id = t.trip_id
        WHERE r.route_type = 1
      ''');
      expect(metroStopTimesRows.first['c'], equals(96),
          reason: 'every metro trip must have real stop_times rows to be usable for journey planning');
    });

    test(
        'HONEST LIMITATION: metro stop_times only cover each line\'s 2 termini — no intermediate '
        'boarding across the other 42 real CMRL stations', () async {
      // This is a SEPARATE, deeper problem from the trips.txt column
      // bug fixed in Phase D — discovered only after that fix let
      // metro trips import at all. It is a genuine gap in this
      // bundled feed's stop_times.txt content, not a code bug, and
      // this app does not fabricate the missing intermediate
      // stop_times to paper over it (see assets/gtfs/README.md "Known
      // remaining limitation"). If this count ever changes, it means
      // the bundled feed changed — go read why, don't just update the
      // number.
      final rowsPerTrip = await rawDbService.database.rawQuery('''
        SELECT trip_id, COUNT(*) AS n FROM stop_times WHERE trip_id LIKE 'CMRL%' GROUP BY trip_id
      ''');
      expect(rowsPerTrip.length, equals(96));
      final distinctCounts = rowsPerTrip.map((r) => r['n'] as int).toSet();
      expect(distinctCounts, equals({2}),
          reason: 'every CMRL trip currently has exactly 2 stop_times rows (start + end of line) — if this '
              'increases, the feed now has real intermediate stop_times and journey planning should start '
              'finding genuinely useful multi-station metro connections automatically (no code change needed)');
    });
  });

  group('Part B — ranking no longer prefers a 472-minute journey with a ~7-hour initial wait', () {
    test('JourneySegment.isInitialWait defaults to false and is settable', () {
      const defaultSeg = JourneySegment(type: JourneySegmentType.transfer, description: 'x', duration: Duration.zero);
      expect(defaultSeg.isInitialWait, isFalse);
      const flaggedSeg =
          JourneySegment(type: JourneySegmentType.transfer, description: 'x', duration: Duration.zero, isInitialWait: true);
      expect(flaggedSeg.isInitialWait, isTrue);
    });

    test('Porur -> Velachery: the top-ranked journey is the practical one, not the multi-hour-wait direct one', () async {
      final resolver = GtfsLocalityResolver(repo);
      final origin = await resolver.resolve('Porur, Chennai');
      final dest = await resolver.resolve('Velachery, Chennai');
      expect(origin, isNotNull);
      expect(dest, isNotNull);

      final journeys = await repo.findJourneys(
        originLat: origin!.stopLat,
        originLon: origin.stopLon,
        destinationLat: dest!.stopLat,
        destinationLon: dest.stopLon,
        departureAfter: DateTime(2026, 8, 12, 9, 0), // same fixed reference time as the original finding
      );

      expect(journeys, isNotEmpty);
      final best = journeys.first;
      // AUDIT FIX VERIFICATION: previously the top-ranked journey here
      // was the 0-transfer, 472-minute (~7h52m) journey. The fix must
      // make the ranking prefer the practical alternative instead.
      expect(best.totalTravelTime.inMinutes, lessThan(120),
          reason: 'top-ranked journey must not be the ~7-hour-wait direct bus — expected the practical '
              '~40-minute 2-transfer alternative to rank first now');

      // The previously-winning long-wait journey must still be FOUND
      // (candidate generation is correct and untouched) — just not
      // ranked first anymore.
      final stillFound = journeys.any((j) => j.totalTravelTime.inMinutes > 400);
      expect(stillFound, isTrue,
          reason: 'the long-wait journey should still be a candidate (proves this is a ranking fix, not a '
              'candidate-generation change) — it should simply no longer be ranked first');
    });

    test('Chromepet -> Tambaram regression unaffected by the ranking fix', () async {
      final resolver = GtfsLocalityResolver(repo);
      final dest = await resolver.resolve('Tambaram, Chennai');
      expect(dest, isNotNull);
      final journeys = await repo.findJourneys(
        originLat: 12.943488,
        originLon: 80.1429569,
        destinationLat: dest!.stopLat,
        destinationLon: dest.stopLon,
        departureAfter: DateTime(2026, 8, 12, 9, 0),
      );
      expect(journeys, isNotEmpty);
      final minTransfers = journeys.map((j) => j.transferCount).reduce((a, b) => a < b ? a : b);
      expect(minTransfers, lessThanOrEqualTo(3),
          reason: 'must remain far below the ORIGINAL 4-5 transfer geographic detour this regression guards against');
    });
  });

  group('Part C — destination-stop selection accounts for the final walk, not just raw transit arrival (AUDIT FIX)',
      () {
    test(
        'REGRESSION: Chromepet -> "Tambaram West" no longer detours through an unnecessary ~800m walk from a stop '
        'the bus was already about to reach', () async {
      // Reproduced live, on a real device, from the user's own "is the
      // transit it is showing right?" question. On that live run, the
      // app boarded bus MAA1 R (route 24034) and alighted at Kadaperi to
      // walk the last ~800m, even though — confirmed directly against
      // the bundled feed (assets/gtfs/chennai-unified-gtfs.zip) — EVERY
      // one of that route's 62 trips shares one identical stop pattern
      // that continues from Kadaperi (6718, stop_sequence 9) to
      // Tambaram West Bus Stand itself (10972, stop_sequence 10) just 6
      // real scheduled minutes later, on the SAME bus. The old
      // destination-stop selection in `JourneyPlannerService.findJourneys`
      // picked whichever nearby stop the network reached SOONEST by raw
      // transit-arrival time, with no regard for how far that stop still
      // was from the actual destination coordinate — so it always chose
      // Kadaperi (reached first) and appended an ~11-minute walk, instead
      // of considering that riding a few minutes further would finish
      // the trip with no walk at all. See journey_planner_service.dart's
      // `bestProjectedFinalArrival` fix.
      //
      // This test doesn't pin down a specific route number — a
      // DIFFERENT, faster real route (bus 91) turns out to beat MAA1 R
      // entirely at this time of day, which is itself correct RAPTOR
      // behavior (always prefer the objectively fastest option). What
      // it does verify is the general property the fix establishes:
      // total walking stays small (no revival of the ~800m detour,
      // under whichever route is actually chosen), because stop
      // selection now accounts for the walk still needed afterward, not
      // just raw transit-arrival speed.
      final resolver = GtfsLocalityResolver(repo);
      // The real GPS position from the on-device run that first
      // surfaced this bug (near Chromepet) — required for the resolver
      // to pick "Tambaram West Bus Stand" over the unrelated same-
      // length "Tambaram West" ~1.3km away (see the GPS-vs-length-
      // closeness AUDIT FIX in gtfs_locality_resolver_test.dart).
      final position = Position(
        latitude: 12.9438529,
        longitude: 80.1427218,
        timestamp: DateTime(2026, 8, 12, 9, 0),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
      );
      final destStop = await resolver.resolve('Tambaram West', currentPosition: position);
      expect(destStop, isNotNull);
      expect(destStop!.stopName, 'Tambaram West Bus Stand');

      final journeys = await repo.findJourneys(
        originLat: 12.9438529,
        originLon: 80.1427218,
        destinationLat: destStop.stopLat,
        destinationLon: destStop.stopLon,
        departureAfter: DateTime(2026, 8, 12, 11, 29), // a Wednesday — matches the real on-device run's time of day
      );

      expect(journeys, isNotEmpty);
      final best = journeys.first;

      // The live-device buggy run produced ~1593m of total walking (an
      // ~711m initial walk to the boarding stop PLUS an unnecessary
      // ~800m mid-journey walk from an early-alighted stop to the
      // destination). The fixed selection keeps total walking to just
      // the legitimate initial-walk-to-stop distance (~750m at this
      // origin/destination pair) — comfortably under 900m — with no
      // revival of an ~800m avoidable detour.
      expect(best.totalWalkingDistanceMeters, lessThan(900),
          reason: 'must not include an unnecessary ~800m mid-journey walk from an early-alighted stop — the old '
              'raw-arrival-only stop selection produced exactly that on the real device');

      // At most one non-vehicle "transfer": real bundled feeds
      // sometimes register the same physical bus stand as more than one
      // stop_id (separate boarding bays, ~tens of meters apart, sharing
      // one public name) — walking between those is legitimate and
      // short, not a symptom of the bug this test guards against. What
      // matters is that it stays a short walk, not a real second
      // vehicle boarding.
      expect(best.transferCount, lessThanOrEqualTo(1),
          reason: 'at most one short same-stand walk is acceptable; a real second vehicle boarding would mean the '
              'destination-stop selection picked something far from the actual destination again');
    });
  });

  group('Part D — "tight connection" alternatives are surfaced but never outrank the safe answer (AUDIT ADD)', () {
    test(
        'REGRESSION: a genuinely faster, single-bus alternative from the NEAREST stop (Kumaran Kundram, ~217m) is '
        'offered as a secondary option, without displacing the safe Chromepet Mit Gate route from first place',
        () async {
      // Reproduced live, on a real device: from a real position, the
      // NEAREST stop (Kumaran Kundram) has bus M18G running straight to
      // Tambaram West Bus Stand — genuinely faster and less walking than
      // the app's actual (safe) answer, which instead walks farther to
      // Chromepet Mit Gate for bus 91. M18G only runs HOURLY, and the
      // standard 120s safety buffer meant the real walking time to
      // Kumaran Kundram landed too close to that specific departure for
      // the safe pass to ever consider it — so the faster option was
      // previously discarded entirely rather than offered with a
      // warning. See `JourneyPlannerService`'s "tight connection" pass
      // and `Journey.hasTightConnection`.
      final resolver = GtfsLocalityResolver(repo);
      final destStop = await resolver.resolve('Tambaram West Bus Stand');
      expect(destStop, isNotNull);

      final journeys = await repo.findJourneys(
        originLat: 12.9438144,
        originLon: 80.1426996,
        destinationLat: destStop!.stopLat,
        destinationLon: destStop.stopLon,
        departureAfter: DateTime(2026, 9, 8, 17, 30),
        maxTransfers: 4,
      );

      expect(journeys, isNotEmpty);

      // The FIRST (top-ranked) journey must always be a safe one — the
      // whole point of this fix is that a faster tight-connection
      // alternative is offered ALONGSIDE the safe answer, never in
      // place of it. Every journey after the first non-tight one must
      // also never be tight-connection-before-safe (safe candidates are
      // ranked and placed as a contiguous block first — see
      // `findJourneys`'s `rankedSafe`/`rankedTight` split).
      expect(journeys.first.hasTightConnection, isFalse,
          reason: 'a tight-connection journey must never rank first, regardless of how much faster it is — the '
              'safe answer must always be presented as the primary option');
      var seenTight = false;
      for (final j in journeys) {
        if (j.hasTightConnection) {
          seenTight = true;
        } else {
          expect(seenTight, isFalse,
              reason: 'a safe journey appeared AFTER a tight-connection one — safe candidates must always be '
                  'ranked as a contiguous block before any tight-connection alternative');
        }
      }

      // A genuine tight-connection alternative should now be SURFACED
      // for this real, borderline-timing scenario, not silently
      // discarded — confirming the fix actually works, not just that
      // it's harmless. Deliberately NOT pinned to a specific route
      // number: which exact bus is fastest is legitimately schedule-
      // and departure-time-sensitive (this same real position finds a
      // completely different, even better SAFE answer at a slightly
      // different departure time — see the investigation this test
      // documents). What must hold regardless is that when a tight
      // alternative exists, it's a genuinely different, meaningfully
      // faster option — not noise.
      final tightAlternatives = journeys.where((j) => j.hasTightConnection).toList();
      expect(tightAlternatives, isNotEmpty,
          reason: 'a faster alternative requiring a tighter-than-usual connection should now be surfaced instead '
              'of being silently discarded — this exact scenario (a real device run) previously found only the '
              'single safe answer');
      expect(tightAlternatives.first.totalTravelTime, lessThan(journeys.first.totalTravelTime),
          reason: 'a surfaced tight-connection alternative must be a genuinely faster option, not just a '
              'differently-risky route with no real benefit');
    });
  });
}
