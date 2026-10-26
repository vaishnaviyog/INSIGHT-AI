import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/services/gtfs/gtfs_database_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_import_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_query_service.dart';
import 'package:vaishnavi/services/journey/journey_planner_service.dart';
import 'package:vaishnavi/services/journey/raptor/gtfs_timetable.dart';
import 'package:vaishnavi/services/journey/raptor/raptor_pattern_store.dart';

/// MOST IMPORTANT test in the route-search-latency investigation's
/// precomputed-RAPTOR-pattern work (Phase 3): proves the NEW path
/// (precomputed `raptor_patterns` table, read+filtered in Dart) and
/// the OLD path (row-by-row `stop_times` query, unchanged) produce
/// IDENTICAL routing input and IDENTICAL routing output for the same
/// GTFS data and date — not "looks right," but structural equality of
/// every `GtfsPattern` field, plus end-to-end journey-result equality
/// through the real, unmodified `JourneyPlannerService`/`RaptorRouter`.
///
/// Uses a small, hand-built, real (not fabricated-to-pass) GTFS fixture
/// with two routes, two trips per pattern (exercises earliest-
/// catchable-trip selection), and a genuine walking transfer between
/// two close-but-different stops (exercises RAPTOR's footpath
/// relaxation across multiple rounds) — richer than a trivial one-trip
/// fixture specifically so this test can catch a real divergence, not
/// just confirm two empty results match.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late GtfsDatabaseService dbService;
  late GtfsQueryService queryService;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('insight_raptor_equivalence_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    dbService = GtfsDatabaseService();
    await dbService.initialize();
    queryService = GtfsQueryService(dbService);
    final importService = GtfsImportService(dbService);
    final report = await importService.importFromZipBytes(Uint8List.fromList(await _buildFixtureGtfsZipBytes()));
    if (!report.succeeded) {
      throw StateError('fixture GTFS import failed: ${report.failureReason}');
    }
  });

  tearDown(() async {
    await dbService.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  final referenceDate = DateTime(2026, 8, 10); // a Monday, within SVC1's every-day range
  const originLat = 13.0000, originLon = 80.0000; // at S1
  const destLat = 13.0300, destLon = 80.0010; // at S5

  test('GtfsTimetableLoader: prepared-pattern path and row-by-row path produce structurally identical timetables',
      () async {
    final activeServiceIds = await queryService.getActiveServiceIds(referenceDate);
    expect(activeServiceIds, isNotEmpty);

    // OLD PATH: no raptor_patterns table exists yet -> load() falls
    // through to the row-by-row path.
    final oldLoader = GtfsTimetableLoader(queryService);
    final oldTimetable = await oldLoader.load(activeServiceIds);
    expect(oldLoader.lastLoadUsedPreparedPatterns, isFalse);
    expect(oldTimetable.patternsById, isNotEmpty, reason: 'fixture must produce at least one real pattern');

    // Precompute and write the prepared patterns into the SAME database.
    await dbService.schema.createRaptorPatternSchema(dbService.database);
    final allRows = await queryService.getAllTimetableRowsForPatternPrecomputation();
    final precomputed = buildPrecomputedPatterns(allRows);
    await writePrecomputedPatterns(dbService.database, precomputed);

    // NEW PATH: a FRESH loader (no cache to worry about) now finds the
    // prepared table and uses it.
    final newLoader = GtfsTimetableLoader(queryService);
    final newTimetable = await newLoader.load(activeServiceIds);
    expect(newLoader.lastLoadUsedPreparedPatterns, isTrue);

    _expectTimetablesEquivalent(oldTimetable, newTimetable);
  });

  test('JourneyPlannerService.findJourneys: prepared-pattern path and row-by-row path produce identical journeys',
      () async {
    // OLD PATH — a fresh JourneyPlannerService (its own, uncached
    // GtfsTimetableCache), before any prepared patterns exist.
    final oldPlanner = JourneyPlannerService(queryService);
    final oldJourneys = await oldPlanner.findJourneys(
      originLat: originLat,
      originLon: originLon,
      destinationLat: destLat,
      destinationLon: destLon,
      departureAfter: referenceDate.add(const Duration(hours: 7, minutes: 55)),
    );
    expect(oldJourneys, isNotEmpty, reason: 'the fixture is specifically built so a route exists — see class doc comment');

    // Precompute and write prepared patterns.
    await dbService.schema.createRaptorPatternSchema(dbService.database);
    final allRows = await queryService.getAllTimetableRowsForPatternPrecomputation();
    final precomputed = buildPrecomputedPatterns(allRows);
    await writePrecomputedPatterns(dbService.database, precomputed);

    // NEW PATH — a SEPARATE, fresh JourneyPlannerService instance, so
    // its GtfsTimetableCache is not polluted by the old run's cached
    // (pre-prepared-patterns) timetable for the same date.
    final newPlanner = JourneyPlannerService(queryService);
    final newJourneys = await newPlanner.findJourneys(
      originLat: originLat,
      originLon: originLon,
      destinationLat: destLat,
      destinationLon: destLon,
      departureAfter: referenceDate.add(const Duration(hours: 7, minutes: 55)),
    );

    expect(newJourneys.length, equals(oldJourneys.length), reason: 'different number of journeys returned');
    for (int i = 0; i < oldJourneys.length; i++) {
      final oldJ = oldJourneys[i];
      final newJ = newJourneys[i];
      expect(newJ.departureTime, equals(oldJ.departureTime), reason: 'journey $i departureTime differs');
      expect(newJ.arrivalTime, equals(oldJ.arrivalTime), reason: 'journey $i arrivalTime differs');
      expect(newJ.transferCount, equals(oldJ.transferCount), reason: 'journey $i transferCount differs');
      expect(newJ.totalTravelTime, equals(oldJ.totalTravelTime), reason: 'journey $i totalTravelTime differs');
      expect(newJ.segments.length, equals(oldJ.segments.length), reason: 'journey $i segment count differs');
      for (int s = 0; s < oldJ.segments.length; s++) {
        final oldSeg = oldJ.segments[s];
        final newSeg = newJ.segments[s];
        expect(newSeg.type, equals(oldSeg.type), reason: 'journey $i segment $s type differs');
        expect(newSeg.tripId, equals(oldSeg.tripId), reason: 'journey $i segment $s tripId (selected trip) differs');
        expect(newSeg.routeId, equals(oldSeg.routeId), reason: 'journey $i segment $s routeId differs');
        expect(newSeg.boardingStopId, equals(oldSeg.boardingStopId), reason: 'journey $i segment $s boardingStopId differs');
        expect(newSeg.alightingStopId, equals(oldSeg.alightingStopId), reason: 'journey $i segment $s alightingStopId differs');
        expect(newSeg.departureTime, equals(oldSeg.departureTime), reason: 'journey $i segment $s departureTime differs');
        expect(newSeg.arrivalTime, equals(oldSeg.arrivalTime), reason: 'journey $i segment $s arrivalTime differs');
      }
    }
  });

  test('a corrupted raptor_pattern_schema (version mismatch) is reported, not silently used', () async {
    await dbService.schema.createRaptorPatternSchema(dbService.database);
    // A version this build does not understand.
    await dbService.database.insert('raptor_pattern_schema', {
      'schema_version': 999999,
      'pattern_count': 0,
      'built_at': DateTime.now().toIso8601String(),
    });

    final activeServiceIds = await queryService.getActiveServiceIds(referenceDate);
    final loader = GtfsTimetableLoader(queryService);
    // Must not throw out to the caller — must fall back safely — but
    // must still end up using the row-by-row path, not silently trust
    // the unreadable prepared table.
    final timetable = await loader.load(activeServiceIds);
    expect(loader.lastLoadUsedPreparedPatterns, isFalse,
        reason: 'a version-mismatched prepared table must never be trusted');
    expect(timetable.patternsById, isNotEmpty, reason: 'the safe fallback must still produce a real, correct timetable');
  });
}

void _expectTimetablesEquivalent(GtfsTimetable a, GtfsTimetable b) {
  expect(b.patternsById.keys.toSet(), equals(a.patternsById.keys.toSet()), reason: 'pattern ID sets differ');
  for (final patternId in a.patternsById.keys) {
    final pa = a.patternsById[patternId]!;
    final pb = b.patternsById[patternId]!;
    expect(pb.routeId, equals(pa.routeId), reason: 'pattern $patternId routeId differs');
    expect(pb.stopIds, equals(pa.stopIds), reason: 'pattern $patternId stopIds differ');
    expect(pb.tripIds, equals(pa.tripIds), reason: 'pattern $patternId tripIds (and their order) differ');
    expect(pb.tripArrivalSeconds.length, equals(pa.tripArrivalSeconds.length),
        reason: 'pattern $patternId trip count differs');
    for (int i = 0; i < pa.tripArrivalSeconds.length; i++) {
      expect(pb.tripArrivalSeconds[i], equals(pa.tripArrivalSeconds[i]),
          reason: 'pattern $patternId trip $i arrival seconds differ');
      expect(pb.tripDepartureSeconds[i], equals(pa.tripDepartureSeconds[i]),
          reason: 'pattern $patternId trip $i departure seconds differ');
    }
  }
  expect(b.allStopsById.keys.toSet(), equals(a.allStopsById.keys.toSet()), reason: 'stop ID sets differ');
  for (final stopId in a.allStopsById.keys) {
    expect(b.allStopsById[stopId]!.stopLat, equals(a.allStopsById[stopId]!.stopLat));
    expect(b.allStopsById[stopId]!.stopLon, equals(a.allStopsById[stopId]!.stopLon));
  }
}

/// Two routes, two trips per pattern (exercises earliest-catchable-
/// trip selection among multiple trips), and a genuine ~33m walking
/// transfer between S3 and S4 (two DIFFERENT, close-but-not-identical
/// stops — exercises RAPTOR's footpath relaxation, not just same-stop
/// boarding). NOT a trivial single-trip fixture: rich enough that a
/// real bug in pattern reconstruction (wrong trip order, wrong stop
/// sequence, wrong arrival/departure values) would actually change
/// the winning journey, which is the whole point of an equivalence
/// test.
Future<List<int>> _buildFixtureGtfsZipBytes() async {
  const agency = 'agency_id,agency_name,agency_url,agency_timezone\n'
      'A1,Test Agency,https://example.com,Asia/Kolkata\n';
  const stops = 'stop_id,stop_name,stop_lat,stop_lon\n'
      'S1,Origin Stop,13.0000,80.0000\n'
      'S2,Mid Stop A,13.0100,80.0000\n'
      'S3,Transfer Stop,13.0200,80.0000\n'
      'S4,Transfer Stop Near,13.0203,80.0003\n'
      'S5,Destination Stop,13.0300,80.0010\n';
  const routes = 'route_id,agency_id,route_short_name,route_long_name,route_type\n'
      'R1,A1,1,Route One,3\n'
      'R2,A1,2,Route Two,3\n';
  const trips = 'route_id,trip_id,service_id\n'
      'R1,T1a,SVC1\n'
      'R1,T1b,SVC1\n'
      'R2,T2a,SVC1\n'
      'R2,T2b,SVC1\n';
  const stopTimes = 'trip_id,arrival_time,departure_time,stop_id,stop_sequence\n'
      'T1a,08:00:00,08:00:00,S1,0\n'
      'T1a,08:10:00,08:10:00,S2,1\n'
      'T1a,08:20:00,08:20:00,S3,2\n'
      'T1b,08:30:00,08:30:00,S1,0\n'
      'T1b,08:40:00,08:40:00,S2,1\n'
      'T1b,08:50:00,08:50:00,S3,2\n'
      'T2a,08:25:00,08:25:00,S4,0\n'
      'T2a,08:35:00,08:35:00,S5,1\n'
      'T2b,09:00:00,09:00:00,S4,0\n'
      'T2b,09:10:00,09:10:00,S5,1\n';
  const calendar = 'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n'
      'SVC1,1,1,1,1,1,1,1,20200101,20301231\n';

  final encoder = ZipFileEncoder();
  final tmp = Directory.systemTemp.createTempSync('insight_raptor_equivalence_fixture_');
  final srcDir = Directory('${tmp.path}/src')..createSync();
  try {
    File('${srcDir.path}/agency.txt').writeAsStringSync(agency);
    File('${srcDir.path}/stops.txt').writeAsStringSync(stops);
    File('${srcDir.path}/routes.txt').writeAsStringSync(routes);
    File('${srcDir.path}/trips.txt').writeAsStringSync(trips);
    File('${srcDir.path}/stop_times.txt').writeAsStringSync(stopTimes);
    File('${srcDir.path}/calendar.txt').writeAsStringSync(calendar);
    final zipPath = '${tmp.path}/out.zip';
    await encoder.zipDirectory(srcDir, filename: zipPath);
    return File(zipPath).readAsBytesSync();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}
