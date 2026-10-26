import 'dart:typed_data';

import '../../../models/gtfs/stop.dart';
import '../../gtfs/gtfs_query_service.dart';
import 'gtfs_pattern.dart';
import 'raptor_pattern_store.dart';

/// The in-memory network `RaptorRouter` scans — built ONCE per date
/// (see `GtfsTimetableCache`) from a single ordered `stop_times` query
/// via `GtfsQueryService.getTimetableRows`, not recreating the GTFS
/// database or any of its import/query logic: this is purely a
/// derived, cached view for routing.
class GtfsTimetable {
  final Map<String, GtfsPattern> patternsById;
  final Map<String, List<PatternStopRef>> patternRefsByStop;
  final Map<String, GtfsStop> allStopsById;

  const GtfsTimetable({
    required this.patternsById,
    required this.patternRefsByStop,
    required this.allStopsById,
  });
}

/// Builds a [GtfsTimetable] for a given active-service-id set.
///
/// WHY PATTERNS, NOT ROUTES: two trips on the same `route_id` can
/// legitimately visit different stop subsets (a short-turn, a branch).
/// RAPTOR's route-scanning step depends on every trip in a "route"
/// visiting the exact same stops in the exact same order — grouping by
/// (route_id + exact stop-id sequence) is what guarantees that, at the
/// cost of splitting a branching route into multiple patterns (which
/// is correct, not a compromise).
class GtfsTimetableLoader {
  final GtfsQueryService queryService;
  GtfsTimetableLoader(this.queryService);

  /// TEMPORARY PERF-DIAGNOSTIC (route-search-latency investigation,
  /// Phase 3 — see JourneyPlannerService.lastSearchTimingsMs for the
  /// same convention): per-stage numbers for the MOST RECENT [load]
  /// call — null until the first call completes. Answers "is the cold
  /// timetable build dominated by the SQL read or by Dart-side pattern
  /// construction, and how much data are we actually talking about."
  /// Field names stay the same regardless of which path (prepared
  /// patterns vs row-by-row) actually ran — see [lastLoadUsedPreparedPatterns]
  /// for that — so a before/after comparison reads the same keys.
  Map<String, int>? lastLoadDiagnosticsMs;

  /// TEMPORARY PERF-DIAGNOSTIC: true if the MOST RECENT [load] call
  /// used the precomputed `raptor_patterns` table (fast path); false
  /// if it fell back to the row-by-row `stop_times` path (either no
  /// prepared patterns were shipped, or they were present but failed
  /// validation — see the WARNING log line in that case). Null before
  /// the first call.
  bool? lastLoadUsedPreparedPatterns;

  Future<GtfsTimetable> load(Set<String> activeServiceIds) async {
    // AUDIT ADD (route-search-latency investigation, Phase 3 —
    // precomputed RAPTOR patterns): try the fast, precomputed path
    // FIRST. Returns null (not shipped — an older prepared-database
    // build, or the CSV-import fallback path) or throws
    // RaptorPatternStoreException (shipped but invalid/corrupted,
    // which must be reported, not silently downgraded) — see
    // raptor_pattern_store.dart's doc comment. Either way, falling
    // through to the ORIGINAL row-by-row path below is always safe:
    // nothing about that path changes.
    final preparedStopwatch = Stopwatch()..start();
    try {
      final prepared = await decodePreparedPatterns(queryService, activeServiceIds);
      if (prepared != null) {
        final preparedMs = preparedStopwatch.elapsedMilliseconds;
        final tripsCount = prepared.patternsById.values.fold<int>(0, (sum, p) => sum + p.tripIds.length);
        lastLoadUsedPreparedPatterns = true;
        lastLoadDiagnosticsMs = {
          'sqlMs': preparedMs,
          'sqlRows': prepared.patternsById.length,
          'patternBuildMs': 0,
          'patterns': prepared.patternsById.length,
          'trips': tripsCount,
        };
        // ignore: avoid_print
        print('[GtfsTimetableLoader] TIMING (prepared patterns): sql_rows=${prepared.patternsById.length} '
            'sql_ms=$preparedMs pattern_build_ms=0 patterns=${prepared.patternsById.length} trips=$tripsCount');
        return prepared;
      }
    } on RaptorPatternStoreException catch (e) {
      // ignore: avoid_print
      print('[GtfsTimetableLoader] WARNING: prepared RAPTOR patterns present but invalid ($e) — '
          'falling back to the row-by-row stop_times path.');
    }

    lastLoadUsedPreparedPatterns = false;
    // ORIGINAL row-by-row path — UNCHANGED below.
    final sqlStopwatch = Stopwatch()..start();
    final rows = await queryService.getTimetableRows(activeServiceIds);
    final allStops = await queryService.getAllStops();
    final sqlMs = sqlStopwatch.elapsedMilliseconds;
    final allStopsById = {for (final s in allStops) s.stopId: s};

    final buildStopwatch = Stopwatch()..start();

    // Rows are already ORDER BY trip_id, stop_sequence — grouping by
    // trip_id via a single linear pass (not re-sorting) is sufficient.
    final byTrip = <String, List<Map<String, Object?>>>{};
    for (final row in rows) {
      byTrip.putIfAbsent(row['trip_id'] as String, () => []).add(row);
    }

    final builders = <String, _PatternBuilder>{};
    for (final tripRows in byTrip.values) {
      if (tripRows.isEmpty) continue;
      final routeId = tripRows.first['route_id'] as String;
      final stopIds = tripRows.map((r) => r['stop_id'] as String).toList(growable: false);
      final patternKey = '$routeId|${stopIds.join(',')}';

      final arrivals = Int32List(tripRows.length);
      final departures = Int32List(tripRows.length);
      for (int i = 0; i < tripRows.length; i++) {
        arrivals[i] = _hhmmssToSeconds(tripRows[i]['arrival_time'] as String);
        departures[i] = _hhmmssToSeconds(tripRows[i]['departure_time'] as String);
      }

      final builder = builders.putIfAbsent(patternKey, () => _PatternBuilder(patternKey, routeId, stopIds));
      builder.addTrip(tripRows.first['trip_id'] as String? ?? '', arrivals, departures);
    }

    final patternsById = <String, GtfsPattern>{};
    final patternRefsByStop = <String, List<PatternStopRef>>{};
    for (final builder in builders.values) {
      final pattern = builder.build();
      patternsById[pattern.patternId] = pattern;
      for (int i = 0; i < pattern.stopIds.length; i++) {
        patternRefsByStop.putIfAbsent(pattern.stopIds[i], () => []).add(PatternStopRef(pattern, i));
      }
    }

    final patternBuildMs = buildStopwatch.elapsedMilliseconds;
    lastLoadDiagnosticsMs = {
      'sqlMs': sqlMs,
      'sqlRows': rows.length,
      'patternBuildMs': patternBuildMs,
      'patterns': patternsById.length,
      'trips': byTrip.length,
    };
    // ignore: avoid_print
    print('[GtfsTimetableLoader] TIMING: sql_rows=${rows.length} sql_ms=$sqlMs '
        'pattern_build_ms=$patternBuildMs patterns=${patternsById.length} trips=${byTrip.length}');

    return GtfsTimetable(patternsById: patternsById, patternRefsByStop: patternRefsByStop, allStopsById: allStopsById);
  }

  int _hhmmssToSeconds(String hhmmss) {
    final parts = hhmmss.split(':');
    return int.parse(parts[0]) * 3600 + int.parse(parts[1]) * 60 + int.parse(parts[2]);
  }
}

class _PatternBuilder {
  final String patternId;
  final String routeId;
  final List<String> stopIds;
  final List<String> _tripIds = [];
  final List<Int32List> _arrivals = [];
  final List<Int32List> _departures = [];

  _PatternBuilder(this.patternId, this.routeId, this.stopIds);

  void addTrip(String tripId, Int32List arrivals, Int32List departures) {
    _tripIds.add(tripId);
    _arrivals.add(arrivals);
    _departures.add(departures);
  }

  GtfsPattern build() {
    // Sort trips by their departure at stop index 0 — required so
    // RaptorRouter's "earliest catchable trip" scan can rely on trips
    // being in chronological order at every stop (true for any
    // well-formed, non-overtaking schedule, which real bus schedules
    // are).
    final order = List.generate(_tripIds.length, (i) => i)
      ..sort((a, b) => _departures[a][0].compareTo(_departures[b][0]));
    return GtfsPattern(
      patternId: patternId,
      routeId: routeId,
      stopIds: stopIds,
      tripArrivalSeconds: [for (final i in order) _arrivals[i]],
      tripDepartureSeconds: [for (final i in order) _departures[i]],
      tripIds: [for (final i in order) _tripIds[i]],
    );
  }
}

/// Caches the built [GtfsTimetable] per calendar date — rebuilding it
/// on every search would repeat the full `stop_times` scan every time;
/// rebuilding it once per date is enough (service days don't change
/// mid-day) and keeps "offline operation" viable without a network
/// dependency for routing itself.
class GtfsTimetableCache {
  final GtfsTimetableLoader _loader;
  DateTime? _cachedDate;
  GtfsTimetable? _cachedTimetable;

  GtfsTimetableCache(GtfsQueryService queryService) : _loader = GtfsTimetableLoader(queryService);

  /// TEMPORARY PERF-DIAGNOSTIC (route-search-latency investigation,
  /// Phase 3): the underlying loader's own per-stage numbers for
  /// whichever call last actually ran the loader — see
  /// [GtfsTimetableLoader.lastLoadDiagnosticsMs]. Exposed here too so
  /// callers only holding a [GtfsTimetableCache] reference (e.g.
  /// JourneyPlannerService) don't need their own reference to the
  /// loader.
  Map<String, int>? get lastLoadDiagnosticsMs => _loader.lastLoadDiagnosticsMs;

  /// TEMPORARY PERF-DIAGNOSTIC: whether the MOST RECENT [forDate] call
  /// was a cache hit (reused the in-memory timetable) or a miss (ran
  /// the full loader). Null until the first call completes.
  bool? lastWasCacheHit;

  Future<GtfsTimetable> forDate(DateTime date, Set<String> activeServiceIds) async {
    final stopwatch = Stopwatch()..start();
    final dateKey = DateTime(date.year, date.month, date.day);
    if (_cachedDate == dateKey && _cachedTimetable != null) {
      lastWasCacheHit = true;
      // ignore: avoid_print
      print('[GtfsTimetableCache] TIMING: timetable_cache=hit total_ms=${stopwatch.elapsedMilliseconds}');
      return _cachedTimetable!;
    }
    final timetable = await _loader.load(activeServiceIds);
    _cachedDate = dateKey;
    _cachedTimetable = timetable;
    lastWasCacheHit = false;
    // ignore: avoid_print
    print('[GtfsTimetableCache] TIMING: timetable_cache=miss total_ms=${stopwatch.elapsedMilliseconds}');
    return timetable;
  }
}
