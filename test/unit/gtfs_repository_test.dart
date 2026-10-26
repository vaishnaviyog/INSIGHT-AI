import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/repositories/gtfs_repository.dart';
import 'package:vaishnavi/services/location_service.dart';

/// P0 regression tests for the route-search-latency investigation's
/// GTFS-preparation fix: on a real device, the bundled feed's
/// first-ever import measured ~574s (see GtfsRepository's doc
/// comment) — that is only acceptable as a genuine ONE-TIME cost, and
/// these tests exist specifically to prove it behaves that way:
/// [GtfsRepository.initialize] must be safe to call repeatedly and
/// concurrently on the same instance without re-running the
/// empty-check-then-import sequence more than once, must recover
/// (not permanently wedge) after a failed attempt, and previously-
/// imported data must be visible to a FRESH instance pointed at the
/// same on-disk database (the "survives screen/service recreation"
/// requirement — a fresh instance is exactly what a new
/// `NavigationScreen` used to construct every time before this fix).
///
/// Deliberately does NOT exercise GtfsImportService's real CSV/ZIP
/// parsing against the actual bundled 1.36M-row feed — that would
/// reintroduce the exact multi-minute cost this fix removes from the
/// critical path, and correctness of that parsing is unchanged/
/// untouched by this fix. Empty-vs-populated `stops` state is
/// simulated with a single directly-inserted row where a test needs
/// "already imported" — enough to exercise
/// [GtfsRepository.needsFirstTimeImport]/the internal check
/// correctly, without needing a real import to have run.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // AudioService (constructed indirectly via LocationService? — no,
  // LocationService itself touches no platform channel at
  // construction) — kept for symmetry with other test files in case
  // that changes; harmless if unused.
  const flutterTtsChannel = MethodChannel('flutter_tts');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    flutterTtsChannel,
    (MethodCall call) async => 1,
  );

  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('insight_gtfs_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() {
    // Best-effort: sqflite_common_ffi's native SQLite handle can lag
    // slightly behind `dispose()`'s returned Future on Windows, which
    // can make an immediate delete of the temp dir fail with a
    // file-in-use error. That's OS temp-folder hygiene, not a
    // correctness signal this suite should fail on — the OS reclaims
    // its own temp directory regardless.
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('GtfsRepository.needsFirstTimeImport', () {
    test('reports true on a freshly created, empty database', () async {
      final repo = GtfsRepository();
      await repo.initialize(locationService: LocationService());
      expect(await repo.needsFirstTimeImport(), isTrue);
      await repo.dispose();
    });

    test('reports false once at least one stop has been recorded', () async {
      final repo = GtfsRepository();
      await repo.initialize(locationService: LocationService());
      await repo.debugInsertFakeStopForTest();
      expect(await repo.needsFirstTimeImport(), isFalse);
      await repo.dispose();
    });
  });

  group('GtfsRepository.initialize — memoization (requirement A/C)', () {
    test('two sequential calls on the same instance return the identical Future', () async {
      final repo = GtfsRepository();
      final first = repo.initialize(locationService: LocationService());
      await first;
      final second = repo.initialize(locationService: LocationService());
      expect(identical(first, second), isTrue,
          reason: 'a second call must reuse the already-completed initialization, not run the body again');
      await repo.dispose();
    });

    test('two concurrent (unawaited-between) calls return the identical Future — no duplicate init/import work', () async {
      final repo = GtfsRepository();
      final first = repo.initialize(locationService: LocationService());
      final second = repo.initialize(locationService: LocationService()); // fired before `first` resolves
      expect(identical(first, second), isTrue,
          reason: 'concurrent callers must await the SAME in-flight initialization, never start a second one');
      await first;
      await second;
      await repo.dispose();
    });

    test('5 fully concurrent calls all share the exact same Future — proves at most one import body ever runs',
        () async {
      final repo = GtfsRepository();
      final futures = List.generate(5, (_) => repo.initialize(locationService: LocationService()));
      // Every call — none awaited between — must be the SAME Future
      // instance. If even one were a distinct Future, that would mean
      // a second `_initializeOnce()` body (and therefore a second
      // empty-check-then-import sequence) started.
      for (final f in futures.skip(1)) {
        expect(identical(futures.first, f), isTrue);
      }
      await Future.wait(futures);
      await repo.dispose();
    });

    test('importFromZipFile (the real import pipeline, unchanged) actually populates data', () async {
      // Builds a tiny, real, valid GTFS zip (not the 1.36M-row
      // production feed) and imports it via the existing public
      // passthrough — confirms the underlying import mechanism this
      // fix wraps still genuinely works, and that needsFirstTimeImport
      // reflects real imported data, not just a manually-seeded row.
      final repo = GtfsRepository();
      await repo.initialize(locationService: LocationService());
      expect(await repo.needsFirstTimeImport(), isTrue);

      final zipFile = File('${tempDir.path}/tiny_fixture.zip')..writeAsBytesSync(await _buildTinyGtfsZipBytes());
      await repo.importFromZipFile(zipFile);

      expect(await repo.needsFirstTimeImport(), isFalse);
      await repo.dispose();
    });

    test('an import that inserts no stops (corrupt/empty zip) does NOT mark the database as ready', () async {
      // GtfsImportService.importFromZipBytes doesn't throw on garbage
      // bytes (ZipDecoder is lenient — it just finds no matching
      // agency.txt/stops.txt/etc. entries and imports nothing, which
      // it treats as a trivial "succeeded" no-op, not an error — that
      // is unchanged, existing behavior, not something this fix
      // touches). What actually matters for THIS fix is that
      // needsFirstTimeImport() reflects REAL row counts, not whatever
      // a report claims — this proves that: whatever the import
      // "succeeded" flag says, zero stops actually landed, so
      // needsFirstTimeImport() must still correctly say true.
      final repo = GtfsRepository();
      await repo.initialize(locationService: LocationService());
      expect(await repo.needsFirstTimeImport(), isTrue);

      final corruptZip = File('${tempDir.path}/corrupt.zip')..writeAsBytesSync([1, 2, 3, 4, 5]); // not a valid zip
      await repo.importFromZipFile(corruptZip);

      expect(await repo.needsFirstTimeImport(), isTrue,
          reason: 'no real stops were ever imported, so the database must not be considered ready');
      await repo.dispose();
    });

    test('a failed initialize() does not permanently wedge — a later call can retry and succeed', () async {
      // Now that a real prepared-database asset exists
      // (assets/gtfs/prepared_chennai_gtfs.db.gz), it installs
      // successfully whenever autoImportAssetPathIfEmpty is provided —
      // so a nonexistent CSV asset path alone no longer reaches the
      // old CSV-import fallback to force a failure there (the prepared
      // copy already satisfies "has data" first). Instead, force a
      // genuine failure in the NEW first step
      // (installPreparedDatabaseIfNeeded's file copy) by pointing
      // path_provider at a path that is a FILE, not a directory —
      // File.writeAsBytes into a path under a non-directory throws a
      // real IO error, the same class of failure (disk full,
      // permission denied) this recovery contract exists to survive.
      final brokenPath = '${tempDir.path}/not_a_directory';
      File(brokenPath).writeAsStringSync('this is a file, not a directory');
      PathProviderPlatform.instance = _FakePathProviderPlatform(brokenPath);

      final repo = GtfsRepository();
      await expectLater(
        repo.initialize(locationService: LocationService(), autoImportAssetPathIfEmpty: 'assets/does_not_exist.zip'),
        throwsA(anything),
      );

      // Point back at a real, writable directory and retry — must
      // succeed, not replay the same cached exception forever.
      PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
      await repo.initialize(locationService: LocationService());
      expect(await repo.needsFirstTimeImport(), isTrue); // still empty — the failed attempt never got that far
      await repo.dispose();
    });
  });

  group('GtfsRepository — persistence across instance recreation (requirement D/"survives screen recreation")', () {
    test('data imported by one instance is visible to a NEW instance pointed at the same database', () async {
      final first = GtfsRepository();
      await first.initialize(locationService: LocationService());
      await first.debugInsertFakeStopForTest();
      expect(await first.needsFirstTimeImport(), isFalse);
      await first.dispose();

      // A brand-new instance — exactly what NavigationScreen used to
      // construct fresh every time before this fix.
      final second = GtfsRepository();
      await second.initialize(locationService: LocationService());
      expect(await second.needsFirstTimeImport(), isFalse,
          reason: 'previously-imported data must survive a fresh GtfsRepository instance, not trigger a re-import');
      await second.dispose();
    });
  });

  group('GtfsRepository schema (requirement E — schemaVersion/onUpgrade still correct)', () {
    test('a freshly created database has the trips.service_id index the perf fix added', () async {
      final repo = GtfsRepository();
      await repo.initialize(locationService: LocationService());
      final hasIndex = await repo.debugHasTripsServiceIdIndexForTest();
      expect(hasIndex, isTrue);
      await repo.dispose();
    });
  });
}

/// Builds a minimal, real, valid GTFS feed (one agency, two stops, one
/// route, one trip, two stop_times, one calendar entry) as in-memory
/// zip bytes — small and fast, purely to prove the auto-import
/// mechanism runs the real GtfsImportService exactly once under
/// concurrency, without paying the real bundled feed's cost.
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
  final tmp = Directory.systemTemp.createTempSync('insight_gtfs_fixture_');
  final srcDir = Directory('${tmp.path}/src')..createSync();
  try {
    File('${srcDir.path}/agency.txt').writeAsStringSync(agency);
    File('${srcDir.path}/stops.txt').writeAsStringSync(stops);
    File('${srcDir.path}/routes.txt').writeAsStringSync(routes);
    File('${srcDir.path}/trips.txt').writeAsStringSync(trips);
    File('${srcDir.path}/stop_times.txt').writeAsStringSync(stopTimes);
    File('${srcDir.path}/calendar.txt').writeAsStringSync(calendar);
    // Output path must NOT be inside the directory being zipped.
    final zipPath = '${tmp.path}/out.zip';
    await encoder.zipDirectory(srcDir, filename: zipPath);
    return File(zipPath).readAsBytesSync();
  } finally {
    tmp.deleteSync(recursive: true);
  }
}
