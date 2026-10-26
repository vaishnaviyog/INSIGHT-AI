import 'dart:convert';
import 'dart:typed_data';

import 'package:sqflite/sqflite.dart';

import '../../../database/gtfs_database.dart';
import '../../gtfs/gtfs_query_service.dart';
import 'gtfs_pattern.dart';
import 'gtfs_timetable.dart';

/// AUDIT ADD (route-search-latency investigation, Phase 3 —
/// precomputed RAPTOR patterns): encodes/decodes the
/// `raptor_patterns`/`raptor_pattern_schema` tables
/// `GtfsDatabase.createRaptorPatternSchema` defines, populated at BUILD
/// TIME by `tool/prepare_gtfs_database.dart`.
///
/// WHY THIS EXISTS: `GtfsTimetableLoader.load()`'s original row-by-row
/// path calls `GtfsQueryService.getTimetableRows`, which returns
/// ~1.36M raw `stop_times` rows through sqflite's Android platform
/// channel — measured 20+ minutes on a real device for a single cold
/// search (RAPTOR itself was never even reached). The IDENTICAL SQL
/// query + Dart-side pattern construction, run via
/// `sqflite_common_ffi` (in-process SQLite, no platform channel),
/// completes in ~11 seconds. That gap is per-row platform-channel
/// marshalling overhead, not SQL execution time or Dart-side
/// algorithm cost — so the fix is eliminating the ~1.36M-row transfer
/// entirely, not touching RAPTOR, the SQL query, or the pattern
/// grouping logic, all of which are already fast.
///
/// DESIGN: this file's precomputed representation covers EVERY trip in
/// the WHOLE feed — deliberately NOT filtered by service_id/date, so
/// one build-time run stays correct for any future date rather than
/// needing to predict which calendar/weekday combinations will be
/// active later (a date-specific precomputation would go stale the
/// moment a calendar's date range boundary is crossed). Each trip's
/// `service_id` is carried alongside its arrival/departure arrays so
/// [decodePreparedPatterns] can apply the EXACT SAME per-date
/// filtering `GtfsQueryService.getActiveServiceIds` already computes
/// (unchanged, still the source of truth for service-calendar
/// semantics) — just in Dart, against a few thousand small in-memory
/// arrays, instead of a second SQL query against 1.36M rows.
///
/// EQUIVALENCE: [buildPrecomputedPatterns] is a deliberate structural
/// mirror of `GtfsTimetableLoader`'s private `_PatternBuilder` —
/// same pattern-grouping key (`route_id|comma-joined stop_ids`), same
/// ascending-departure-at-stop-0 trip sort. Filtering an
/// already-sorted trip list by service_id preserves relative order,
/// so [decodePreparedPatterns]'s output is sort-order-identical to
/// what the row-by-row path would produce for the same date — verified
/// directly by `test/unit/raptor_pattern_equivalence_test.dart`, not
/// just asserted here.
class RaptorPatternStoreException implements Exception {
  final String message;
  RaptorPatternStoreException(this.message);
  @override
  String toString() => 'RaptorPatternStoreException: $message';
}

int _hhmmssToSeconds(String hhmmss) {
  final parts = hhmmss.split(':');
  return int.parse(parts[0]) * 3600 + int.parse(parts[1]) * 60 + int.parse(parts[2]);
}

/// One pattern's raw (unfiltered-by-service) data — the build-time-only
/// intermediate shape [buildPrecomputedPatterns] produces before
/// BLOB-encoding. Carries [serviceIds] per trip (unlike [GtfsPattern],
/// which never needs it — by the time a real [GtfsPattern] exists,
/// either via [decodePreparedPatterns]'s per-date filtering or the
/// original row-by-row path, service-id filtering has already
/// happened). Deliberately a SEPARATE, build/load-time-only type, not
/// a change to [GtfsPattern] itself — RAPTOR and journey assembly
/// never see this type.
class PrecomputedPattern {
  final String patternId;
  final String routeId;
  final List<String> stopIds;
  final List<String> tripIds;
  final List<String> serviceIds;
  final List<Int32List> tripArrivalSeconds;
  final List<Int32List> tripDepartureSeconds;

  PrecomputedPattern({
    required this.patternId,
    required this.routeId,
    required this.stopIds,
    required this.tripIds,
    required this.serviceIds,
    required this.tripArrivalSeconds,
    required this.tripDepartureSeconds,
  });

  int get numStops => stopIds.length;
  int get numTrips => tripIds.length;
}

class _PrecomputedPatternBuilder {
  final String patternId;
  final String routeId;
  final List<String> stopIds;
  final List<String> _tripIds = [];
  final List<String> _serviceIds = [];
  final List<Int32List> _arrivals = [];
  final List<Int32List> _departures = [];

  _PrecomputedPatternBuilder(this.patternId, this.routeId, this.stopIds);

  void addTrip(String tripId, String serviceId, Int32List arrivals, Int32List departures) {
    _tripIds.add(tripId);
    _serviceIds.add(serviceId);
    _arrivals.add(arrivals);
    _departures.add(departures);
  }

  PrecomputedPattern build() {
    // MUST MATCH `_PatternBuilder.build()` in gtfs_timetable.dart's
    // sort key EXACTLY — test/unit/raptor_pattern_equivalence_test.dart
    // verifies this stays true. A divergence here would let RAPTOR
    // board a different first trip than the row-by-row path would.
    final order = List.generate(_tripIds.length, (i) => i)
      ..sort((a, b) => _departures[a][0].compareTo(_departures[b][0]));
    return PrecomputedPattern(
      patternId: patternId,
      routeId: routeId,
      stopIds: stopIds,
      tripIds: [for (final i in order) _tripIds[i]],
      serviceIds: [for (final i in order) _serviceIds[i]],
      tripArrivalSeconds: [for (final i in order) _arrivals[i]],
      tripDepartureSeconds: [for (final i in order) _departures[i]],
    );
  }
}

/// Groups EVERY (trip, stop) row in [allRows] (expected to be the
/// WHOLE feed, unfiltered — see
/// `GtfsQueryService.getAllTimetableRowsForPatternPrecomputation`)
/// into patterns. Build-time mirror of `GtfsTimetableLoader.load()`'s
/// grouping step, extended to also carry each trip's `service_id`.
List<PrecomputedPattern> buildPrecomputedPatterns(List<Map<String, Object?>> allRows) {
  final byTrip = <String, List<Map<String, Object?>>>{};
  for (final row in allRows) {
    byTrip.putIfAbsent(row['trip_id'] as String, () => []).add(row);
  }

  final builders = <String, _PrecomputedPatternBuilder>{};
  for (final tripRows in byTrip.values) {
    if (tripRows.isEmpty) continue;
    final routeId = tripRows.first['route_id'] as String;
    final serviceId = tripRows.first['service_id'] as String;
    final stopIds = tripRows.map((r) => r['stop_id'] as String).toList(growable: false);
    final patternKey = '$routeId|${stopIds.join(',')}';

    final arrivals = Int32List(tripRows.length);
    final departures = Int32List(tripRows.length);
    for (int i = 0; i < tripRows.length; i++) {
      arrivals[i] = _hhmmssToSeconds(tripRows[i]['arrival_time'] as String);
      departures[i] = _hhmmssToSeconds(tripRows[i]['departure_time'] as String);
    }

    final builder = builders.putIfAbsent(patternKey, () => _PrecomputedPatternBuilder(patternKey, routeId, stopIds));
    builder.addTrip(tripRows.first['trip_id'] as String? ?? '', serviceId, arrivals, departures);
  }

  return [for (final b in builders.values) b.build()];
}

Uint8List _encodeSeconds(List<Int32List> perTrip, int numStops) {
  final flat = ByteData(perTrip.length * numStops * 4);
  for (int t = 0; t < perTrip.length; t++) {
    for (int s = 0; s < numStops; s++) {
      flat.setInt32((t * numStops + s) * 4, perTrip[t][s], Endian.little);
    }
  }
  return flat.buffer.asUint8List();
}

/// BUILD-TIME: encodes [patterns] and writes them into the
/// `raptor_patterns`/`raptor_pattern_schema` tables (already created
/// by `GtfsDatabase.createRaptorPatternSchema`) inside [db]. Replaces
/// any existing rows first, in one transaction — safe to call on a
/// fresh prepared-database build, which always starts from a clean
/// import (see `GtfsImportService`'s transactional drop-and-recreate).
Future<void> writePrecomputedPatterns(Database db, List<PrecomputedPattern> patterns) async {
  await db.transaction((txn) async {
    await txn.delete('raptor_patterns');
    await txn.delete('raptor_pattern_schema');
    final batch = txn.batch();
    for (final p in patterns) {
      batch.insert('raptor_patterns', {
        'pattern_id': p.patternId,
        'route_id': p.routeId,
        'num_stops': p.numStops,
        'num_trips': p.numTrips,
        'stop_ids': jsonEncode(p.stopIds),
        'trip_ids': jsonEncode(p.tripIds),
        'service_ids': jsonEncode(p.serviceIds),
        'arrival_seconds': _encodeSeconds(p.tripArrivalSeconds, p.numStops),
        'departure_seconds': _encodeSeconds(p.tripDepartureSeconds, p.numStops),
      });
    }
    await batch.commit(noResult: true);
    await txn.insert('raptor_pattern_schema', {
      'schema_version': GtfsDatabase.raptorPatternSchemaVersion,
      'pattern_count': patterns.length,
      'built_at': DateTime.now().toIso8601String(),
    });
  });
}

/// RUNTIME: reads the prepared `raptor_patterns` table (if present and
/// version-compatible) and reconstructs a full [GtfsTimetable],
/// filtering each pattern's trips down to [activeServiceIds] — the
/// SAME filtering `GtfsQueryService.getActiveServiceIds` already
/// determines, just applied in Dart against a small array instead of a
/// second SQL query. Trips stay in ascending-departure order after
/// filtering because removing elements from an already-sorted list
/// preserves the relative order of what remains.
///
/// Returns null if no prepared-pattern data was ever written (an
/// older prepared-database build, or the CSV-import fallback path,
/// neither of which create these tables) — callers must fall back to
/// the row-by-row path in that case, exactly like
/// `GtfsDatabase.installPreparedDatabaseIfNeeded`'s own
/// no-asset-bundled fallback.
///
/// Throws [RaptorPatternStoreException] if the tables EXIST but are
/// structurally invalid (schema version mismatch, declared-vs-actual
/// row count mismatch, malformed BLOB length) — this is NEVER silently
/// treated the same as "not present": a corrupted prepared table must
/// be reported, not silently downgraded to the slow path without a
/// trace.
Future<GtfsTimetable?> decodePreparedPatterns(GtfsQueryService queryService, Set<String> activeServiceIds) async {
  final schemaInfo = await queryService.getRaptorPatternSchemaInfo();
  if (schemaInfo == null) return null; // not shipped — caller falls back

  final schemaVersion = schemaInfo['schema_version'] as int?;
  final declaredCount = schemaInfo['pattern_count'] as int?;
  if (schemaVersion != GtfsDatabase.raptorPatternSchemaVersion) {
    throw RaptorPatternStoreException(
        'raptor_pattern_schema.schema_version=$schemaVersion does not match this build\'s expected '
        'version ${GtfsDatabase.raptorPatternSchemaVersion} — refusing to read a pattern encoding this '
        'build cannot safely interpret.');
  }

  final rows = await queryService.getRaptorPatternRows();
  if (declaredCount != null && rows.length != declaredCount) {
    throw RaptorPatternStoreException(
        'raptor_pattern_schema declares pattern_count=$declaredCount but raptor_patterns actually has '
        '${rows.length} rows — the prepared database is inconsistent/corrupted.');
  }

  final allStops = await queryService.getAllStops();
  final allStopsById = {for (final s in allStops) s.stopId: s};

  final patternsById = <String, GtfsPattern>{};
  final patternRefsByStop = <String, List<PatternStopRef>>{};

  for (final row in rows) {
    final patternId = row['pattern_id'] as String;
    final routeId = row['route_id'] as String;
    final numStops = row['num_stops'] as int;
    final numTripsAll = row['num_trips'] as int;
    final stopIds = (jsonDecode(row['stop_ids'] as String) as List).cast<String>();
    final tripIdsAll = (jsonDecode(row['trip_ids'] as String) as List).cast<String>();
    final serviceIdsAll = (jsonDecode(row['service_ids'] as String) as List).cast<String>();
    final arrivalBytes = row['arrival_seconds'] as Uint8List;
    final departureBytes = row['departure_seconds'] as Uint8List;

    if (stopIds.length != numStops || tripIdsAll.length != numTripsAll || serviceIdsAll.length != numTripsAll) {
      throw RaptorPatternStoreException(
          'pattern $patternId has inconsistent array lengths (stopIds=${stopIds.length}/$numStops, '
          'tripIds=${tripIdsAll.length}/$numTripsAll, serviceIds=${serviceIdsAll.length}/$numTripsAll) — '
          'corrupted prepared database.');
    }
    final expectedBytes = numTripsAll * numStops * 4;
    if (arrivalBytes.length != expectedBytes || departureBytes.length != expectedBytes) {
      throw RaptorPatternStoreException(
          'pattern $patternId BLOB length (arrival=${arrivalBytes.length}, departure=${departureBytes.length}) '
          'does not match numTrips*numStops*4=$expectedBytes — corrupted prepared database.');
    }

    final keptIndices = <int>[
      for (int i = 0; i < numTripsAll; i++)
        if (activeServiceIds.contains(serviceIdsAll[i])) i,
    ];
    // No trip on this pattern runs on the requested date — omit it
    // entirely, exactly matching what the row-by-row path would do
    // (no matching stop_times rows -> nothing in `byTrip` -> no
    // pattern built for it).
    if (keptIndices.isEmpty) continue;

    final arrivalFlat = ByteData.sublistView(arrivalBytes);
    final departureFlat = ByteData.sublistView(departureBytes);
    final tripArrivalSeconds = <Int32List>[];
    final tripDepartureSeconds = <Int32List>[];
    final tripIds = <String>[];
    for (final i in keptIndices) {
      final arr = Int32List(numStops);
      final dep = Int32List(numStops);
      for (int s = 0; s < numStops; s++) {
        arr[s] = arrivalFlat.getInt32((i * numStops + s) * 4, Endian.little);
        dep[s] = departureFlat.getInt32((i * numStops + s) * 4, Endian.little);
      }
      tripArrivalSeconds.add(arr);
      tripDepartureSeconds.add(dep);
      tripIds.add(tripIdsAll[i]);
    }

    final pattern = GtfsPattern(
      patternId: patternId,
      routeId: routeId,
      stopIds: stopIds,
      tripArrivalSeconds: tripArrivalSeconds,
      tripDepartureSeconds: tripDepartureSeconds,
      tripIds: tripIds,
    );
    patternsById[pattern.patternId] = pattern;
    for (int i = 0; i < pattern.stopIds.length; i++) {
      patternRefsByStop.putIfAbsent(pattern.stopIds[i], () => []).add(PatternStopRef(pattern, i));
    }
  }

  return GtfsTimetable(patternsById: patternsById, patternRefsByStop: patternRefsByStop, allStopsById: allStopsById);
}
