import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vaishnavi/repositories/gtfs_repository.dart';
import 'package:vaishnavi/services/gtfs/gtfs_query_service.dart';
import 'package:vaishnavi/services/gtfs/gtfs_database_service.dart';
import 'package:vaishnavi/services/location_service.dart';

/// PHASE NEXT (safe timetable-loading caching investigation) regression
/// coverage for `GtfsRepository.prewarmTimetableCache` /
/// `JourneyPlannerService.prewarmTimetableCache`.
///
/// WHAT THIS PROVES: a real device measurement (Phase G audit) found
/// the FIRST route search of an app session paying ~6.78s just loading
/// today's timetable via SQL, before RAPTOR ever runs. The fix adds a
/// background prewarm call (see `main.dart`, right after
/// `GtfsRepository.instance.initialize()` finishes) so that cost is
/// usually already paid by the time the user asks for a route. This
/// file proves the prewarm mechanism itself is correct against the
/// real bundled feed: calling it warms the SAME cache `findJourneys`
/// reads, so a search issued after a completed prewarm reuses it
/// (`lastTimetableCacheHit == true`) instead of loading again.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

final DateTime _fixedReferenceTime = DateTime(2026, 8, 12, 9, 0); // a Wednesday, within the feed's service-calendar range

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late GtfsRepository repo;
  late GtfsQueryService rawQueryService;

  setUpAll(() async {
    tempDir = Directory.systemTemp.createTempSync('insight_timetable_prewarm_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
    repo = GtfsRepository();
    await repo.initialize(
      locationService: LocationService(),
      autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
    );
    final rawDbService = GtfsDatabaseService();
    await rawDbService.initialize();
    rawQueryService = GtfsQueryService(rawDbService);
  });

  tearDownAll(() async {
    await repo.dispose();
    try {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('a search after prewarmTimetableCache() reuses the warm timetable instead of reloading it', () async {
    final stops = await rawQueryService.getNearbyStops(latitude: 13.0475, longitude: 80.2077, radiusMeters: 3000, limit: 5);
    expect(stops, isNotEmpty, reason: 'test needs at least one real stop near this coordinate to search a route');
    final origin = stops.first;
    final destStops =
        await rawQueryService.getNearbyStops(latitude: 12.9915, longitude: 80.2337, radiusMeters: 3000, limit: 5);
    expect(destStops, isNotEmpty, reason: 'test needs at least one real stop near the destination coordinate');
    final destination = destStops.first;

    await repo.prewarmTimetableCache(_fixedReferenceTime);

    await repo.findJourneys(
      originLat: origin.stopLat,
      originLon: origin.stopLon,
      destinationLat: destination.stopLat,
      destinationLon: destination.stopLon,
      departureAfter: _fixedReferenceTime,
    );

    expect(repo.lastTimetableCacheHit, isTrue,
        reason: 'findJourneys should reuse the timetable prewarmTimetableCache() already loaded for the same day, '
            'not pay the SQL load cost again');
  });

  test('prewarmTimetableCache() is safe to call before any destination is known (no coordinates involved)', () async {
    // Exercises the real code path with a fresh repository instance to
    // prove prewarming never requires an origin/destination — it only
    // depends on the date, matching how it's actually invoked in
    // main.dart (immediately after GTFS import/open, before onboarding
    // has produced any destination at all).
    final freshTempDir = Directory.systemTemp.createTempSync('insight_timetable_prewarm_fresh_test_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(freshTempDir.path);
    final freshRepo = GtfsRepository();
    await freshRepo.initialize(
      locationService: LocationService(),
      autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
    );
    try {
      await freshRepo.prewarmTimetableCache();
    } finally {
      await freshRepo.dispose();
      try {
        if (freshTempDir.existsSync()) freshTempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
