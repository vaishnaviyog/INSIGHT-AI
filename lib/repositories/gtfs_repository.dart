import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/gtfs/route.dart';
import '../models/gtfs/stop.dart';
import '../models/gtfs/stop_time.dart';
import '../models/gtfs/trip.dart';
import '../models/journey/journey.dart';
import '../services/gtfs/gtfs_database_service.dart';
import '../services/gtfs/gtfs_import_report.dart';
import '../services/gtfs/gtfs_import_service.dart';
import '../services/gtfs/gtfs_location_service.dart';
import '../services/gtfs/gtfs_query_service.dart';
import '../services/journey/journey_planner_service.dart';
import '../services/location_service.dart';

/// The ONE public entry point future stages (Stage 3's
/// `NavigationPlanner`/`BusVerificationEngine`, etc.) should depend
/// on — internally composes `GtfsDatabaseService`,
/// `GtfsImportService`, `GtfsQueryService`, and `GtfsLocationService`,
/// but nothing outside `lib/services/gtfs/`+`lib/database/` needs to
/// know those exist separately. Kept independent from the onboarding
/// module per this stage's instruction — nothing here imports
/// anything under `lib/onboarding/`.
///
/// AUDIT FIX (route-search-latency investigation — P0 device report):
/// on a fresh install, the bundled GTFS feed's ~1.36M `stop_times`
/// rows take on the order of MINUTES to import (measured on a real
/// device: ~574s). That is only acceptable as a genuine one-time
/// setup cost — it must never repeat once the data is actually on
/// disk. Two separate things previously undermined that:
///
/// 1. NO CROSS-CALL MEMOIZATION: [initialize] re-ran its whole body
///    (including the has-anything-been-imported check) on every call,
///    with no way for a second, concurrent, or later caller to know
///    "this is already happening/already done" without redoing the
///    check itself. Two callers racing the empty check could both
///    decide to import.
/// 2. WIDGET-LIFETIME SCOPING: `NavigationScreen` constructed a NEW
///    `GtfsRepository()` (see the old code) every time it was pushed,
///    so leaving and re-entering navigation discarded the in-memory
///    warm state (the RAPTOR timetable cache) even though the
///    ON-DISK data was already there.
///
/// FIX: [initialize] is now memoized via [_initializationFuture] —
/// every caller, on the SAME instance, concurrent or sequential,
/// awaits the exact same in-flight (or already-completed) Future,
/// so the import body genuinely runs at most once per instance. AND
/// production code now shares ONE instance via [instance] (a plain
/// static field, not an enforced language-level singleton — see its
/// own doc comment for why tests still construct `GtfsRepository()`
/// directly), so that memoization is effectively app-lifetime for
/// real usage. The underlying `stops` row-count check inside
/// [initialize] already correctly avoids re-importing across actual
/// app RESTARTS (a fresh process still finds the previously-imported
/// data on disk) — that part was always correct; what was missing was
/// avoiding redundant WITHIN-PROCESS work.
class GtfsRepository {
  /// Shared instance for real app code (`NavigationScreen`, the GTFS
  /// research/validation screen) to use, so the several-minute
  /// first-time import and the warm in-memory RAPTOR timetable cache
  /// are genuinely app-lifetime rather than re-triggered/discarded
  /// every time a screen is recreated. Deliberately just a plain
  /// static field wrapping the ordinary constructor below, NOT a
  /// private-constructor-enforced singleton — tests construct
  /// `GtfsRepository()` directly (each pointed at its own temp
  /// database) because they need independent, isolated instances;
  /// this field is purely a convenience for production code to share
  /// one, the same pattern as e.g. `WidgetsBinding.instance`.
  static final GtfsRepository instance = GtfsRepository();

  final GtfsDatabaseService _databaseService = GtfsDatabaseService();
  late final GtfsImportService _importService;
  late final GtfsQueryService _queryService;
  late final GtfsLocationService _locationService;
  late final JourneyPlannerService _journeyPlannerService;

  bool _initialized = false;

  /// Memoizes the in-flight/completed [initialize] call — see this
  /// class's doc comment. Reset to null on failure so a later call can
  /// genuinely retry rather than replaying the same cached exception
  /// forever (a plain memoized Future would otherwise do that, since
  /// awaiting an already-failed Future just rethrows its error).
  Future<void>? _initializationFuture;

  /// True only while a genuine first-time GTFS import (not just a
  /// database open) is actually running.
  ///
  /// AUDIT FIX (GTFS-during-onboarding fix — real device bug): THIS,
  /// not [needsFirstTimeImport], is what any UI/status-message
  /// decision should read while preparation might already be in
  /// flight. It's a plain in-memory field — reading it can never
  /// block. [needsFirstTimeImport] queries the database directly,
  /// and sqflite serializes every operation on one connection — a
  /// query issued while the import's write transaction is open
  /// simply QUEUES behind it and doesn't return until that
  /// transaction finishes (which can be minutes). A real bug this
  /// caused: `VoiceOnboardingController.start()` awaited
  /// `needsFirstTimeImport()` moments after `main()` kicked off the
  /// real background import on the SAME shared `GtfsRepository`
  /// instance — the query queued behind that import's transaction,
  /// and onboarding appeared completely frozen (no further questions)
  /// for the entire import duration. Use [isImportingForFirstTime]
  /// for any check that might run while preparation is already
  /// running; reserve [needsFirstTimeImport] for contexts
  /// guaranteed nothing is currently importing (e.g. the very first
  /// caller of the app's lifetime, before anything else has raced
  /// it, or tests against an isolated instance).
  bool isImportingForFirstTime = false;

  /// [autoImportAssetPathIfEmpty], if provided, imports that bundled
  /// GTFS asset automatically the FIRST time this repository is ever
  /// initialized on a device with no data yet (checked via a cheap
  /// `stops` row count) — added for Stage 2B so `NavigationScreen`'s
  /// journey planning works out of the box without requiring someone
  /// to have already run the Research Menu's GTFS Import & Validation
  /// screen manually first. That screen still exists and still works
  /// the same way (re-importing is harmless — see
  /// `GtfsImportService`'s transactional drop-and-recreate).
  ///
  /// Safe to call repeatedly and/or concurrently on the SAME instance
  /// — see this class's doc comment on [_initializationFuture].
  Future<void> initialize({required LocationService locationService, String? autoImportAssetPathIfEmpty}) {
    return _initializationFuture ??= _initializeOnce(
      locationService: locationService,
      autoImportAssetPathIfEmpty: autoImportAssetPathIfEmpty,
    );
  }

  Future<void> _initializeOnce({required LocationService locationService, String? autoImportAssetPathIfEmpty}) async {
    try {
      // Guarded by `_initialized`, NOT just "run once per call" — on a
      // RETRY after a previous attempt failed partway through (e.g.
      // during the import below, after these `late final` fields were
      // already assigned), redoing this block would throw
      // LateInitializationError("already initialized") on the second
      // assignment. Once this part has genuinely succeeded once, it
      // never needs to run again, retry or not.
      if (!_initialized) {
        // AUDIT FIX (prepared-database architecture — route-search-
        // latency investigation): BEFORE the database is even opened,
        // put a real, pre-populated copy in place if one isn't
        // already there and up to date — copying+decompressing an
        // asset (seconds) instead of the CSV-import fallback below
        // parsing the bundled feed's ~1.36M `stop_times` rows itself
        // (measured ~574s on a real device). A no-op if already
        // prepared, or if no prepared asset is bundled at all — see
        // GtfsDatabase.installPreparedDatabaseIfNeeded's own doc
        // comment. Must run before `_databaseService.initialize()`
        // (which is the first thing that actually opens the file) —
        // this only touches the filesystem, never an open connection.
        //
        // GATED BY [autoImportAssetPathIfEmpty], same as the CSV
        // fallback below — this and that fallback are two
        // implementations of the ONE "auto-populate this repository
        // with the bundled feed" feature (fast path vs. slow path),
        // so both should only run when a caller has actually opted
        // into that behavior. Without this gate, a caller that wants
        // a deliberately bare/empty repository (e.g. the Research
        // Menu's GTFS Import & Validation screen, which drives its own
        // explicit, from-scratch CSV import to validate the import
        // pipeline itself; or a test that wants a known-empty
        // database) would silently get real production data anyway,
        // since the prepared asset genuinely exists on disk once
        // built — an unwanted, surprising side effect of a plain
        // `initialize()` call.
        if (autoImportAssetPathIfEmpty != null) {
          await _databaseService.schema.installPreparedDatabaseIfNeeded();
        }
        await _databaseService.initialize();
        // ignore: avoid_print
        print('[GTFS-DIAG] post-open validation report:\n${await _databaseService.schema.diagnosticReport()}');
        _importService = GtfsImportService(_databaseService);
        _queryService = GtfsQueryService(_databaseService);
        _locationService = GtfsLocationService(locationService: locationService, queryService: _queryService);
        _journeyPlannerService = JourneyPlannerService(_queryService);
        _initialized = true;
      }

      // FALLBACK, PRESERVED UNCHANGED: if the prepared-database copy
      // above didn't leave a populated database — no prepared asset
      // bundled (an older build), or it was somehow invalid — this
      // still makes the app fully functional via the original,
      // slower CSV import rather than silently leaving GTFS broken.
      // The common case (a valid prepared asset was bundled and just
      // got copied into place above) makes `_hasAnyStopsImported()`
      // here true, so this block is skipped entirely.
      final hasStops = await _hasAnyStopsImported();
      // ignore: avoid_print
      print('[GTFS-DIAG] _hasAnyStopsImported()=$hasStops (autoImportAssetPathIfEmpty=$autoImportAssetPathIfEmpty) — '
          '${hasStops ? "using prepared/existing database" : "FALLING BACK TO SLOW CSV IMPORT"}');
      if (autoImportAssetPathIfEmpty != null && !hasStops) {
        isImportingForFirstTime = true;
        // ignore: avoid_print
        print('[GTFS-DIAG] BEGIN slow CSV import from $autoImportAssetPathIfEmpty ...');
        final csvStopwatch = Stopwatch()..start();
        try {
          await _importService.importFromAsset(autoImportAssetPathIfEmpty);
        } finally {
          isImportingForFirstTime = false;
          // ignore: avoid_print
          print('[GTFS-DIAG] END slow CSV import — took ${csvStopwatch.elapsedMilliseconds}ms');
        }
      }
    } catch (e) {
      _initializationFuture = null;
      rethrow;
    }
  }

  /// Ground-truth pre-check: does a database row count directly. Only
  /// safe to await when nothing is CURRENTLY importing on this
  /// instance — see [isImportingForFirstTime]'s doc comment for why a
  /// query issued while an import's write transaction is open queues
  /// behind it (can block for the transaction's full duration, i.e.
  /// minutes) instead of returning quickly. Prefer
  /// [isImportingForFirstTime] for any UI/status decision that might
  /// run concurrently with [initialize]. This remains correct and
  /// useful for callers that know no import is in flight (tests
  /// against an isolated instance; a caller that already checked
  /// [isImportingForFirstTime] is false and `_initializationFuture`
  /// hasn't been started elsewhere).
  Future<bool> needsFirstTimeImport() async {
    await _databaseService.initialize();
    return !(await _hasAnyStopsImported());
  }

  Future<bool> _hasAnyStopsImported() async {
    final rows = await _databaseService.database.rawQuery('SELECT COUNT(*) AS c FROM stops');
    final count = rows.first['c'] as int? ?? 0;
    return count > 0;
  }

  void _assertInitialized() {
    if (!_initialized) {
      throw StateError('GtfsRepository.initialize() must be called before use.');
    }
  }

  // --- Import -------------------------------------------------------------
  Future<GtfsImportReport> importFromAsset(String assetPath) {
    _assertInitialized();
    return _importService.importFromAsset(assetPath);
  }

  Future<GtfsImportReport> importFromZipFile(File file) {
    _assertInitialized();
    return _importService.importFromZipFile(file);
  }

  // --- Query ----------------------------------------------------------------
  Future<GtfsStop?> getStopById(String stopId) {
    _assertInitialized();
    return _queryService.getStopById(stopId);
  }

  Future<List<GtfsStop>> searchStops(String query, {int limit = 20}) {
    _assertInitialized();
    return _queryService.searchStops(query, limit: limit);
  }

  Future<List<String>> getAllDistinctStopNames() {
    _assertInitialized();
    return _queryService.getAllDistinctStopNames();
  }

  Future<List<GtfsRoute>> searchRoutes(String query, {int limit = 20}) {
    _assertInitialized();
    return _queryService.searchRoutes(query, limit: limit);
  }

  Future<List<GtfsRoute>> getRoutesForStop(String stopId) {
    _assertInitialized();
    return _queryService.getRoutesForStop(stopId);
  }

  Future<List<GtfsTrip>> getTripsForRoute(String routeId) {
    _assertInitialized();
    return _queryService.getTripsForRoute(routeId);
  }

  Future<List<GtfsStopTime>> getUpcomingTrips({
    required String stopId,
    required String afterTimeHHMMSS,
    int limit = 10,
  }) {
    _assertInitialized();
    return _queryService.getUpcomingTrips(stopId: stopId, afterTimeHHMMSS: afterTimeHHMMSS, limit: limit);
  }

  Future<List<GtfsStop>> getNearbyStops({
    required double latitude,
    required double longitude,
    double radiusMeters = 500,
    int limit = 20,
  }) {
    _assertInitialized();
    return _queryService.getNearbyStops(
        latitude: latitude, longitude: longitude, radiusMeters: radiusMeters, limit: limit);
  }

  Future<GtfsStop?> getNearestStop({required double latitude, required double longitude}) {
    _assertInitialized();
    return _queryService.getNearestStop(latitude: latitude, longitude: longitude);
  }

  // --- Location (GPS) ---------------------------------------------------
  Future<GtfsStop?> nearestBusStop() {
    _assertInitialized();
    return _locationService.nearestBusStop();
  }

  Future<GtfsStop?> nearestMetroStation() {
    _assertInitialized();
    return _locationService.nearestMetroStation();
  }

  // --- Journey planning (Stage 2B, replaced by a RAPTOR-based engine) ---
  Future<List<Journey>> findJourneys({
    required double originLat,
    required double originLon,
    required double destinationLat,
    required double destinationLon,
    DateTime? departureAfter,
    double? walkingRadiusMeters,
    int? maxTransfers,
    double? walkingSpeedMetersPerSecond,
    bool accessibilityPreferFewerTransfers = false,
  }) {
    _assertInitialized();
    return _journeyPlannerService.findJourneys(
      originLat: originLat,
      originLon: originLon,
      destinationLat: destinationLat,
      destinationLon: destinationLon,
      departureAfter: departureAfter,
      walkingRadiusMeters: walkingRadiusMeters ?? 800,
      maxTransfers: maxTransfers ?? 4,
      walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond ?? 1.2,
      accessibilityPreferFewerTransfers: accessibilityPreferFewerTransfers,
    );
  }

  /// PHASE NEXT (safe timetable-loading caching investigation) — see
  /// `JourneyPlannerService.prewarmTimetableCache`'s doc comment for the
  /// full rationale and safety argument. Fire-and-forget from
  /// `main.dart`, right after this repository's own [initialize]
  /// finishes.
  Future<void> prewarmTimetableCache([DateTime? date]) {
    _assertInitialized();
    return _journeyPlannerService.prewarmTimetableCache(date);
  }

  /// Test/diagnostic passthrough — see
  /// `JourneyPlannerService.lastTimetableCacheHit`'s doc comment.
  bool? get lastTimetableCacheHit {
    _assertInitialized();
    return _journeyPlannerService.lastTimetableCacheHit;
  }

  /// The specific reason the most recent [findJourneys] call returned
  /// no journeys — null if it succeeded or hasn't been called yet.
  /// See `JourneyPlannerService.lastFailureReason`'s doc comment.
  String? get lastJourneyPlanningFailureReason {
    _assertInitialized();
    return _journeyPlannerService.lastFailureReason;
  }

  /// TEMPORARY PERF-DIAGNOSTIC passthrough — see
  /// `JourneyPlannerService.lastSearchTimingsMs`'s doc comment.
  Map<String, int>? get lastJourneySearchTimingsMs {
    _assertInitialized();
    return _journeyPlannerService.lastSearchTimingsMs;
  }

  /// Toggles the RAPTOR engine's verbose per-stage logging — see
  /// `JourneyPlannerService.debugMode`'s doc comment.
  set journeyPlannerDebugMode(bool enabled) {
    _assertInitialized();
    _journeyPlannerService.debugMode = enabled;
  }

  /// Test-only: inserts one placeholder stop row directly, standing in
  /// for "an import has happened" without needing to run a real
  /// import (against the real 1.36M-row feed or even a tiny fixture)
  /// — see test/unit/gtfs_repository_test.dart's doc comment for why
  /// [needsFirstTimeImport]'s "is there any data yet" check is what's
  /// actually being exercised in most of those tests, not
  /// GtfsImportService's own CSV-parsing correctness (unchanged,
  /// untested here).
  @visibleForTesting
  Future<void> debugInsertFakeStopForTest() async {
    _assertInitialized();
    await _databaseService.database.insert('stops', {
      'stop_id': 'debug_test_stop_${DateTime.now().microsecondsSinceEpoch}',
      'stop_name': 'Debug Test Stop',
      'stop_lat': 13.0,
      'stop_lon': 80.0,
    });
  }

  /// Test-only: confirms the `idx_trips_service_id` index (added by
  /// the route-search-latency investigation's schemaVersion 2 fix —
  /// see `GtfsDatabase.createSchema`) actually exists on a real
  /// database this repository opened, rather than just trusting the
  /// SQL statement compiled without error.
  @visibleForTesting
  Future<bool> debugHasTripsServiceIdIndexForTest() async {
    _assertInitialized();
    final rows = await _databaseService.database.rawQuery("PRAGMA index_list('trips')");
    return rows.any((row) => row['name'] == 'idx_trips_service_id');
  }

  /// Closes the underlying database connection. NEVER call this on
  /// [instance] from a single screen's own dispose() — it is shared,
  /// app-lifetime state; closing it out from under a still-running app
  /// would break every other consumer. This exists for tests (which
  /// construct their own throwaway `GtfsRepository()` instances against
  /// a temp database and need to clean up after themselves) and for
  /// any future genuine app-shutdown path.
  Future<void> dispose() async {
    if (_initialized) await _databaseService.dispose();
  }
}
