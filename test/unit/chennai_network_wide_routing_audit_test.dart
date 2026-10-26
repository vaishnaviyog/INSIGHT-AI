import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/models/gtfs/stop.dart';
import 'package:vaishnavi/repositories/gtfs_repository.dart';
import 'package:vaishnavi/services/gtfs/gtfs_database_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_locality_resolver.dart';
import 'package:vaishnavi/services/gtfs/gtfs_query_service.dart';
import 'package:vaishnavi/services/location_service.dart';

import '../support/chennai_locality_directory.dart';

/// PHASE 2 — network-wide Chennai routing correctness audit.
///
/// SCOPE: this is deliberately an AUDIT file, not a narrow regression
/// test for one destination — every check here runs against the REAL
/// bundled Chennai GTFS feed (same prepared-database fast path
/// production uses), sampling broadly across the network rather than
/// a hand-picked list, per the explicit "the routing NETWORK works,
/// not just a few journeys" requirement. Findings that are informative
/// but not yet a settled pass/fail bar (detour ratios, transfer
/// quality, ranking behavior) are PRINTED as statistics/examples
/// rather than asserted against an invented threshold — per the
/// explicit instruction not to hard-code an arbitrary cutoff. Findings
/// that ARE unambiguous correctness invariants (chronological
/// ordering, no negative durations, valid stop references, no
/// same-stop transit "journeys") are hard `expect()` assertions.
///
/// PRODUCTION CODE IS NOT MODIFIED BY THIS FILE — RAPTOR, footpath
/// relaxation, journey ranking, the GTFS importer, and the prepared
/// pattern schema are exercised exactly as they exist in production.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

/// A fixed, reproducible reference time (a real weekday morning, well
/// within the feed's service-calendar range) — every journey search
/// in this file is pinned to this instant rather than DateTime.now(),
/// so results (which trips are "soon", and therefore transfer counts/
/// rankings) are deterministic across runs. See gtfs_locality_resolver_test.dart's
/// doc comment on the SAME fix for why this matters: the set of
/// soon-departing trips is genuinely time-of-day-dependent, and this
/// file's whole purpose is to produce reproducible regression evidence.
final DateTime _fixedReferenceTime = DateTime(2026, 8, 12, 9, 0); // a Wednesday

double _haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final dLat = (lat2 - lat1) * (pi / 180.0);
  final dLon = (lon2 - lon1) * (pi / 180.0);
  final a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * pi / 180.0) * cos(lat2 * pi / 180.0) * sin(dLon / 2) * sin(dLon / 2);
  return r * 2 * atan2(sqrt(a), sqrt(1 - a));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late GtfsRepository repo;
  late GtfsDatabaseService rawDbService; // separate handle onto the SAME already-populated db file, for raw SQL audits
  late GtfsQueryService rawQueryService;
  late List<GtfsStop> allRealStops;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('insight_network_audit_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);

    repo = GtfsRepository();
    await repo.initialize(
      locationService: LocationService(),
      autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
    );

    // A second handle onto the SAME on-disk database (same fake
    // path-provider directory) purely for read-only raw-SQL audits
    // (route_type counts, table row counts) that GtfsQueryService/
    // GtfsRepository don't already expose — never writes anything.
    rawDbService = GtfsDatabaseService();
    await rawDbService.initialize();
    rawQueryService = GtfsQueryService(rawDbService);
    allRealStops = await rawQueryService.getAllStops();
  });

  tearDownAll(() async {
    await rawDbService.dispose();
    await repo.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('Phase 11 — Prepared database integrity vs. raw source feed', () {
    test('stops/routes/trips/stop_times row counts, classified against the raw feed', () async {
      final zipBytes = await rootBundle.load('assets/gtfs/chennai-unified-gtfs.zip');
      final archive = ZipDecoder().decodeBytes(zipBytes.buffer.asUint8List());

      int rawDataRowCount(String fileName) {
        final file = archive.files.firstWhere((f) => f.name == fileName);
        final text = utf8.decode(file.content as List<int>);
        final lines = const LineSplitter().convert(text).where((l) => l.trim().isNotEmpty).toList();
        return lines.length - 1; // minus header
      }

      Future<int> preparedCount(String table) async {
        final rows = await rawDbService.database.rawQuery('SELECT COUNT(*) AS c FROM $table');
        return rows.first['c'] as int;
      }

      final rawStops = rawDataRowCount('stops.txt');
      final rawRoutes = rawDataRowCount('routes.txt');
      final rawTrips = rawDataRowCount('trips.txt');
      final rawStopTimes = rawDataRowCount('stop_times.txt');

      final preparedStops = await preparedCount('stops');
      final preparedRoutes = await preparedCount('routes');
      final preparedTrips = await preparedCount('trips');
      final preparedStopTimes = await preparedCount('stop_times');

      // ignore: avoid_print
      print('[DB INTEGRITY] stops:      raw=$rawStops  prepared=$preparedStops  delta=${rawStops - preparedStops} '
          '(FIXED this phase — the 44 CMRL_* metro station rows now import; see metro data-restoration report)');
      // ignore: avoid_print
      print('[DB INTEGRITY] routes:     raw=$rawRoutes  prepared=$preparedRoutes  delta=${rawRoutes - preparedRoutes} '
          '(FIXED this phase — the 3 CMRL routes now import)');
      // ignore: avoid_print
      print('[DB INTEGRITY] trips:      raw=$rawTrips  prepared=$preparedTrips  delta=${rawTrips - preparedTrips} '
          '(FIXED in Phase D — the 96 CMRL rows now import too; only the 6 unrelated leaked calendar.txt rows '
          'remain correctly rejected)');
      // ignore: avoid_print
      print('[DB INTEGRITY] stop_times: raw=$rawStopTimes  prepared=$preparedStopTimes  delta=${rawStopTimes - preparedStopTimes}');

      // Hard invariants: prepared counts must never EXCEED raw counts
      // (nothing fabricated), and stops/stop_times (which have no
      // known source-data defect) should import essentially 1:1.
      expect(preparedStops, lessThanOrEqualTo(rawStops));
      expect(preparedRoutes, lessThanOrEqualTo(rawRoutes));
      expect(preparedTrips, lessThanOrEqualTo(rawTrips));
      expect(preparedStopTimes, lessThanOrEqualTo(rawStopTimes));

      // AUDIT FIX: stops.txt's 44 CMRL rows and routes.txt's 3 CMRL
      // rows were corrected at the source in an earlier phase
      // (bundledGtfsDataVersion bumped to v2) — both import with ZERO
      // loss. trips.txt's 96 CMRL rows were fixed in Phase D
      // (bundledGtfsDataVersion bumped to v3, see assets/gtfs/README.md
      // for the proof of the correct column order) — only the 6
      // unrelated leaked-calendar.txt rows remain correctly rejected
      // (they are not CMRL data and have no provable correct
      // reinterpretation).
      expect(rawRoutes - preparedRoutes, equals(0), reason: 'routes.txt CMRL rows must now import with zero loss');
      expect(rawTrips - preparedTrips, equals(6),
          reason: 'trip loss must now match EXACTLY the 6 leaked calendar.txt rows — the 96 CMRL rows are fixed '
              'as of Phase D (bundledGtfsDataVersion v3)');
      expect(rawStops - preparedStops, equals(0), reason: 'stops.txt CMRL rows must now import with zero loss');
    });
  });

  group('Phase 9 — Metro coverage, verified programmatically against the live prepared database', () {
    test('metro ROUTES and TRIPS both now exist (Phase D fix)', () async {
      // AUDIT FIX (Southern Railway suburban-rail data merge): was
      // `route_type IN (1,2)` — harmless while this feed had no
      // route_type=2 data at all, but once real SRR suburban-rail
      // routes were merged in under the GTFS-correct route_type=2
      // ("Rail", distinct from 1="Subway/Metro"), this query started
      // counting 763 unrelated rail routes as "metro" too (3 -> 766).
      // This test's own stated purpose is CMRL metro specifically (see
      // the reason strings below) — scoped to route_type=1 only, which
      // is now exclusively CMRL's 3 real lines, matching what the test
      // actually claims to verify. See the companion rail-coverage
      // check just below for the new data's own verification.
      final routeRows = await rawDbService.database.rawQuery('SELECT COUNT(*) AS c FROM routes WHERE route_type = 1');
      final tripRows = await rawDbService.database.rawQuery('''
        SELECT COUNT(*) AS c FROM trips t JOIN routes r ON r.route_id = t.route_id WHERE r.route_type = 1
      ''');
      final metroRoutes = routeRows.first['c'] as int;
      final metroTrips = tripRows.first['c'] as int;
      // ignore: avoid_print
      print('[METRO] usable route_type=1 routes=$metroRoutes trips=$metroTrips '
          '(both now non-zero as of Phase D — metro trips are honestly considered by RAPTOR, though see '
          'assets/gtfs/README.md "Known remaining limitation" for why they rarely win the ranking)');
      expect(metroRoutes, equals(3), reason: 'the 3 CMRL routes (Blue Line, Green Line, Inter-Corridor) import');
      expect(metroTrips, equals(96),
          reason: 'all 96 CMRL trips now import (Phase D trips.txt fix) and participate in journey planning');
    });

    test('Southern Railway suburban-rail coverage, verified programmatically against the live prepared database',
        () async {
      final routeRows = await rawDbService.database.rawQuery('SELECT COUNT(*) AS c FROM routes WHERE route_type = 2');
      final tripRows = await rawDbService.database.rawQuery('''
        SELECT COUNT(*) AS c FROM trips t JOIN routes r ON r.route_id = t.route_id WHERE r.route_type = 2
      ''');
      final railRoutes = routeRows.first['c'] as int;
      final railTrips = tripRows.first['c'] as int;
      // ignore: avoid_print
      print('[RAIL] usable route_type=2 routes=$railRoutes trips=$railTrips');
      expect(railRoutes, equals(763),
          reason: 'all 763 Southern Railway suburban services (CUMTA source) import as real, distinct routes');
      expect(railTrips, equals(763), reason: 'SRR models one trip per service — 763 routes, 763 trips, 1:1');
    });
  });

  group('Phase 2 — Destination resolution: network-wide statistics', () {
    test('resolution outcome across every locality in the directory (N/Central/W/S Chennai)', () async {
      final resolver = GtfsLocalityResolver(repo);
      int exactOrFuzzyMatch = 0;
      int noMatch = 0;
      final failures = <String>[];

      for (final locality in ChennaiLocalityDirectory.all) {
        // Exercise BOTH the bare locality form and the geocoder-style
        // ", Chennai"-suffixed form (the shape every curated alias
        // actually produces) — both must resolve equally well, since
        // stripTrailingCityQualifier should make them equivalent.
        final bare = await resolver.resolve(locality);
        final suffixed = await resolver.resolve('$locality, Chennai');
        final resolved = bare ?? suffixed;
        if (resolved != null) {
          exactOrFuzzyMatch++;
        } else {
          noMatch++;
          failures.add(locality);
        }
      }

      final total = ChennaiLocalityDirectory.all.length;
      final successRate = exactOrFuzzyMatch / total;
      // ignore: avoid_print
      print('[DESTINATION RESOLUTION] $exactOrFuzzyMatch/$total resolved locally (${(successRate * 100).toStringAsFixed(1)}%), '
          '$noMatch fell through to geocoding: $failures');

      // A generous floor, not a demand for 100% — landmark-style
      // names whose real GTFS wording diverges entirely (documented
      // gap from the destination-resolution fix) are expected to
      // still need geocoding. This asserts the fix generalizes
      // broadly across the network, not just for Tambaram.
      expect(successRate, greaterThanOrEqualTo(0.7),
          reason: 'local GTFS resolution should succeed for a strong majority of real Chennai localities');
    });

    test('an explicit, more specific stop name resolves MORE specifically than its bare locality', () async {
      final resolver = GtfsLocalityResolver(repo);
      final bare = await resolver.resolve('Tambaram, Chennai');
      final specific = await resolver.resolve('Tambaram Railway Station');
      expect(bare, isNotNull);
      expect(specific, isNotNull);
      expect(specific!.stopName, 'Tambaram Railway Station');
      // The bare locality is allowed to pick a DIFFERENT (still real,
      // still Tambaram-area) stop than the explicit one — it must not
      // be forced to the same generic answer regardless of specificity.
      expect(bare!.stopName.toLowerCase(), contains('tambaram'));
    });
  });

  group('Phase 3 — Origin stop selection sanity (does not simply grab the mathematically nearest stop in isolation)', () {
    test('nearby-stop candidate sets at increasing radii are monotonically non-shrinking and geographically real', () async {
      // A real, populated area (around the Chromepet regression
      // origin) — not a hand-picked "friendly" coordinate.
      const lat = 12.943488, lon = 80.1429569;
      final radii = [50.0, 100.0, 200.0, 400.0, 800.0];
      var previousCount = 0;
      for (final radius in radii) {
        final nearby = await rawQueryService.getNearbyStops(latitude: lat, longitude: lon, radiusMeters: radius, limit: 100);
        // ignore: avoid_print
        print('[ORIGIN STOP SELECTION] radius=${radius}m candidates=${nearby.length}');
        expect(nearby.length, greaterThanOrEqualTo(previousCount), reason: 'a larger radius must never see FEWER candidate stops');
        for (final stop in nearby) {
          final d = _haversineMeters(lat, lon, stop.stopLat, stop.stopLon);
          expect(d, lessThanOrEqualTo(radius + 1), reason: '${stop.stopName} at ${d}m returned inside a ${radius}m query');
        }
        previousCount = nearby.length;
      }
      // NOTE ON "not simply the nearest stop": JourneyPlannerService
      // does not pre-filter to a single nearest stop at all — every
      // candidate within walkingRadiusMeters is fed to RAPTOR as an
      // independent multi-source seed (see journey_planner_service.dart:118-124,
      // 191-196), and the ACTUAL boarding stop used emerges from
      // whichever seed produces the best-ranked whole journey, not
      // from a pre-selection step. There is no separate "best origin
      // stop" heuristic to unit-test in isolation — its correctness is
      // covered by the journey-level assertions elsewhere in this file.
    });
  });

  group('Phase 4/5/8/15 — Randomized network-wide journey stress test (real GTFS data, fixed seed)', () {
    test('journeys generated across many random real stop pairs are ALWAYS internally consistent', () async {
      final rng = Random(20260809); // fixed seed — reproducible on failure
      // AUDIT SCALE-UP (real-device validation phase — "400 possible
      // transit tests" request): previously scaled down to 40 pairs
      // from the SAME peak-time cost concern noted below. Scaled back
      // up to the requested ~400 here, at the SAME realistic peak-time
      // reference (9am Wednesday, chosen for Phase-10-style
      // reproducibility) rather than switching to a cheaper off-peak
      // time just to make the number easier — a single real search
      // against this feed costs, empirically, anywhere from ~0.5s to
      // ~11s of actual RAPTOR wall time at this peak reference (see
      // Phase 17's measured peak-vs-off-peak baseline), so this run is
      // genuinely long (well over an hour in the worst case) — run in
      // the background with a generous timeout, not as a normal fast
      // CI check. 400 pairs is a real, non-cherry-picked, fixed-seed
      // random sample spanning the whole real network.
      const pairCount = 400;

      int pairsWithNoJourney = 0;
      int pairsWithJourney = 0;
      int totalJourneysValidated = 0;
      final transferCounts = <int>[];
      final walkingDistances = <double>[];
      final detourRatios = <double>[];
      final suspiciousTransfers = <String>[];

      for (int i = 0; i < pairCount; i++) {
        final origin = allRealStops[rng.nextInt(allRealStops.length)];
        final dest = allRealStops[rng.nextInt(allRealStops.length)];
        if (origin.stopId == dest.stopId) continue;

        final journeys = await repo.findJourneys(
          originLat: origin.stopLat,
          originLon: origin.stopLon,
          destinationLat: dest.stopLat,
          destinationLon: dest.stopLon,
          departureAfter: _fixedReferenceTime,
        );

        if (journeys.isEmpty) {
          pairsWithNoJourney++;
          continue; // "no journey available" is explicitly a VALID outcome — not asserted against
        }
        pairsWithJourney++;

        final straightLine = _haversineMeters(origin.stopLat, origin.stopLon, dest.stopLat, dest.stopLon);

        for (final journey in journeys) {
          totalJourneysValidated++;
          transferCounts.add(journey.transferCount);
          walkingDistances.add(journey.totalWalkingDistanceMeters);

          // --- HARD correctness invariants (unambiguous, always must hold) ---
          expect(journey.segments, isNotEmpty, reason: 'pair $i: a returned journey must have at least one segment');
          expect(journey.arrivalTime.isAfter(journey.departureTime) || journey.arrivalTime.isAtSameMomentAs(journey.departureTime),
              isTrue, reason: 'pair $i: journey arrival must not precede its own departure');

          DateTime? previousArrival;
          for (int s = 0; s < journey.segments.length; s++) {
            final seg = journey.segments[s];
            expect(seg.duration.inSeconds, greaterThanOrEqualTo(0), reason: 'pair $i segment $s: negative duration');
            if (seg.departureTime != null && seg.arrivalTime != null) {
              expect(
                seg.arrivalTime!.isAfter(seg.departureTime!) || seg.arrivalTime!.isAtSameMomentAs(seg.departureTime!),
                isTrue,
                reason: 'pair $i segment $s (${seg.type}): arrival before its own departure',
              );
            }
            if (previousArrival != null && seg.departureTime != null) {
              expect(
                seg.departureTime!.isAfter(previousArrival) || seg.departureTime!.isAtSameMomentAs(previousArrival),
                isTrue,
                reason: 'pair $i segment $s (${seg.type}): departs BEFORE the previous segment arrived — a chronologically '
                    'impossible connection (arrival after the connecting departure)',
              );
            }
            if (seg.arrivalTime != null) previousArrival = seg.arrivalTime;

            // No degenerate "board and alight at the same stop" transit segment.
            if (seg.boardingStopId != null && seg.alightingStopId != null) {
              expect(seg.boardingStopId, isNot(equals(seg.alightingStopId)),
                  reason: 'pair $i segment $s: transit segment boards and alights at the SAME stop — a zero-distance loop');
            }
          }

          // Final segment must actually end at (approximately) the
          // requested destination coordinate — never silently
          // terminate somewhere else.
          final last = journey.segments.last;
          if (last.toLat != null && last.toLon != null) {
            final finalGap = _haversineMeters(last.toLat!, last.toLon!, dest.stopLat, dest.stopLon);
            expect(finalGap, lessThan(5.0),
                reason: 'pair $i: final segment ends ${finalGap}m from the requested destination coordinate');
          }

          // --- SOFT diagnostic signals (reported, not hard-failed — Phase 8) ---
          if (straightLine > 50) {
            // Approximate actual geographic movement as the sum of
            // consecutive segment-endpoint distances (a real, if
            // coarse, proxy — segments carry real waypoints for
            // transit legs and real to-coordinates for walking legs).
            double movement = 0;
            double prevLat = origin.stopLat, prevLon = origin.stopLon;
            for (final seg in journey.segments) {
              if (seg.toLat != null && seg.toLon != null) {
                movement += _haversineMeters(prevLat, prevLon, seg.toLat!, seg.toLon!);
                prevLat = seg.toLat!;
                prevLon = seg.toLon!;
              }
            }
            final ratio = movement / straightLine;
            detourRatios.add(ratio);
            if (ratio > 3.0) {
              suspiciousTransfers.add(
                  'pair $i: ${origin.stopName} -> ${dest.stopName} straight=${straightLine.round()}m actual=${movement.round()}m ratio=${ratio.toStringAsFixed(1)}x transfers=${journey.transferCount}');
            }
          }
        }
      }

      // ignore: avoid_print
      print('[NETWORK STRESS TEST] pairs=$pairCount withJourney=$pairsWithJourney withoutJourney=$pairsWithNoJourney '
          'journeysValidated=$totalJourneysValidated');
      if (transferCounts.isNotEmpty) {
        final avgTransfers = transferCounts.reduce((a, b) => a + b) / transferCounts.length;
        final avgWalking = walkingDistances.reduce((a, b) => a + b) / walkingDistances.length;
        // ignore: avoid_print
        print('[NETWORK STRESS TEST] avgTransfers=${avgTransfers.toStringAsFixed(2)} avgWalkingMeters=${avgWalking.toStringAsFixed(0)} '
            'maxTransfers=${transferCounts.reduce(max)}');
      }
      if (detourRatios.isNotEmpty) {
        detourRatios.sort();
        final p50 = detourRatios[detourRatios.length ~/ 2];
        final p90 = detourRatios[(detourRatios.length * 0.9).floor().clamp(0, detourRatios.length - 1)];
        // ignore: avoid_print
        print('[NETWORK STRESS TEST] detour ratio (actual movement / straight-line): median=${p50.toStringAsFixed(2)}x p90=${p90.toStringAsFixed(2)}x');
      }
      if (suspiciousTransfers.isNotEmpty) {
        // ignore: avoid_print
        print('[NETWORK STRESS TEST] ${suspiciousTransfers.length} journeys with >3x geographic detour ratio (reported, not failed):');
        for (final s in suspiciousTransfers.take(15)) {
          // ignore: avoid_print
          print('  $s');
        }
      }

      expect(totalJourneysValidated, greaterThan(0),
          reason: 'the random sample should find AT LEAST some real, valid journeys across the network — zero would '
              'indicate a systemic failure, not just sparse coverage');
    }, timeout: const Timeout(Duration(hours: 3)));
  });

  group('Phase 16 — Golden journeys (human-readable regression scenarios)', () {
    final scenarios = <(String, String)>[
      ('Chromepet', 'Tambaram'),
      ('VIT Chennai', 'Airport'),
      ('VIT Chennai', 'Chennai Central'),
      ('Airport', 'Chennai Central'),
      ('Guindy', 'Tambaram'),
      ('Adyar', 'Chennai Central'),
      ('Koyambedu', 'Airport'),
      ('Tondiarpet', 'Chennai Central'), // "North Chennai -> Central"
      ('Porur', 'Velachery'), // "West Chennai -> South Chennai"
      ('Ambattur', 'Tambaram'), // likely genuine multi-transfer
      // AUDIT ADD (Phase D Part 17): the remaining 4 of the 10 EXACT
      // regression pairs the phase spec named, not previously covered
      // (reverse-direction + 3 more real-world pairs).
      ('Tambaram', 'Chromepet'), // reverse of the first scenario
      ('Anna Nagar', 'Chennai Central'),
      ('Chromepet', 'Airport'),
      ('Tambaram', 'Chennai Central'),
    ];

    for (final (originName, destName) in scenarios) {
      test('$originName -> $destName', () async {
        final resolver = GtfsLocalityResolver(repo);
        final originStop = await resolver.resolve('$originName, Chennai') ?? await resolver.resolve(originName);
        final destStop = await resolver.resolve('$destName, Chennai') ?? await resolver.resolve(destName);

        if (originStop == null || destStop == null) {
          // ignore: avoid_print
          print('[GOLDEN] $originName -> $destName: locality resolution incomplete '
              '(origin=${originStop?.stopName ?? "UNRESOLVED"}, dest=${destStop?.stopName ?? "UNRESOLVED"}) — '
              'reported, not failed (a resolution gap, not a routing bug).');
          return;
        }

        final journeys = await repo.findJourneys(
          originLat: originStop.stopLat,
          originLon: originStop.stopLon,
          destinationLat: destStop.stopLat,
          destinationLon: destStop.stopLon,
          departureAfter: _fixedReferenceTime,
        );

        if (journeys.isEmpty) {
          // ignore: avoid_print
          print('[GOLDEN] $originName (${originStop.stopName}) -> $destName (${destStop.stopName}): NO JOURNEY FOUND '
              '(reason: ${repo.lastJourneyPlanningFailureReason}) — valid outcome, reported not failed.');
          return;
        }

        final best = journeys.first;
        final modes = best.segments.map((s) => s.type.name).join(' -> ');
        // ignore: avoid_print
        print('[GOLDEN] $originName (${originStop.stopName}) -> $destName (${destStop.stopName}): '
            'transfers=${best.transferCount} walking=${best.totalWalkingDistanceMeters.round()}m '
            'travel=${best.totalTravelTime.inMinutes}min departs=${best.departureTime} arrives=${best.arrivalTime} '
            'route=$modes buses=${best.busRouteLabels} metros=${best.metroLineLabels}');

        expect(best.segments, isNotEmpty);
        expect(best.arrivalTime.isAfter(best.departureTime) || best.arrivalTime.isAtSameMomentAs(best.departureTime), isTrue);
      });
    }
  });

  group('Phase 17 — Performance baseline across MULTIPLE representative journeys (not just Tambaram)', () {
    test('per-stage timing for 5 geographically distinct real journeys', () async {
      final resolver = GtfsLocalityResolver(repo);
      final pairs = [
        ('Chromepet', 'Tambaram'),
        ('Guindy', 'Airport'),
        ('Adyar', 'Chennai Central'),
        ('Ambattur', 'Velachery'),
        ('Tondiarpet', 'Saidapet'),
      ];
      for (final (originName, destName) in pairs) {
        final originStop = await resolver.resolve('$originName, Chennai') ?? await resolver.resolve(originName);
        final destStop = await resolver.resolve('$destName, Chennai') ?? await resolver.resolve(destName);
        if (originStop == null || destStop == null) continue;

        await repo.findJourneys(
          originLat: originStop.stopLat,
          originLon: originStop.stopLon,
          destinationLat: destStop.stopLat,
          destinationLon: destStop.stopLon,
          departureAfter: _fixedReferenceTime,
        );
        final timings = repo.lastJourneySearchTimingsMs;
        // ignore: avoid_print
        print('[PERF] $originName -> $destName: $timings');
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
