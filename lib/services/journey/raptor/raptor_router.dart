import '../../gtfs/gtfs_geo_utils.dart';
import 'gtfs_pattern.dart';
import 'gtfs_timetable.dart';
import 'stop_spatial_index.dart';

/// One way a stop was reached during a RAPTOR round: either boarding
/// a specific trip on a pattern, or a walking (footpath) transfer.
class RaptorLeg {
  final bool isWalking;
  final String? patternId;
  final int? tripIndex;
  final int? boardStopIndex;
  final int? alightStopIndex;
  final String fromStopId;
  final String toStopId;
  final int departureSeconds;
  final int arrivalSeconds;

  const RaptorLeg({
    required this.isWalking,
    required this.fromStopId,
    required this.toStopId,
    required this.departureSeconds,
    required this.arrivalSeconds,
    this.patternId,
    this.tripIndex,
    this.boardStopIndex,
    this.alightStopIndex,
  });
}

/// Result of one RAPTOR run capped at a specific number of rounds —
/// `bestArrivalByStop`/`lastLegByStop` describe the single best
/// (earliest-arrival) path found to each stop within that round cap.
/// `JourneyPlannerService` runs this multiple times at increasing
/// round caps (0, 1, 2, ...) to build a small set of alternatives
/// with different transfer counts — see that file's doc comment for
/// why, rather than a single run producing a full Pareto frontier
/// internally.
class RaptorResult {
  final Map<String, int> bestArrivalByStop;
  final Map<String, RaptorLeg> lastLegByStop;

  const RaptorResult({required this.bestArrivalByStop, required this.lastLegByStop});
}

/// RAPTOR (Round-bAsed Public Transit Optimized Router), per Delling,
/// Pajor & Werneck (2015) — chosen over Dijkstra-on-a-time-expanded-
/// graph or CSA (Connection Scan Algorithm) because it scans by
/// PATTERN (a handful of thousand, for this feed) rather than by
/// individual stop_time "connections" (1.36M rows): each round visits
/// every pattern touching a stop improved in the previous round
/// exactly once, tracking the earliest trip catchable as it walks the
/// pattern's stop sequence — this is the standard reason RAPTOR
/// outperforms connection-scan approaches on real-world GTFS-scale
/// networks, and it naturally expresses "up to k transfers" as "k+1
/// rounds," which is exactly this project's "configurable transfer
/// limit" requirement.
///
/// EACH ROUND = ONE ADDITIONAL VEHICLE BOARDING. Round 0 is the
/// walking-only seed (arrival at stops reachable on foot from the true
/// origin); round r's result is the best arrival using AT MOST r
/// vehicle boardings. A footpath (walking-transfer) relaxation runs
/// after each round's route scan, which is what enables transfers
/// between two DIFFERENT nearby stops — not just the same-stop
/// transfers the previous, non-RAPTOR planner was limited to — and,
/// because pattern scanning doesn't care about `route_type`, bus-bus,
/// bus-metro, metro-bus, and metro-metro transfers are all handled by
/// the exact same code path, with no mode-specific special-casing.
class RaptorRouter {
  final GtfsTimetable timetable;
  final int maxRounds;
  final double walkingRadiusMeters;
  final double walkingSpeedMetersPerSecond;
  final int minTransferSeconds;

  /// AUDIT FIX (Phase A — RAPTOR/footpath optimization): built ONCE per
  /// `RaptorRouter` instance (which itself is constructed once per
  /// `JourneyPlannerService.findJourneys` call and reused across every
  /// boarding-cap `run()` call in that search — see that class) and
  /// reused by every round's Step B. Replaces a brute-force scan of
  /// EVERY stop in the whole feed (previously `timetable.allStopsById.values`,
  /// ~5,580 stops) with a lookup into the handful of grid cells that
  /// could actually contain a stop within [walkingRadiusMeters] — see
  /// `StopSpatialIndex`'s own doc comment for the measured impact (Step
  /// B was ~98% of total RAPTOR time on a real device before this fix).
  late final StopSpatialIndex _footpathIndex =
      StopSpatialIndex.build(timetable.allStopsById.values, cellSizeMeters: walkingRadiusMeters);

  RaptorRouter({
    required this.timetable,
    this.maxRounds = 4,
    this.walkingRadiusMeters = 500,
    this.walkingSpeedMetersPerSecond = 1.2,
    this.minTransferSeconds = 120,
  });

  static const int _infinity = 1 << 30;

  /// TEMPORARY PERF-DIAGNOSTIC (route-search-latency investigation,
  /// Phase 3): per-stage numbers for the MOST RECENT [run] call — null
  /// until the first call completes. `footpathCandidateScans` is the
  /// key number for testing the "footpath relaxation is O(stops^2)"
  /// hypothesis. AUDIT NOTE (Phase A): now reflects the SPATIAL-INDEXED
  /// candidate count (post-fix), not the old brute-force full-feed
  /// scan count — see [perRoundDiagnostics] for the detailed per-round
  /// breakdown (attempted vs. successful relaxations, stops examined,
  /// trip lookups) requested for this investigation.
  Map<String, int>? lastRunDiagnosticsMs;

  /// AUDIT ADD (Phase A — RAPTOR/footpath optimization, profiling):
  /// one entry per round executed by the MOST RECENT [run] call —
  /// exactly the per-round counts requested for this investigation
  /// (stops examined, stops newly reached, patterns/trip-lookups
  /// examined, footpath relaxations attempted vs. successful) so the
  /// specific operation responsible for a round's cost can be read
  /// directly rather than inferred from aggregate totals.
  List<Map<String, Object>> lastRunPerRoundDiagnostics = [];

  /// Runs RAPTOR seeded from [originStopSeconds] (stopId -> arrival
  /// time in seconds-since-reference-midnight, reachable on foot from
  /// the true origin — round 0), capped at [roundCap] rounds (roundCap
  /// vehicle boardings, i.e. up to `roundCap` transfers after the
  /// first boarding is accounted for by the caller — see
  /// `JourneyPlannerService`).
  RaptorResult run({required Map<String, int> originStopSeconds, required int roundCap}) {
    final initStopwatch = Stopwatch()..start();
    final bestArrival = <String, int>{};
    final lastLeg = <String, RaptorLeg>{};
    var previousRoundArrival = <String, int>{};

    for (final entry in originStopSeconds.entries) {
      bestArrival[entry.key] = entry.value;
    }
    previousRoundArrival = Map.of(bestArrival);
    var markedStops = originStopSeconds.keys.toSet();
    final initMs = initStopwatch.elapsedMilliseconds;

    int roundsExecuted = 0;
    int patternsScannedTotal = 0;
    int footpathCandidateScans = 0;
    int stepAMs = 0;
    int stepBMs = 0;
    lastRunPerRoundDiagnostics = [];

    for (int round = 1; round <= roundCap; round++) {
      roundsExecuted++;
      final roundArrival = Map<String, int>.of(bestArrival);
      final roundLegs = <String, RaptorLeg>{};
      final newlyMarked = <String>{};
      final stopsExaminedThisRound = markedStops.length;
      int tripLookupsThisRound = 0;
      int stopsNewlyReachedStepA = 0;

      final stepAStopwatch = Stopwatch()..start();
      // --- Step A: scan every pattern touching a stop marked last round ---
      final patternsToScan = <GtfsPattern>{};
      for (final stopId in markedStops) {
        for (final ref in timetable.patternRefsByStop[stopId] ?? const <PatternStopRef>[]) {
          patternsToScan.add(ref.pattern);
        }
      }
      patternsScannedTotal += patternsToScan.length;

      for (final pattern in patternsToScan) {
        int boardedTripIndex = -1;
        int boardedAtStopIndex = -1;

        for (int stopIndex = 0; stopIndex < pattern.stopIds.length; stopIndex++) {
          final stopId = pattern.stopIds[stopIndex];

          // (1) If a trip is already boarded, does riding it to this
          // stop improve the stop's arrival time?
          if (boardedTripIndex != -1) {
            final arrival = pattern.tripArrivalSeconds[boardedTripIndex][stopIndex];
            if (arrival < (roundArrival[stopId] ?? _infinity)) {
              roundArrival[stopId] = arrival;
              roundLegs[stopId] = RaptorLeg(
                isWalking: false,
                patternId: pattern.patternId,
                tripIndex: boardedTripIndex,
                boardStopIndex: boardedAtStopIndex,
                alightStopIndex: stopIndex,
                fromStopId: pattern.stopIds[boardedAtStopIndex],
                toStopId: stopId,
                departureSeconds: pattern.tripDepartureSeconds[boardedTripIndex][boardedAtStopIndex],
                arrivalSeconds: arrival,
              );
              newlyMarked.add(stopId);
              stopsNewlyReachedStepA++;
            }
          }

          // (2) Can we board an earlier (or first) trip here, using
          // the PREVIOUS round's arrival at this stop? (Must use the
          // previous round's snapshot, not this round's in-progress
          // value, per RAPTOR's correctness rule — using this round's
          // still-updating value could let a trip "board before it
          // arrives.")
          final reachableAt = previousRoundArrival[stopId];
          if (reachableAt != null) {
            final earliestBoardable = reachableAt + minTransferSeconds;
            tripLookupsThisRound++;
            final candidateTripIndex = _earliestTripDepartingAtOrAfter(pattern, stopIndex, earliestBoardable);
            if (candidateTripIndex != -1) {
              final candidateDeparture = pattern.tripDepartureSeconds[candidateTripIndex][stopIndex];
              final currentDeparture =
                  boardedTripIndex == -1 ? _infinity : pattern.tripDepartureSeconds[boardedTripIndex][stopIndex];
              if (candidateDeparture < currentDeparture) {
                boardedTripIndex = candidateTripIndex;
                boardedAtStopIndex = stopIndex;
              }
            }
          }
        }
      }
      stepAMs += stepAStopwatch.elapsedMilliseconds;

      final stepBStopwatch = Stopwatch()..start();
      // --- Step B: footpath relaxation for every stop improved above ---
      //
      // AUDIT FIX (Phase A — RAPTOR/footpath optimization): previously
      // scanned EVERY stop in the whole feed (`timetable.allStopsById.values`,
      // ~5,580 stops) for every improved stop, computing a haversine
      // distance to each before discarding the ~99% outside
      // [walkingRadiusMeters]. Now queries [_footpathIndex] for just the
      // stops in the surrounding grid cells — still runs the exact same
      // haversine check on every CANDIDATE returned (correctness is
      // unchanged, only which stops count as candidates), but the
      // candidate set is now dozens, not thousands. See that class's
      // doc comment for the measured before/after impact and the
      // grid-neighborhood correctness argument.
      final improvedThisRound = Set<String>.of(newlyMarked);
      int footpathAttemptedThisRound = 0;
      int footpathSuccessfulThisRound = 0;
      for (final stopId in improvedThisRound) {
        final fromStop = timetable.allStopsById[stopId];
        if (fromStop == null) continue;
        final arrivalHere = roundArrival[stopId]!;
        final candidates = _footpathIndex.candidatesNear(fromStop.stopLat, fromStop.stopLon);
        footpathAttemptedThisRound += candidates.length;
        for (final other in candidates) {
          if (other.stopId == stopId) continue;
          final distance = haversineDistanceMeters(fromStop.stopLat, fromStop.stopLon, other.stopLat, other.stopLon);
          if (distance > walkingRadiusMeters) continue;
          final walkSeconds = (distance / walkingSpeedMetersPerSecond).ceil();
          final candidateArrival = arrivalHere + walkSeconds;
          if (candidateArrival < (roundArrival[other.stopId] ?? _infinity)) {
            roundArrival[other.stopId] = candidateArrival;
            roundLegs[other.stopId] = RaptorLeg(
              isWalking: true,
              fromStopId: stopId,
              toStopId: other.stopId,
              departureSeconds: arrivalHere,
              arrivalSeconds: candidateArrival,
            );
            newlyMarked.add(other.stopId);
            footpathSuccessfulThisRound++;
          }
        }
      }
      footpathCandidateScans += footpathAttemptedThisRound;
      stepBMs += stepBStopwatch.elapsedMilliseconds;

      lastRunPerRoundDiagnostics.add({
        'round': round,
        'stops_examined': stopsExaminedThisRound,
        'patterns_scanned': patternsToScan.length,
        'trip_lookups': tripLookupsThisRound,
        'stops_newly_reached_step_a': stopsNewlyReachedStepA,
        'footpath_relaxations_attempted': footpathAttemptedThisRound,
        'footpath_relaxations_successful': footpathSuccessfulThisRound,
        'stops_newly_reached_total': newlyMarked.length,
        'step_a_ms': stepAStopwatch.elapsedMilliseconds,
        'step_b_ms': stepBStopwatch.elapsedMilliseconds,
      });

      if (newlyMarked.isEmpty) break; // converged — no point running further rounds

      for (final stopId in newlyMarked) {
        bestArrival[stopId] = roundArrival[stopId]!;
        lastLeg[stopId] = roundLegs[stopId]!;
      }
      previousRoundArrival = Map.of(bestArrival);
      markedStops = newlyMarked;
    }

    lastRunDiagnosticsMs = {
      'raptor_init_ms': initMs,
      'raptor_rounds': roundsExecuted,
      'patterns_scanned': patternsScannedTotal,
      'step_a_ms': stepAMs,
      'footpath_candidate_scans': footpathCandidateScans,
      'step_b_ms': stepBMs,
      'raptor_ms': stepAMs + stepBMs,
    };
    // ignore: avoid_print
    print('[RaptorRouter] TIMING: roundCap=$roundCap raptor_init_ms=$initMs raptor_rounds=$roundsExecuted '
        'patterns_scanned=$patternsScannedTotal step_a_ms=$stepAMs '
        'footpath_candidate_scans=$footpathCandidateScans step_b_ms=$stepBMs');
    for (final r in lastRunPerRoundDiagnostics) {
      // ignore: avoid_print
      print('[RaptorRouter] ROUND-DIAG roundCap=$roundCap round=${r['round']} '
          'stops_examined=${r['stops_examined']} patterns_scanned=${r['patterns_scanned']} '
          'trip_lookups=${r['trip_lookups']} step_a_new=${r['stops_newly_reached_step_a']} '
          'footpath_attempted=${r['footpath_relaxations_attempted']} '
          'footpath_successful=${r['footpath_relaxations_successful']} '
          'newly_reached_total=${r['stops_newly_reached_total']} '
          'step_a_ms=${r['step_a_ms']} step_b_ms=${r['step_b_ms']}');
    }

    return RaptorResult(bestArrivalByStop: bestArrival, lastLegByStop: lastLeg);
  }

  /// Linear scan for the first trip (patterns typically have tens to a
  /// few hundred trips) departing [stopIndex] at or after
  /// [afterSeconds] — trips are pre-sorted ascending by departure time
  /// (see `GtfsTimetableLoader`), so this is a simple forward scan, not
  /// a binary search, kept that way for clarity at this trip-count
  /// scale.
  int _earliestTripDepartingAtOrAfter(GtfsPattern pattern, int stopIndex, int afterSeconds) {
    for (int i = 0; i < pattern.tripDepartureSeconds.length; i++) {
      if (pattern.tripDepartureSeconds[i][stopIndex] >= afterSeconds) return i;
    }
    return -1;
  }
}
