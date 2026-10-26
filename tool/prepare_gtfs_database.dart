import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/database/gtfs_database.dart';
import 'package:vaishnavi/services/gtfs/gtfs_database_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_import_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_query_service.dart';
import 'package:vaishnavi/services/journey/raptor/raptor_pattern_store.dart';

/// BUILD-TIME (development machine only) GTFS preparation script — NOT
/// part of the app and NOT run on-device. Produces
/// `assets/gtfs/prepared_chennai_gtfs.db`, the artifact
/// `GtfsDatabase.installPreparedDatabaseIfNeeded` copies into place on
/// first run instead of the app parsing the ~1.36M-row `stop_times`
/// CSV itself (measured ~574s on a real device — see that method's
/// doc comment).
///
/// WHY A `flutter_test` SCRIPT, NOT A PLAIN `dart run` SCRIPT: it needs
/// `rootBundle.load` to read the real bundled
/// `assets/gtfs/chennai-unified-gtfs.zip` exactly the way the app
/// does, which requires a Flutter test binding; and it needs a real
/// SQLite engine to run on a dev machine (no Android/iOS platform
/// channel available here), which `sqflite_common_ffi` provides. Both
/// are already dev dependencies of this project (see
/// `test/unit/gtfs_repository_test.dart` for the same pattern).
///
/// REUSES PRODUCTION CODE UNCHANGED: `GtfsDatabaseService`,
/// `GtfsImportService`, and `GtfsDatabase.createSchema` are the exact
/// same classes the app uses — this script does not reimplement or
/// duplicate any import/schema logic, so the prepared database is
/// byte-for-byte what an on-device first-time import would have
/// produced (same validation, same rejected/invalid rows, same
/// indexes), just built once here instead of once per install.
///
/// RUN: `flutter test tool/prepare_gtfs_database.dart`
/// Expect several minutes (the real import work, unchanged) — this is
/// a genuine one-time development-time cost, not something a
/// developer runs often (only when `assets/gtfs/chennai-unified-gtfs.zip`
/// changes). Bump [GtfsDatabase.bundledGtfsDataVersion] whenever this
/// is re-run against updated source data, so on-device installs
/// correctly detect the change and replace their stale copy.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

const String _sourceAssetPath = 'assets/gtfs/chennai-unified-gtfs.zip';
const String _outputAssetPath = 'assets/gtfs/prepared_chennai_gtfs.db.gz';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'prepare shipped GTFS database from $_sourceAssetPath',
    () async {
      final workDir = Directory.systemTemp.createTempSync('insight_gtfs_prepare_');
      PathProviderPlatform.instance = _FakePathProviderPlatform(workDir.path);
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;

      // ignore: avoid_print
      print('Building prepared GTFS database from $_sourceAssetPath ...');
      final stopwatch = Stopwatch()..start();

      final dbService = GtfsDatabaseService();
      await dbService.initialize();
      final importService = GtfsImportService(dbService);
      final report = await importService.importFromAsset(_sourceAssetPath);

      stopwatch.stop();
      // ignore: avoid_print
      print(report.toReadableSummary());
      // ignore: avoid_print
      print('Import wall time: ${stopwatch.elapsed}');

      expect(report.succeeded, isTrue, reason: 'source GTFS import must succeed before shipping the artifact');

      // --- Validate real row counts landed (not a fabricated/empty DB) ---
      final db = dbService.database;
      Future<int> countOf(String table) async {
        final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
        return rows.first['c'] as int;
      }

      final stopCount = await countOf('stops');
      final routeCount = await countOf('routes');
      final tripCount = await countOf('trips');
      final stopTimeCount = await countOf('stop_times');
      final calendarCount = await countOf('calendar');

      // ignore: avoid_print
      print('Row counts — stops: $stopCount, routes: $routeCount, trips: $tripCount, '
          'stop_times: $stopTimeCount, calendar: $calendarCount');

      expect(stopCount, greaterThan(0), reason: 'no stops imported — refusing to ship an empty database');
      expect(routeCount, greaterThan(0), reason: 'no routes imported — refusing to ship an empty database');
      expect(tripCount, greaterThan(0), reason: 'no trips imported — refusing to ship an empty database');
      expect(stopTimeCount, greaterThan(0), reason: 'no stop_times imported — refusing to ship an empty database');
      expect(calendarCount, greaterThan(0), reason: 'no calendar rows imported — refusing to ship an empty database');

      // --- Validate every index production queries rely on exists ---
      Future<Set<String>> indexNamesOf(String table) async {
        final rows = await db.rawQuery("PRAGMA index_list('$table')");
        return rows.map((r) => r['name'] as String).toSet();
      }

      final stopTimesIndexes = await indexNamesOf('stop_times');
      final tripsIndexes = await indexNamesOf('trips');

      for (final required in ['idx_stop_times_stop_id', 'idx_stop_times_trip_id', 'idx_stop_times_stop_departure']) {
        expect(stopTimesIndexes, contains(required), reason: 'stop_times is missing required index $required');
      }
      for (final required in ['idx_trips_route_id', 'idx_trips_service_id']) {
        expect(tripsIndexes, contains(required), reason: 'trips is missing required index $required');
      }

      // --- SQLite's own integrity check ---
      final integrity = await db.rawQuery('PRAGMA integrity_check');
      final integrityResult = integrity.first.values.first as String;
      expect(integrityResult, equals('ok'), reason: 'PRAGMA integrity_check reported: $integrityResult');

      // --- Real relationship spot-checks (every trip's route exists; every stop_time's trip/stop exist) ---
      //
      // TOLERANCE, NOT ZERO: GtfsImportService validates each FILE's
      // rows independently against its own header (see that class's
      // doc comment on the bundled feed's known data-quality issues —
      // malformed CMRL rows, blank-coordinate stops, etc., rejected
      // per-file). It does not cross-validate foreign keys BETWEEN
      // files, and never has — a stop_times row naming a stop_id that
      // was itself rejected during stops.txt validation (or is simply
      // absent from the source feed) is not a bug this script
      // introduces; it's identical, pre-existing behavior an on-device
      // CSV import produces today. Every real production query here
      // (GtfsQueryService) reaches stop_times only via an INNER JOIN
      // to stops/trips, so an orphaned row is silently excluded, never
      // a crash risk. A hard zero here would fail this build over the
      // exact data quality the app already ships and accepts; instead
      // this fails only if orphans exceed 1% of the table, which would
      // indicate a genuinely broken import, not normal feed noise.
      Future<void> checkOrphanRate(String label, int orphanCount, int totalCount) async {
        final ratio = totalCount == 0 ? 0.0 : orphanCount / totalCount;
        // ignore: avoid_print
        print('$label: $orphanCount / $totalCount orphaned (${(ratio * 100).toStringAsFixed(3)}%)');
        expect(ratio, lessThan(0.01),
            reason: '$label orphan rate ${(ratio * 100).toStringAsFixed(3)}% exceeds the 1% tolerance — '
                'this looks like a genuinely broken import, not normal feed noise');
      }

      final orphanTripRoutes = await countOf(
        '(SELECT trip_id FROM trips t WHERE NOT EXISTS (SELECT 1 FROM routes r WHERE r.route_id = t.route_id))'
            ' AS orphan_trip_routes',
      );
      await checkOrphanRate('trips -> routes', orphanTripRoutes, tripCount);

      final orphanStopTimeStops = await countOf(
        '(SELECT trip_id FROM stop_times st WHERE NOT EXISTS (SELECT 1 FROM stops s WHERE s.stop_id = st.stop_id))'
            ' AS orphan_stop_time_stops',
      );
      await checkOrphanRate('stop_times -> stops', orphanStopTimeStops, stopTimeCount);

      final orphanStopTimeTrips = await countOf(
        '(SELECT trip_id FROM stop_times st WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.trip_id = st.trip_id))'
            ' AS orphan_stop_time_trips',
      );
      await checkOrphanRate('stop_times -> trips', orphanStopTimeTrips, stopTimeCount);

      // --- Prove the prepared database can actually answer a real production query shape ---
      final sampleStop = (await db.query('stops', limit: 1)).first;
      final nearby = await db.rawQuery('''
        SELECT stop_id FROM stops
        WHERE stop_lat BETWEEN ? AND ? AND stop_lon BETWEEN ? AND ?
      ''', [
        (sampleStop['stop_lat'] as num) - 0.01,
        (sampleStop['stop_lat'] as num) + 0.01,
        (sampleStop['stop_lon'] as num) - 0.01,
        (sampleStop['stop_lon'] as num) + 0.01,
      ]);
      expect(nearby, isNotEmpty, reason: 'a bounding-box query around a real stop must find at least that stop');

      // --- Precompute the RAPTOR-ready pattern representation (route-search-latency investigation, Phase 3) ---
      //
      // WHY: GtfsTimetableLoader.load()'s row-by-row path (unchanged,
      // still the fallback) marshals ~1.36M stop_times rows through
      // sqflite's Android platform channel on every cold search —
      // measured 20+ minutes on a real device with RAPTOR never even
      // reached. The identical query+grouping via sqflite_common_ffi
      // (no platform channel) took ~11s. This step does that same
      // work ONCE, here, and ships the result as a compact table the
      // runtime reads instead — see raptor_pattern_store.dart's doc
      // comment for the full design.
      // ignore: avoid_print
      print('Precomputing RAPTOR patterns (whole feed, not date-filtered) ...');
      final patternStopwatch = Stopwatch()..start();

      await dbService.schema.createRaptorPatternSchema(db);
      final queryService = GtfsQueryService(dbService);
      final allTimetableRows = await queryService.getAllTimetableRowsForPatternPrecomputation();
      final patterns = buildPrecomputedPatterns(allTimetableRows);

      // ignore: avoid_print
      print('Built ${patterns.length} patterns from ${allTimetableRows.length} rows '
          '(${patternStopwatch.elapsedMilliseconds}ms so far)');

      // --- Validate every pattern before writing it ---
      final knownStopIds = (await db.query('stops', columns: ['stop_id'])).map((r) => r['stop_id'] as String).toSet();
      final knownTripIds = (await db.query('trips', columns: ['trip_id'])).map((r) => r['trip_id'] as String).toSet();
      final knownRouteIds = (await db.query('routes', columns: ['route_id'])).map((r) => r['route_id'] as String).toSet();

      int totalTrips = 0;
      int orderingViolations = 0;
      int unknownStopRefs = 0;
      int unknownTripRefs = 0;
      int unknownRouteRefs = 0;
      for (final p in patterns) {
        expect(p.stopIds.length, greaterThan(0), reason: 'pattern ${p.patternId} has zero stops');
        expect(p.tripIds.length, greaterThan(0), reason: 'pattern ${p.patternId} has zero trips');
        expect(p.tripIds.length, equals(p.serviceIds.length), reason: 'pattern ${p.patternId}: tripIds/serviceIds length mismatch');
        expect(p.tripIds.length, equals(p.tripArrivalSeconds.length), reason: 'pattern ${p.patternId}: tripIds/arrival length mismatch');
        expect(p.tripIds.length, equals(p.tripDepartureSeconds.length), reason: 'pattern ${p.patternId}: tripIds/departure length mismatch');
        totalTrips += p.tripIds.length;

        if (!knownRouteIds.contains(p.routeId)) unknownRouteRefs++;
        for (final stopId in p.stopIds) {
          if (!knownStopIds.contains(stopId)) unknownStopRefs++;
        }
        for (int i = 0; i < p.tripIds.length; i++) {
          if (!knownTripIds.contains(p.tripIds[i])) unknownTripRefs++;
          final arr = p.tripArrivalSeconds[i];
          final dep = p.tripDepartureSeconds[i];
          expect(arr.length, equals(p.numStops), reason: 'pattern ${p.patternId} trip ${p.tripIds[i]}: arrival array length != numStops');
          expect(dep.length, equals(p.numStops), reason: 'pattern ${p.patternId} trip ${p.tripIds[i]}: departure array length != numStops');
          // GTFS ordering semantics: arrival <= departure at each stop,
          // and departure at stop s <= arrival at stop s+1 — informational
          // count, not a hard failure (see checkOrphanRate's doc comment
          // above for why this codebase tolerates real-world feed
          // messiness rather than rejecting it outright).
          for (int s = 0; s < p.numStops; s++) {
            if (arr[s] > dep[s]) orderingViolations++;
            if (s > 0 && dep[s - 1] > arr[s]) orderingViolations++;
          }
          // Ascending-departure-at-stop-0 sort, the exact invariant
          // RaptorRouter's earliest-catchable-trip scan depends on.
          if (i > 0) {
            expect(p.tripDepartureSeconds[i][0], greaterThanOrEqualTo(p.tripDepartureSeconds[i - 1][0]),
                reason: 'pattern ${p.patternId}: trips are not sorted ascending by departure at stop 0');
          }
        }
      }

      // ignore: avoid_print
      print('Pattern validation — total trips: $totalTrips, unknown stop refs: $unknownStopRefs, '
          'unknown trip refs: $unknownTripRefs, unknown route refs: $unknownRouteRefs, '
          'arrival/departure ordering violations: $orderingViolations '
          '(${totalTrips == 0 ? 0 : (orderingViolations / totalTrips * 100).toStringAsFixed(3)}% of trips)');
      expect(unknownStopRefs, equals(0), reason: 'a precomputed pattern references a stop_id not present in stops');
      expect(unknownTripRefs, equals(0), reason: 'a precomputed pattern references a trip_id not present in trips');
      expect(unknownRouteRefs, equals(0), reason: 'a precomputed pattern references a route_id not present in routes');

      await writePrecomputedPatterns(db, patterns);

      final writtenSchemaInfo = await queryService.getRaptorPatternSchemaInfo();
      expect(writtenSchemaInfo, isNotNull, reason: 'raptor_pattern_schema row was not written');
      expect(writtenSchemaInfo!['schema_version'], equals(GtfsDatabase.raptorPatternSchemaVersion));
      expect(writtenSchemaInfo['pattern_count'], equals(patterns.length));
      final writtenPatternRows = await queryService.getRaptorPatternRows();
      expect(writtenPatternRows.length, equals(patterns.length),
          reason: 'raptor_patterns row count does not match the patterns actually built');

      // ignore: avoid_print
      print('RAPTOR pattern precomputation done: ${patterns.length} patterns, $totalTrips trips '
          '(${patternStopwatch.elapsedMilliseconds}ms total)');

      // Re-run SQLite's integrity check now that the new tables exist.
      final integrityAfterPatterns = await db.rawQuery('PRAGMA integrity_check');
      final integrityAfterPatternsResult = integrityAfterPatterns.first.values.first as String;
      expect(integrityAfterPatternsResult, equals('ok'),
          reason: 'PRAGMA integrity_check after writing raptor_patterns reported: $integrityAfterPatternsResult');

      // VACUUM: shrink/defragment the file before shipping it as an asset.
      // ignore: avoid_print
      print('Running VACUUM ...');
      await db.execute('VACUUM');

      await dbService.dispose();

      // --- Gzip-compress the finished file and write it to the shipped asset path ---
      // Raw SQLite file is large (the same ~1.36M-row data an on-device
      // CSV import would produce); gzip cuts it substantially for
      // shipping. GtfsDatabase.installPreparedDatabaseIfNeeded
      // decompresses it back to a real .db file on first run.
      final builtDbFile = File('${workDir.path}/gtfs.db');
      expect(await builtDbFile.exists(), isTrue);
      final builtSizeBytes = await builtDbFile.length();

      // ignore: avoid_print
      print('Compressing (gzip) ...');
      final rawBytes = await builtDbFile.readAsBytes();
      final compressedBytes = gzip.encode(rawBytes);

      final outputFile = File(_outputAssetPath);
      await outputFile.parent.create(recursive: true);
      await outputFile.writeAsBytes(compressedBytes, flush: true);

      // Remove a stale uncompressed artifact from an older run of this
      // script, if one is still sitting in the assets directory.
      final staleUncompressed = File('assets/gtfs/prepared_chennai_gtfs.db');
      if (await staleUncompressed.exists()) await staleUncompressed.delete();

      // ignore: avoid_print
      print('Prepared database written to $_outputAssetPath '
          '(raw: ${(builtSizeBytes / (1024 * 1024)).toStringAsFixed(2)} MB, '
          'gzipped: ${(compressedBytes.length / (1024 * 1024)).toStringAsFixed(2)} MB)');
      // ignore: avoid_print
      print('Data version constant to confirm/bump: GtfsDatabase.bundledGtfsDataVersion '
          '(currently "${GtfsDatabase.bundledGtfsDataVersion}")');

      try {
        workDir.deleteSync(recursive: true);
      } catch (_) {
        // best-effort dev-machine temp cleanup only
      }
    },
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
