import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/database/gtfs_database.dart';
import 'package:vaishnavi/repositories/gtfs_repository.dart';
import 'package:vaishnavi/services/gtfs/gtfs_database_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_import_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_query_service.dart';
import 'package:vaishnavi/services/location_service.dart';

/// Regression tests for the prepared-SQLite-database architecture (the
/// "STOP importing 1.36M CSV rows on the phone" fix — see
/// `GtfsDatabase.installPreparedDatabaseIfNeeded`'s doc comment and
/// `tool/prepare_gtfs_database.dart`). These exercise the on-device
/// CONSUMPTION side: copying/decompressing a prepared database into
/// place, reuse when already up to date, safe replacement on a
/// version change, and proof that a prepared database lets
/// `GtfsRepository.initialize` skip the old CSV-import fallback
/// entirely.
///
/// Deliberately does NOT depend on the real, multi-megabyte production
/// artifact (`assets/gtfs/prepared_chennai_gtfs.db.gz`, built
/// separately and only present after `tool/prepare_gtfs_database.dart`
/// has been run) for most tests — a tiny, real, hand-built GTFS
/// fixture database is installed via
/// [GtfsDatabase.installPreparedDatabaseBytesForTest], the same
/// test-only seam used to prove the atomic-copy contract without
/// requiring that large asset to exist for `flutter test` to pass in
/// a fresh checkout.
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

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('insight_prepared_gtfs_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() {
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('prepared database file contents (fixture)', () {
    test('has every required GTFS table', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'fixture-v1');

      final dbService = GtfsDatabaseService();
      await dbService.initialize();
      final tableRows =
          await dbService.database.rawQuery("SELECT name FROM sqlite_master WHERE type = 'table'");
      final tableNames = tableRows.map((r) => r['name'] as String).toSet();

      for (final required in [
        'agency', 'stops', 'routes', 'trips', 'stop_times', 'calendar', 'calendar_dates', 'shapes',
      ]) {
        expect(tableNames, contains(required));
      }
      await dbService.dispose();
    });

    test('passes SQLite integrity validation', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'fixture-v1');

      final dbService = GtfsDatabaseService();
      await dbService.initialize();
      final result = await dbService.database.rawQuery('PRAGMA integrity_check');
      expect(result.first.values.first, equals('ok'));
      await dbService.dispose();
    });

    test('has every index production queries rely on', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'fixture-v1');

      final dbService = GtfsDatabaseService();
      await dbService.initialize();

      Future<Set<String>> indexNamesOf(String table) async {
        final rows = await dbService.database.rawQuery("PRAGMA index_list('$table')");
        return rows.map((r) => r['name'] as String).toSet();
      }

      final stopTimesIndexes = await indexNamesOf('stop_times');
      final tripsIndexes = await indexNamesOf('trips');
      for (final required in ['idx_stop_times_stop_id', 'idx_stop_times_trip_id', 'idx_stop_times_stop_departure']) {
        expect(stopTimesIndexes, contains(required));
      }
      for (final required in ['idx_trips_route_id', 'idx_trips_service_id']) {
        expect(tripsIndexes, contains(required));
      }
      await dbService.dispose();
    });

    test('every GTFS row relationship (trip->route, stop_time->stop/trip) is valid', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'fixture-v1');

      final dbService = GtfsDatabaseService();
      await dbService.initialize();

      Future<int> countOf(String expr) async {
        final rows = await dbService.database.rawQuery('SELECT COUNT(*) AS c FROM $expr');
        return rows.first['c'] as int;
      }

      expect(
        await countOf(
            '(SELECT trip_id FROM trips t WHERE NOT EXISTS (SELECT 1 FROM routes r WHERE r.route_id = t.route_id)) x'),
        equals(0),
      );
      expect(
        await countOf(
            '(SELECT trip_id FROM stop_times st WHERE NOT EXISTS (SELECT 1 FROM stops s WHERE s.stop_id = st.stop_id)) x'),
        equals(0),
      );
      expect(
        await countOf(
            '(SELECT trip_id FROM stop_times st WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.trip_id = st.trip_id)) x'),
        equals(0),
      );
      await dbService.dispose();
    });

    test('can answer real production queries (GtfsQueryService, unchanged)', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'fixture-v1');

      final dbService = GtfsDatabaseService();
      await dbService.initialize();
      final queryService = GtfsQueryService(dbService);

      final nearby = await queryService.getNearbyStops(latitude: 13.0, longitude: 80.0, radiusMeters: 5000);
      expect(nearby, isNotEmpty);

      final upcoming = await queryService.getUpcomingTrips(stopId: 'S1', afterTimeHHMMSS: '00:00:00');
      expect(upcoming, isNotEmpty);

      await dbService.dispose();
    });
  });

  group('installation mechanics (atomicity / reuse / replacement)', () {
    test('first-run installation succeeds: db file + matching version sidecar exist', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'fixture-v1');

      final dbFile = File('${tempDir.path}/gtfs.db');
      final versionFile = File('${tempDir.path}/gtfs.db.version');
      expect(await dbFile.exists(), isTrue);
      expect(await versionFile.exists(), isTrue);
      expect((await versionFile.readAsString()).trim(), equals('fixture-v1'));
    });

    test('a leftover temp file from an interrupted earlier attempt is never mistaken for a ready database', () async {
      // Simulates a crash between the temp-write and the atomic
      // rename in GtfsDatabase's install logic: a stray
      // "gtfs.db.tmp-<timestamp>" file exists, but nothing was ever
      // renamed into the real "gtfs.db" path and no version sidecar
      // was written.
      final strayTemp = File('${tempDir.path}/gtfs.db.tmp-999999999999');
      await strayTemp.writeAsBytes([1, 2, 3, 4, 5]); // garbage, never a valid db

      final dbFile = File('${tempDir.path}/gtfs.db');
      final versionFile = File('${tempDir.path}/gtfs.db.version');
      expect(await dbFile.exists(), isFalse,
          reason: 'a stray temp file must never be mistaken for the real database file');
      expect(await versionFile.exists(), isFalse);

      // Opening the database at this point (as GtfsRepository.initialize
      // would) must create a genuinely fresh, empty database — never
      // read the stray temp file's garbage bytes.
      final dbService = GtfsDatabaseService();
      await dbService.initialize();
      final rows = await dbService.database.rawQuery('SELECT COUNT(*) AS c FROM stops');
      expect(rows.first['c'], equals(0));
      await dbService.dispose();
    });

    test('installation leaves no leftover temp file behind', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'fixture-v1');

      final leftoverTempFiles =
          tempDir.listSync().whereType<File>().where((f) => f.path.contains('.tmp-')).toList();
      expect(leftoverTempFiles, isEmpty);
    });

    test('installPreparedDatabaseIfNeeded is a no-op once the on-device version already matches (reuse)', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      // Install the fixture but CLAIM it as the real current bundled
      // version — this makes installPreparedDatabaseIfNeeded's
      // version check short-circuit before ever touching rootBundle,
      // which is exactly the "already prepared, do nothing" path this
      // test exercises.
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: GtfsDatabase.bundledGtfsDataVersion);

      final dbFile = File('${tempDir.path}/gtfs.db');
      final beforeModified = dbFile.lastModifiedSync();
      final beforeBytes = await dbFile.readAsBytes();

      await gtfsDb.installPreparedDatabaseIfNeeded();

      expect(dbFile.lastModifiedSync(), equals(beforeModified),
          reason: 'a matching version must not trigger any re-copy');
      expect(await dbFile.readAsBytes(), equals(beforeBytes));
    });

    test('a GTFS version change triggers safe replacement with the real shipped prepared database', () async {
      // Seed an intentionally STALE version marker next to a tiny
      // fixture database, standing in for "an old app install with an
      // older prepared-database build still on disk."
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: 'stale-fixture-version-v0');

      final dbFile = File('${tempDir.path}/gtfs.db');
      final staleSize = await dbFile.length();

      // The real bundledGtfsDataVersion constant doesn't match the
      // stale marker above, so this must load and install the REAL
      // shipped asset (tool/prepare_gtfs_database.dart's output),
      // decompressing it in the process.
      await gtfsDb.installPreparedDatabaseIfNeeded();

      final versionFile = File('${tempDir.path}/gtfs.db.version');
      expect((await versionFile.readAsString()).trim(), equals(GtfsDatabase.bundledGtfsDataVersion));

      final replacedSize = await dbFile.length();
      expect(replacedSize, greaterThan(staleSize * 100),
          reason: 'the real prepared database (real Chennai feed) should be vastly larger than the tiny fixture it replaced');

      // Confirm the replacement is a genuinely usable, populated database.
      final dbService = GtfsDatabaseService();
      await dbService.initialize();
      final stopCountRows = await dbService.database.rawQuery('SELECT COUNT(*) AS c FROM stops');
      expect(stopCountRows.first['c'] as int, greaterThan(1000));
      await dbService.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('GtfsRepository — prepared database means the CSV-import fallback never runs', () {
    test('initialize() with a prepared database already installed never falls back to CSV import', () async {
      final fixtureBytes = await _buildFixtureDatabaseBytes(tempDir);
      final gtfsDb = GtfsDatabase();
      // Claimed as the current version so GtfsRepository.initialize's
      // internal installPreparedDatabaseIfNeeded call finds it already
      // up to date and never touches rootBundle/the real asset.
      await gtfsDb.installPreparedDatabaseBytesForTest(fixtureBytes, version: GtfsDatabase.bundledGtfsDataVersion);

      final repo = GtfsRepository();
      final stopwatch = Stopwatch()..start();
      await repo.initialize(
        locationService: LocationService(),
        // The real, large bundled feed — if this fallback ever ran,
        // it would take tens of seconds even on a dev machine (~46s
        // measured by tool/prepare_gtfs_database.dart) instead of
        // being effectively instant.
        autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
      );
      stopwatch.stop();

      expect(repo.isImportingForFirstTime, isFalse,
          reason: 'a prepared database with real stop data was already present — the CSV fallback must not run');
      expect(await repo.needsFirstTimeImport(), isFalse);
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)),
          reason: 'initialize() must be near-instant when a prepared database is already installed');
      await repo.dispose();
    });
  });
}

/// Builds a tiny, real, valid GTFS-shaped SQLite database file — same
/// schema/importer the production prepared-database artifact uses
/// (`GtfsDatabaseService`/`GtfsImportService`, completely unchanged),
/// just against a small hand-built feed instead of the real ~1.36M-row
/// Chennai one, so these tests run in milliseconds and don't depend on
/// `tool/prepare_gtfs_database.dart` having been run first.
Future<Uint8List> _buildFixtureDatabaseBytes(Directory outerTempDir) async {
  final fixtureDir = Directory.systemTemp.createTempSync('insight_prepared_gtfs_fixture_');
  final previousPlatform = PathProviderPlatform.instance;
  try {
    PathProviderPlatform.instance = _FakePathProviderPlatform(fixtureDir.path);
    final dbService = GtfsDatabaseService();
    await dbService.initialize();
    final importService = GtfsImportService(dbService);
    final zipBytes = await _buildTinyGtfsZipBytes();
    final report = await importService.importFromZipBytes(Uint8List.fromList(zipBytes));
    if (!report.succeeded) {
      throw StateError('fixture GTFS import failed: ${report.failureReason}');
    }
    await dbService.dispose();
    return File('${fixtureDir.path}/gtfs.db').readAsBytesSync();
  } finally {
    PathProviderPlatform.instance = previousPlatform;
    try {
      fixtureDir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// Minimal, real, valid GTFS feed (one agency, two stops, one route,
/// one trip, two stop_times, one calendar entry) as in-memory zip
/// bytes — same shape as the fixture builder in
/// test/unit/gtfs_repository_test.dart.
Future<List<int>> _buildTinyGtfsZipBytes() async {
  const agency = 'agency_id,agency_name,agency_url,agency_timezone\n'
      'A1,Test Agency,https://example.com,Asia/Kolkata\n';
  const stops = 'stop_id,stop_name,stop_lat,stop_lon\n'
      'S1,Stop One,13.0,80.0\n'
      'S2,Stop Two,13.01,80.01\n';
  const routes = 'route_id,agency_id,route_short_name,route_long_name,route_type\n'
      'R1,A1,1,Route One,3\n';
  const trips = 'route_id,trip_id,service_id\n'
      'R1,T1,SVC1\n';
  const stopTimes = 'trip_id,arrival_time,departure_time,stop_id,stop_sequence\n'
      'T1,08:00:00,08:00:00,S1,0\n'
      'T1,08:10:00,08:10:00,S2,1\n';
  const calendar = 'service_id,monday,tuesday,wednesday,thursday,friday,saturday,sunday,start_date,end_date\n'
      'SVC1,1,1,1,1,1,1,1,20200101,20301231\n';

  final encoder = ZipFileEncoder();
  final tmp = Directory.systemTemp.createTempSync('insight_prepared_gtfs_zip_fixture_');
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
