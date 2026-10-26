import 'dart:math';

import '../../models/gtfs/route.dart';
import '../../models/gtfs/stop.dart';
import '../../models/journey/journey.dart';
import '../../models/journey/journey_segment.dart';
import '../gtfs/gtfs_geo_utils.dart';
import '../gtfs/gtfs_query_service.dart';
import 'raptor/gtfs_timetable.dart';
import 'raptor/raptor_router.dart';

/// Production offline multimodal journey planner for the Chennai
/// transit network — REPLACES the earlier direct-trip/same-stop-
/// transfer-only implementation entirely.
///
/// ALGORITHM: RAPTOR (Round-bAsed Public Transit Optimized Router) —
/// see `raptor/raptor_router.dart`'s doc comment for why it was chosen
/// over CSA/time-expanded Dijkstra/time-dependent A* for this project.
///
/// WHAT CHANGED FROM THE OLD PLANNER:
/// - Footpath relaxation connects any two stops within the
///   configurable walking radius, at any round — transfers between
///   two DIFFERENT nearby stops now work, not just same-stop transfers.
/// - `maxTransfers` is a real, configurable parameter, not a hardcoded
///   0-or-1 choice.
/// - Bus->bus, bus->metro, metro->bus, metro->metro transfers are all
///   handled by the same pattern-scanning code — mode never gates
///   whether a transfer is considered, only how a leg is labeled.
///
/// OUT OF SCOPE HERE, DELIBERATELY: geocoding a destination name ("VIT
/// Chennai," "CMBT," a hospital name, ...) into coordinates is
/// `LocationService.getCoordinatesFromAddress`'s job, called upstream
/// in `NavigationScreen` before this service ever sees a destination.
/// This service is coordinate-only and destination-type-agnostic —
/// folding geocoding in here would duplicate logic that already exists.
///
/// METRO CAVEAT, CARRIED FORWARD UNCHANGED FROM STAGE 2A/2B: the
/// bundled Chennai feed's 3 CMRL metro routes fail `routes.txt` import
/// validation (a `route_type` field that doesn't parse as an integer —
/// a genuine source-data defect, not an importer bug). Metro segments
/// are fully implemented and will appear the moment that source data
/// is corrected; there is currently no valid metro route for this
/// engine to find.
class JourneyPlannerService {
  final GtfsQueryService queryService;
  late final GtfsTimetableCache _timetableCache;

  /// When true, every stage of the search prints a
  /// `[JourneyPlannerService]`-tagged line — nearby stops found,
  /// active services, timetable size, per-transfer-count results,
  /// final ranking, timings. Off by default (this runs on every
  /// destination selection; verbose-by-default would flood real
  /// usage logs).
  bool debugMode;

  JourneyPlannerService(this.queryService, {this.debugMode = false}) {
    _timetableCache = GtfsTimetableCache(queryService);
  }

  static const double _defaultWalkingRadiusMeters = 800;
  static const int _defaultMaxTransfers = 4;
  static const double _defaultWalkingSpeedMetersPerSecond = 1.2;
  static const int _candidateStopsPerEnd = 40;
  static const int _maxJourneysReturned = 5;

  /// AUDIT ADD (real-device validation phase — "Kumaran Kundram"
  /// investigation): the reduced boarding buffer used by the SECOND,
  /// "tight connection" RAPTOR pass in [findJourneys] — see that pass's
  /// own doc comment. Deliberately still nonzero: real time is needed
  /// to physically walk up to a stop and board, this just isn't the
  /// full standard [RaptorRouter.minTransferSeconds] (120s) comfort
  /// margin.
  static const int _tightConnectionMinTransferSeconds = 30;

  /// Set whenever [findJourneys] returns an empty list — the SPECIFIC
  /// reason, never a bare "no journeys." Callers (`NavigationScreen`)
  /// read this before falling back to walking-only navigation, per
  /// this phase's "never immediately fall back to walking without
  /// explanation" requirement.
  String? lastFailureReason;

  /// TEMPORARY PERF-DIAGNOSTIC (see this class's `_log`/`debugMode` for
  /// the existing verbose-trace mechanism this complements): per-stage
  /// wall-clock milliseconds for the MOST RECENT [findJourneys] call —
  /// null until the first call completes. Deliberately a plain
  /// `Map<String, int>`, not a bespoke class, so it's trivial to feed
  /// into `RuntimeMetricsCollector`/`EvaluationService` later or delete
  /// outright once the route-search-latency investigation is done; keys
  /// match the stages actually measured: nearbyStopsAndServiceIdsMs,
  /// gtfsTimetableMs, raptorRoutingMs (summed across every boarding-cap
  /// pass — see the loop below), routeMetadataMs, journeyAssemblyMs,
  /// totalMs.
  Map<String, int>? lastSearchTimingsMs;

  /// PHASE NEXT (safe timetable-loading caching investigation) — whether
  /// the MOST RECENT [findJourneys] call reused an already-warm
  /// timetable ([prewarmTimetableCache] or a prior same-day search) vs.
  /// paying the full SQL load itself. Null until the first call
  /// completes. Test-facing diagnostic, same spirit as
  /// [lastSearchTimingsMs].
  bool? get lastTimetableCacheHit => _timetableCache.lastWasCacheHit;

  /// PHASE NEXT (safe timetable-loading caching investigation): warms
  /// [_timetableCache] for TODAY in the background, independent of any
  /// origin/destination — `activeServiceIds` only ever depends on the
  /// date (see [findJourneys]'s own `getActiveServiceIds(referenceTime)`
  /// call), never on coordinates, so this is safe to run before the
  /// user has picked a destination at all.
  ///
  /// WHY THIS IS SAFE AND WHY IT'S NOT A RAPTOR REWRITE: a real device
  /// measurement (Phase G audit) found route search taking 8.52s, of
  /// which 6.78s was [GtfsTimetableCache]'s underlying SQL load — RAPTOR
  /// itself only took 1.65s. [GtfsTimetableCache.forDate] already
  /// de-duplicates by date (see its own doc comment); the ONLY thing
  /// missing was that nothing ever called it before the user's first
  /// real search, so that first search always paid the full SQL cost
  /// synchronously. Calling this once, fire-and-forget, right after GTFS
  /// import/open finishes (see `main.dart`) lets that same cost be paid
  /// during onboarding — while the user is answering voice-onboarding
  /// questions, seconds they're already spending regardless — instead of
  /// after they've asked to go somewhere. If a real search race-wins
  /// against this (calls [findJourneys] before this finishes), nothing
  /// breaks: [GtfsTimetableCache.forDate] has no lock, so both callers
  /// simply run the loader and the cache ends up holding whichever
  /// result finished last — same correctness as today, just usually
  /// faster. Errors here are deliberately swallowed (see call site) —
  /// this is a pure best-effort speed optimization, never a
  /// precondition for [findJourneys] to work correctly.
  Future<void> prewarmTimetableCache([DateTime? date]) async {
    final referenceTime = date ?? DateTime.now();
    final activeServiceIds = await queryService.getActiveServiceIds(referenceTime);
    if (activeServiceIds.isEmpty) {
      _log('prewarmTimetableCache: no active service_ids for ${_dateOnly(referenceTime)} — skipping load.');
      return;
    }
    await _timetableCache.forDate(referenceTime, activeServiceIds);
    _log('prewarmTimetableCache: complete for ${_dateOnly(referenceTime)}.');
  }

  Future<List<Journey>> findJourneys({
    required double originLat,
    required double originLon,
    required double destinationLat,
    required double destinationLon,
    DateTime? departureAfter,
    double walkingRadiusMeters = _defaultWalkingRadiusMeters,
    int maxTransfers = _defaultMaxTransfers,
    double walkingSpeedMetersPerSecond = _defaultWalkingSpeedMetersPerSecond,
    bool accessibilityPreferFewerTransfers = false,
  }) async {
    lastFailureReason = null;
    lastSearchTimingsMs = null;
    final overallStopwatch = Stopwatch()..start();
    final referenceTime = departureAfter ?? DateTime.now();
    _log('=== findJourneys: origin=($originLat,$originLon) destination=($destinationLat,$destinationLon) '
        'time=$referenceTime maxTransfers=$maxTransfers radius=${walkingRadiusMeters}m ===');

    // PERF FIX: these three reads are fully independent (none depends
    // on another's result) but were previously awaited one at a time —
    // pure sequential round-trip latency stacking for no reason. Same
    // three queries, same results; only the wall-clock order of
    // dispatch changes. The empty-result checks below still run in the
    // EXACT SAME precedence (origin, then destination, then active
    // service ids) so `lastFailureReason` and its message are
    // byte-identical to before for every failure case — only the
    // (rare) case where an origin AND a later check would both have
    // failed now does the harmless extra work of also having fetched
    // the later ones, same as it already did further down for
    // multi-check paths.
    final lookupStopwatch = Stopwatch()..start();
    final results = await Future.wait([
      queryService.getNearbyStops(
          latitude: originLat, longitude: originLon, radiusMeters: walkingRadiusMeters, limit: _candidateStopsPerEnd),
      queryService.getNearbyStops(
          latitude: destinationLat,
          longitude: destinationLon,
          radiusMeters: walkingRadiusMeters,
          limit: _candidateStopsPerEnd),
      queryService.getActiveServiceIds(referenceTime),
    ]);
    final originStops = results[0] as List<GtfsStop>;
    final destinationStops = results[1] as List<GtfsStop>;
    final activeServiceIds = results[2] as Set<String>;
    _log('Origin stops (${originStops.length}): ${originStops.map((s) => s.stopId).toList()}');
    _log('Destination stops (${destinationStops.length}): ${destinationStops.map((s) => s.stopId).toList()}');
    _log('Active service_ids for ${_dateOnly(referenceTime)}: $activeServiceIds');

    if (originStops.isEmpty) {
      lastFailureReason = 'No transit stops found within ${walkingRadiusMeters.round()}m of your starting location. '
          'The origin may be outside this feed\'s coverage area, or the walking radius may need to be increased.';
      _log('REJECTED: $lastFailureReason');
      _recordTimings(
        overallStopwatch: overallStopwatch,
        nearbyStopsAndServiceIdsMs: lookupStopwatch.elapsedMilliseconds,
        gtfsTimetableMs: 0,
        raptorRoutingMs: 0,
        routeMetadataMs: 0,
        journeyAssemblyMs: 0,
      );
      return [];
    }
    if (destinationStops.isEmpty) {
      lastFailureReason = 'No transit stops found within ${walkingRadiusMeters.round()}m of your destination. '
          'The destination may be outside this feed\'s coverage area.';
      _log('REJECTED: $lastFailureReason');
      _recordTimings(
        overallStopwatch: overallStopwatch,
        nearbyStopsAndServiceIdsMs: lookupStopwatch.elapsedMilliseconds,
        gtfsTimetableMs: 0,
        raptorRoutingMs: 0,
        routeMetadataMs: 0,
        journeyAssemblyMs: 0,
      );
      return [];
    }
    if (activeServiceIds.isEmpty) {
      lastFailureReason = 'No GTFS service is active on ${_dateOnly(referenceTime)} — check calendar.txt/'
          'calendar_dates.txt import and date ranges for this feed.';
      _log('REJECTED: $lastFailureReason');
      _recordTimings(
        overallStopwatch: overallStopwatch,
        nearbyStopsAndServiceIdsMs: lookupStopwatch.elapsedMilliseconds,
        gtfsTimetableMs: 0,
        raptorRoutingMs: 0,
        routeMetadataMs: 0,
        journeyAssemblyMs: 0,
      );
      return [];
    }
    final nearbyStopsAndServiceIdsMs = lookupStopwatch.elapsedMilliseconds;

    final timetableStopwatch = Stopwatch()..start();
    final timetable = await _timetableCache.forDate(referenceTime, activeServiceIds);
    final gtfsTimetableMs = timetableStopwatch.elapsedMilliseconds;
    final timetableCacheHit = _timetableCache.lastWasCacheHit;
    final loadDiag = _timetableCache.lastLoadDiagnosticsMs;
    final sqlRows = loadDiag?['sqlRows'] ?? 0;
    final sqlMs = loadDiag?['sqlMs'] ?? 0;
    final patternBuildMs = loadDiag?['patternBuildMs'] ?? 0;
    final patternsCount = loadDiag?['patterns'] ?? 0;
    _log('Timetable ready: ${timetable.patternsById.length} patterns, ${timetable.allStopsById.length} stops '
        '(${gtfsTimetableMs}ms)');

    final referenceSeconds = _clockToSeconds(referenceTime);
    final originStopSeconds = <String, int>{};
    for (final stop in originStops) {
      final distance = haversineDistanceMeters(originLat, originLon, stop.stopLat, stop.stopLon);
      final walkSeconds = (distance / walkingSpeedMetersPerSecond).ceil();
      originStopSeconds[stop.stopId] = referenceSeconds + walkSeconds;
    }

    final destStopById = {for (final s in destinationStops) s.stopId: s};
    final router = RaptorRouter(
      timetable: timetable,
      walkingRadiusMeters: walkingRadiusMeters,
      walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond,
    );

    // AUDIT ADD (real-device validation phase — "Kumaran Kundram"
    // investigation): a SECOND router using a much smaller boarding
    // buffer than the standard, safe [RaptorRouter.minTransferSeconds]
    // default (120s). Reproduced live: from a real position, the
    // NEAREST stop (Kumaran Kundram, ~217m) has a single-bus route
    // (M18G) straight to the destination — genuinely faster and less
    // walking than the app's actual answer (a longer walk to a
    // farther, through-route stop) — but M18G only runs HOURLY, and the
    // standard 120s safety buffer meant the walk-arrival at Kumaran
    // Kundram landed too close to that specific departure for the main
    // search to ever consider boarding it, so the faster option was
    // silently discarded rather than offered with a warning. This
    // second pass exists ONLY to surface genuinely faster alternatives
    // that require a tighter-than-usual connection — see
    // `Journey.hasTightConnection` for how a caller tells such a result
    // apart from the app's normal, comfortable-buffer answer.
    // [_tightConnectionMinTransferSeconds] is intentionally still
    // nonzero (not 0) — a rider needs SOME time to actually walk up to
    // a stop and physically board, not teleport.
    final optimisticRouter = RaptorRouter(
      timetable: timetable,
      walkingRadiusMeters: walkingRadiusMeters,
      walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond,
      minTransferSeconds: _tightConnectionMinTransferSeconds,
    );

    // Phase 1: run RAPTOR at increasing boarding caps, collect raw leg
    // chains only (no route labels yet — see phase 2 for why batching
    // the route lookup separately is worth the extra pass). Run TWICE
    // — once with the standard safety buffer, once with the tight one
    // above — and pool both passes' chains together; deduplication and
    // ranking below already handle the (usual) case where both passes
    // agree, and only add a visible second candidate when the tight
    // pass genuinely finds something the safe pass couldn't.
    //
    // TEMPORARY PERF-DIAGNOSTIC NOTE (route-search-latency
    // investigation, Phase 3): each iteration below calls
    // `router.run()` FRESH from round 1 — round 1's work (and round
    // 2's, for every cap beyond the first, etc.) is REDONE from
    // scratch by every higher boarding cap, not reused incrementally.
    // The aggregated diagnostics below (summed across every call this
    // loop makes) reflect that real, repeated cost as it actually
    // happens today — not a hypothetical single-pass cost. This is an
    // observation for the investigation, not a change: no loop
    // structure or algorithm logic below is modified.
    final safePass = _collectRawChains(
      router: router,
      originStopSeconds: originStopSeconds,
      destStopById: destStopById,
      maxTransfers: maxTransfers,
      destinationLat: destinationLat,
      destinationLon: destinationLon,
      walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond,
      passLabel: 'safe',
    );
    final tightPass = _collectRawChains(
      router: optimisticRouter,
      originStopSeconds: originStopSeconds,
      destStopById: destStopById,
      maxTransfers: maxTransfers,
      destinationLat: destinationLat,
      destinationLon: destinationLon,
      walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond,
      passLabel: 'tight',
    );
    final rawChains = [...safePass.chains, ...tightPass.chains];
    final rejectedCaps = safePass.rejectedCaps;
    final raptorRoutingMs = safePass.raptorRoutingMs + tightPass.raptorRoutingMs;
    final raptorRoundsTotal = safePass.raptorRoundsTotal + tightPass.raptorRoundsTotal;
    final patternsScannedTotal = safePass.patternsScannedTotal + tightPass.patternsScannedTotal;
    final footpathCandidateScansTotal = safePass.footpathCandidateScansTotal + tightPass.footpathCandidateScansTotal;
    final raptorInitMsTotal = safePass.raptorInitMsTotal + tightPass.raptorInitMsTotal;

    if (rawChains.isEmpty) {
      lastFailureReason = 'No route was found connecting your origin\'s nearby stops to your destination\'s '
          'nearby stops within $maxTransfers transfer(s), even though both ends have transit coverage. '
          'This GTFS feed\'s network may genuinely not connect these two areas within that transfer budget — '
          'try increasing the transfer limit or the walking radius.';
      _log('REJECTED: $lastFailureReason (checked boarding caps 1..${maxTransfers + 1}, all empty: $rejectedCaps)');
      _recordTimings(
        overallStopwatch: overallStopwatch,
        nearbyStopsAndServiceIdsMs: nearbyStopsAndServiceIdsMs,
        gtfsTimetableMs: gtfsTimetableMs,
        raptorRoutingMs: raptorRoutingMs,
        routeMetadataMs: 0,
        journeyAssemblyMs: 0,
        timetableCacheHit: timetableCacheHit,
        sqlRows: sqlRows,
        sqlMs: sqlMs,
        patternBuildMs: patternBuildMs,
        patterns: patternsCount,
        raptorInitMs: raptorInitMsTotal,
        raptorRounds: raptorRoundsTotal,
        patternsScanned: patternsScannedTotal,
        footpathCandidateScans: footpathCandidateScansTotal,
      );
      return [];
    }

    // Phase 2: batch-fetch route metadata for every route actually
    // used, ONE query, instead of one query per leg per chain.
    final routeMetadataStopwatch = Stopwatch()..start();
    final routeIds = <String>{
      for (final chain in rawChains)
        for (final leg in chain)
          if (!leg.isWalking) leg.patternId!.split('|').first,
    };
    final routesById = await queryService.getRoutesByIds(routeIds);
    final routeMetadataMs = routeMetadataStopwatch.elapsedMilliseconds;

    // Phase 3: build Journey/JourneySegment objects from the raw
    // chains now that route labels are available.
    final journeyAssemblyStopwatch = Stopwatch()..start();
    final candidates = <Journey>[];
    for (final chain in rawChains) {
      final journey = _buildJourneyFromLegChain(
        legs: chain,
        timetable: timetable,
        routesById: routesById,
        originLat: originLat,
        originLon: originLon,
        destinationLat: destinationLat,
        destinationLon: destinationLon,
        referenceTime: referenceTime,
        walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond,
      );
      if (journey != null) candidates.add(journey);
    }

    if (candidates.isEmpty) {
      lastFailureReason = 'Paths were found by the routing algorithm, but journey reconstruction failed for all '
          'of them — this indicates a bug in segment-building, not a genuine absence of transit connectivity.';
      _log('REJECTED: $lastFailureReason');
      _recordTimings(
        overallStopwatch: overallStopwatch,
        nearbyStopsAndServiceIdsMs: nearbyStopsAndServiceIdsMs,
        gtfsTimetableMs: gtfsTimetableMs,
        raptorRoutingMs: raptorRoutingMs,
        routeMetadataMs: routeMetadataMs,
        journeyAssemblyMs: journeyAssemblyStopwatch.elapsedMilliseconds,
        timetableCacheHit: timetableCacheHit,
        sqlRows: sqlRows,
        sqlMs: sqlMs,
        patternBuildMs: patternBuildMs,
        patterns: patternsCount,
        raptorInitMs: raptorInitMsTotal,
        raptorRounds: raptorRoundsTotal,
        patternsScanned: patternsScannedTotal,
        footpathCandidateScans: footpathCandidateScansTotal,
      );
      return [];
    }

    final deduped = _dedupeByTripSequence(candidates);

    // AUDIT FIX (real-device validation phase — "Kumaran Kundram"
    // investigation): a journey found ONLY by the "tight connection"
    // pass (see `findJourneys`'s `tightPass`) can be genuinely faster
    // or involve less walking than every safe-pass journey — that's
    // the whole point of running it — but it must never be allowed to
    // outrank a safe journey in the final order just because it wins on
    // raw speed. `Journey.hasTightConnection` reliably tells the two
    // apart post-hoc (a safe-pass journey can never have a sub-120s
    // wait segment, by construction — see that getter's doc comment),
    // so safe and tight-connection candidates are ranked SEPARATELY
    // here and concatenated — safe first, always — rather than
    // competing on one shared weighted score where `_rankJourneys`'
    // travel-time weight could let speed alone promote a risky option
    // to the top.
    final safeCandidates = deduped.where((j) => !j.hasTightConnection).toList();
    final tightCandidates = deduped.where((j) => j.hasTightConnection).toList();
    final rankedSafe = _rankJourneys(safeCandidates, accessibilityPreferFewerTransfers: accessibilityPreferFewerTransfers);
    final rankedTight =
        _rankJourneys(tightCandidates, accessibilityPreferFewerTransfers: accessibilityPreferFewerTransfers);
    final ranked = [...rankedSafe, ...rankedTight];
    final journeyAssemblyMs = journeyAssemblyStopwatch.elapsedMilliseconds;

    _log('Final ranking (${ranked.length} journeys, ${rankedTight.length} tight-connection, '
        'total ${overallStopwatch.elapsedMilliseconds}ms):');
    for (final j in ranked) {
      _log('  arrival=${j.arrivalTime} travel=${j.totalTravelTime.inMinutes}min transfers=${j.transferCount} '
          'walk=${j.totalWalkingDistanceMeters.round()}m tight=${j.hasTightConnection} '
          'routes=${[...j.busRouteLabels, ...j.metroLineLabels]}');
    }

    _recordTimings(
      overallStopwatch: overallStopwatch,
      nearbyStopsAndServiceIdsMs: nearbyStopsAndServiceIdsMs,
      gtfsTimetableMs: gtfsTimetableMs,
      raptorRoutingMs: raptorRoutingMs,
      routeMetadataMs: routeMetadataMs,
      journeyAssemblyMs: journeyAssemblyMs,
      timetableCacheHit: timetableCacheHit,
      sqlRows: sqlRows,
      sqlMs: sqlMs,
      patternBuildMs: patternBuildMs,
      patterns: patternsCount,
      raptorInitMs: raptorInitMsTotal,
      raptorRounds: raptorRoundsTotal,
      patternsScanned: patternsScannedTotal,
      footpathCandidateScans: footpathCandidateScansTotal,
      journeysProduced: ranked.length,
    );
    return ranked.take(_maxJourneysReturned).toList();
  }

  /// TEMPORARY PERF-DIAGNOSTIC helper — see [lastSearchTimingsMs]'s doc
  /// comment. Also prints the exact stage-by-stage breakdown requested
  /// for the current route-search-latency investigation; this print is
  /// NOT gated behind [debugMode] (unlike [_log]'s verbose per-stage
  /// trace) so it's visible on a normal run without flipping a flag —
  /// delete this whole method (and its call sites above) once the
  /// investigation is done, or fold it into
  /// `RuntimeMetricsCollector`/`EvaluationService` if it's worth
  /// keeping permanently.
  void _recordTimings({
    required Stopwatch overallStopwatch,
    required int nearbyStopsAndServiceIdsMs,
    required int gtfsTimetableMs,
    required int raptorRoutingMs,
    required int routeMetadataMs,
    required int journeyAssemblyMs,
    bool? timetableCacheHit,
    int sqlRows = 0,
    int sqlMs = 0,
    int patternBuildMs = 0,
    int patterns = 0,
    int raptorInitMs = 0,
    int raptorRounds = 0,
    int patternsScanned = 0,
    int footpathCandidateScans = 0,
    int journeysProduced = 0,
  }) {
    final totalMs = overallStopwatch.elapsedMilliseconds;
    lastSearchTimingsMs = {
      'nearbyStopsAndServiceIdsMs': nearbyStopsAndServiceIdsMs,
      'gtfsTimetableMs': gtfsTimetableMs,
      'raptorRoutingMs': raptorRoutingMs,
      'routeMetadataMs': routeMetadataMs,
      'journeyAssemblyMs': journeyAssemblyMs,
      'sqlRows': sqlRows,
      'sqlMs': sqlMs,
      'patternBuildMs': patternBuildMs,
      'patterns': patterns,
      'raptorInitMs': raptorInitMs,
      'raptorRounds': raptorRounds,
      'patternsScanned': patternsScanned,
      'footpathCandidateScans': footpathCandidateScans,
      'journeysProduced': journeysProduced,
      'totalMs': totalMs,
    };
    // TEMPORARY PERF-DIAGNOSTIC (route-search-latency investigation,
    // Phase 3) — single structured summary line covering every stage
    // requested: cache hit/miss, SQL read, Dart-side pattern
    // construction, RAPTOR (init/rounds/pattern-scan/footpath-scan
    // counts), route metadata, journey assembly, and the overall
    // total. Deliberately ONE line per search (not per-row/per-stop)
    // — cheap enough to leave on unconditionally.
    // ignore: avoid_print
    print('[JourneyPlannerService] TIMING: '
        'timetable_cache=${timetableCacheHit == null ? 'n/a' : (timetableCacheHit ? 'hit' : 'miss')} '
        'sql_rows=$sqlRows sql_ms=$sqlMs pattern_build_ms=$patternBuildMs patterns=$patterns '
        'raptor_init_ms=$raptorInitMs raptor_rounds=$raptorRounds patterns_scanned=$patternsScanned '
        'footpath_candidate_scans=$footpathCandidateScans raptor_ms=$raptorRoutingMs '
        'nearby_lookup_ms=$nearbyStopsAndServiceIdsMs route_metadata_ms=$routeMetadataMs '
        'assembly_ms=$journeyAssemblyMs journeys=$journeysProduced total_ms=$totalMs');
  }

  // ---------------------------------------------------------------------
  // Phase 1 helper: run one router across every boarding cap, collecting
  // the raw leg chains it finds. Factored out so `findJourneys` can run
  // it twice — once with the standard safety buffer, once with the
  // "tight connection" buffer — without duplicating this logic. See the
  // "tight connection" pass's own doc comment in `findJourneys` for why
  // a second pass exists at all.
  // ---------------------------------------------------------------------

  ({
    List<List<RaptorLeg>> chains,
    List<int> rejectedCaps,
    int raptorRoutingMs,
    int raptorRoundsTotal,
    int patternsScannedTotal,
    int footpathCandidateScansTotal,
    int raptorInitMsTotal,
  }) _collectRawChains({
    required RaptorRouter router,
    required Map<String, int> originStopSeconds,
    required Map<String, GtfsStop> destStopById,
    required int maxTransfers,
    required double destinationLat,
    required double destinationLon,
    required double walkingSpeedMetersPerSecond,
    required String passLabel,
  }) {
    final rawChains = <List<RaptorLeg>>[];
    final rejectedCaps = <int>[];
    var raptorRoutingMs = 0;
    var raptorRoundsTotal = 0;
    var patternsScannedTotal = 0;
    var footpathCandidateScansTotal = 0;
    var raptorInitMsTotal = 0;

    for (int boardingCap = 1; boardingCap <= maxTransfers + 1; boardingCap++) {
      final raptorStopwatch = Stopwatch()..start();
      final result = router.run(originStopSeconds: originStopSeconds, roundCap: boardingCap);
      raptorRoutingMs += raptorStopwatch.elapsedMilliseconds;
      final runDiag = router.lastRunDiagnosticsMs;
      if (runDiag != null) {
        raptorRoundsTotal += runDiag['raptor_rounds'] ?? 0;
        patternsScannedTotal += runDiag['patterns_scanned'] ?? 0;
        footpathCandidateScansTotal += runDiag['footpath_candidate_scans'] ?? 0;
        raptorInitMsTotal += runDiag['raptor_init_ms'] ?? 0;
      }

      // AUDIT FIX (real-device validation phase — "is the transit it is
      // showing right?" investigation, reproduced on-device for
      // Chromepet -> "Tambaram West"): this used to pick whichever
      // destination-adjacent stop the transit network reached SOONEST
      // by raw arrival time alone, with no regard for how much walking
      // that stop still needed afterward to reach the real destination
      // coordinate. Confirmed against the actual bundled feed: bus
      // route 24034 (MAA1 R) stops at "Kadaperi" then, 6 real scheduled
      // minutes later on the SAME trip, at "Tambaram West Bus Stand"
      // itself (stop 10972, which IS the resolved destination
      // coordinate here) — Kadaperi is reached earlier in raw transit
      // terms, so the old comparison always chose it, then appended an
      // ~11-minute, ~800m walk to finish the trip. Riding 6 more
      // minutes to the exact door beats an 11-minute walk to get there,
      // but that was never considered because the walk cost wasn't part
      // of the comparison at all.
      //
      // FIX: score every reached destination-adjacent stop by its
      // PROJECTED FINAL arrival — transit arrival at that stop PLUS the
      // walk time from that stop to the real destination coordinate,
      // using the exact same distance/speed formula the final-walk
      // segment itself uses below (see `_buildJourneyFromLegChain`'s
      // `finalWalkDistance`/`finalWalkDuration`) — so the comparison
      // here matches what the assembled journey will actually cost the
      // user door-to-door, not just door-to-nearest-transit-stop.
      String? bestDestStopId;
      int bestProjectedFinalArrival = 1 << 30;
      for (final stopId in destStopById.keys) {
        final arrival = result.bestArrivalByStop[stopId];
        if (arrival == null) continue;
        final stop = destStopById[stopId]!;
        final finalWalkDistance = haversineDistanceMeters(stop.stopLat, stop.stopLon, destinationLat, destinationLon);
        final finalWalkSeconds = (finalWalkDistance / walkingSpeedMetersPerSecond).ceil();
        final projectedFinalArrival = arrival + finalWalkSeconds;
        if (projectedFinalArrival < bestProjectedFinalArrival) {
          bestProjectedFinalArrival = projectedFinalArrival;
          bestDestStopId = stopId;
        }
      }

      if (bestDestStopId == null) {
        rejectedCaps.add(boardingCap);
        _log('[$passLabel] boardingCap=$boardingCap: no destination stop reached '
            '(${raptorStopwatch.elapsedMilliseconds}ms)');
        continue;
      }

      final chain = _backtrackLegChain(result, bestDestStopId);
      if (chain == null) {
        _log('[$passLabel] boardingCap=$boardingCap: best-arrival stop found but backtracking hit a cycle — discarded.');
        continue;
      }
      _log('[$passLabel] boardingCap=$boardingCap: path found, ${chain.length} leg(s) '
          '(${raptorStopwatch.elapsedMilliseconds}ms)');
      rawChains.add(chain);
    }

    return (
      chains: rawChains,
      rejectedCaps: rejectedCaps,
      raptorRoutingMs: raptorRoutingMs,
      raptorRoundsTotal: raptorRoundsTotal,
      patternsScannedTotal: patternsScannedTotal,
      footpathCandidateScansTotal: footpathCandidateScansTotal,
      raptorInitMsTotal: raptorInitMsTotal,
    );
  }

  // ---------------------------------------------------------------------
  // Phase 1 helper: backtrack RaptorLeg chain from destination to an
  // origin-seed stop (a stop with no recorded incoming leg).
  // ---------------------------------------------------------------------

  List<RaptorLeg>? _backtrackLegChain(RaptorResult result, String destStopId) {
    final legsBackward = <RaptorLeg>[];
    var currentStopId = destStopId;
    final visited = <String>{};

    while (result.lastLegByStop.containsKey(currentStopId)) {
      if (!visited.add(currentStopId)) return null; // cycle guard — should be unreachable given strictly-improving arrival times, but never trust that blindly during reconstruction
      final leg = result.lastLegByStop[currentStopId]!;
      legsBackward.add(leg);
      currentStopId = leg.fromStopId;
    }
    return legsBackward.reversed.toList();
  }

  // ---------------------------------------------------------------------
  // Phase 3 helper: raw leg chain -> Journey/JourneySegment.
  // ---------------------------------------------------------------------

  Journey? _buildJourneyFromLegChain({
    required List<RaptorLeg> legs,
    required GtfsTimetable timetable,
    required Map<String, GtfsRoute> routesById,
    required double originLat,
    required double originLon,
    required double destinationLat,
    required double destinationLon,
    required DateTime referenceTime,
    required double walkingSpeedMetersPerSecond,
  }) {
    if (legs.isEmpty) return null;

    final firstStop = timetable.allStopsById[legs.first.fromStopId];
    if (firstStop == null) return null;

    final segments = <JourneySegment>[];

    final initialWalkDistance = haversineDistanceMeters(originLat, originLon, firstStop.stopLat, firstStop.stopLon);
    final initialWalkDuration = Duration(seconds: (initialWalkDistance / walkingSpeedMetersPerSecond).ceil());
    segments.add(JourneySegment(
      type: JourneySegmentType.walking,
      description: 'Walk to ${firstStop.stopName}',
      duration: initialWalkDuration,
      toStopName: firstStop.stopName,
      walkingDistanceMeters: initialWalkDistance,
      departureTime: referenceTime,
      arrivalTime: referenceTime.add(initialWalkDuration),
      toLat: firstStop.stopLat,
      toLon: firstStop.stopLon,
    ));

    int transferCount = 0;
    for (int i = 0; i < legs.length; i++) {
      final leg = legs[i];
      final fromStop = timetable.allStopsById[leg.fromStopId];
      final toStop = timetable.allStopsById[leg.toStopId];
      if (fromStop == null || toStop == null) return null;

      final departureDateTime = _secondsToDateTime(referenceTime, leg.departureSeconds);
      final previousArrival = segments.last.arrivalTime;

      // A meaningful wait/transfer gap between the previous segment's
      // arrival and this leg's departure is shown as its own segment
      // — keeps displayed durations honest (they sum to roughly the
      // total travel time) instead of hiding wait time inside the
      // next transit segment.
      if (previousArrival != null && departureDateTime.difference(previousArrival).inSeconds > 60) {
        final isFirstLeg = i == 0;
        segments.add(JourneySegment(
          type: JourneySegmentType.transfer,
          description: isFirstLeg ? 'Wait at ${fromStop.stopName}' : 'Transfer at ${fromStop.stopName}',
          duration: departureDateTime.difference(previousArrival),
          fromStopName: fromStop.stopName,
          toStopName: fromStop.stopName,
          departureTime: previousArrival,
          arrivalTime: departureDateTime,
          // No walkingDistanceMeters (this is a time-based WAIT at the
          // SAME stop, not a physical walk) — toLat/toLon still set
          // for consistency, but a zero-distance "route" isn't
          // meaningful; TransitJourneyGuideScreen uses the absence of
          // walkingDistanceMeters to skip route-fetching for this
          // specific case and just wait instead.
          toLat: fromStop.stopLat,
          toLon: fromStop.stopLon,
          isInitialWait: isFirstLeg,
        ));
        if (!isFirstLeg) transferCount++;
      } else if (i > 0) {
        transferCount++;
      }

      if (leg.isWalking) {
        final distance = haversineDistanceMeters(fromStop.stopLat, fromStop.stopLon, toStop.stopLat, toStop.stopLon);
        segments.add(JourneySegment(
          type: JourneySegmentType.transfer,
          description: 'Walk to ${toStop.stopName} to transfer',
          duration: Duration(seconds: leg.arrivalSeconds - leg.departureSeconds),
          fromStopName: fromStop.stopName,
          toStopName: toStop.stopName,
          walkingDistanceMeters: distance,
          departureTime: departureDateTime,
          arrivalTime: _secondsToDateTime(referenceTime, leg.arrivalSeconds),
          toLat: toStop.stopLat,
          toLon: toStop.stopLon,
        ));
      } else {
        final routeId = leg.patternId!.split('|').first;
        final route = routesById[routeId];
        final pattern = timetable.patternsById[leg.patternId];
        final actualTripId = (pattern != null && leg.tripIndex != null && leg.tripIndex! < pattern.tripIds.length)
            ? pattern.tripIds[leg.tripIndex!]
            : routeId; // fallback should be unreachable — patternId/tripIndex always come from a RaptorLeg this router itself produced
        // AUDIT FIX: route_type 1 = Subway/Metro, 2 = Rail (suburban
        // train), anything else (including the common 3 = Bus, and an
        // absent route) defaults to bus — see JourneySegmentType's doc
        // comment for why these must stay distinct rather than
        // collapsing "not a bus" into a single "metro" bucket.
        final segmentType = switch (route?.routeType) {
          1 => JourneySegmentType.metro,
          2 => JourneySegmentType.train,
          _ => JourneySegmentType.bus,
        };
        final modeLabel = switch (segmentType) {
          JourneySegmentType.metro => 'Metro',
          JourneySegmentType.train => 'Train',
          _ => 'Bus',
        };
        final routeLabel = route?.routeShortName ?? route?.routeLongName ?? routeId;

        // AUDIT ADD (transit state machine — BLOCKER 6): the ordered
        // stop sequence for JUST this segment (boarding through
        // alighting, inclusive) — a sub-list of the matched pattern's
        // own full stopIds, using the SAME leg.fromStopId/toStopId
        // this segment's description/labels already use. Empty (not
        // an error) if the pattern is somehow unavailable or the stop
        // IDs aren't found in it — a caller must treat an empty list
        // as "no automatic progress tracking possible for this leg,"
        // never fabricate a sequence.
        var orderedStops = <TransitStopWaypoint>[];
        if (pattern != null) {
          final fromIndex = pattern.stopIds.indexOf(leg.fromStopId);
          final toIndex = pattern.stopIds.indexOf(leg.toStopId);
          if (fromIndex != -1 && toIndex != -1 && toIndex >= fromIndex) {
            orderedStops = [
              for (int idx = fromIndex; idx <= toIndex; idx++)
                if (timetable.allStopsById[pattern.stopIds[idx]] != null)
                  TransitStopWaypoint(
                    stopId: pattern.stopIds[idx],
                    stopName: timetable.allStopsById[pattern.stopIds[idx]]!.stopName,
                    stopLat: timetable.allStopsById[pattern.stopIds[idx]]!.stopLat,
                    stopLon: timetable.allStopsById[pattern.stopIds[idx]]!.stopLon,
                    sequenceIndex: idx - fromIndex,
                  ),
            ];
          }
        }

        segments.add(JourneySegment(
          type: segmentType,
          description: 'Board $modeLabel $routeLabel towards ${route?.routeLongName ?? toStop.stopName}',
          duration: Duration(seconds: leg.arrivalSeconds - leg.departureSeconds),
          fromStopName: fromStop.stopName,
          toStopName: toStop.stopName,
          routeShortName: routeLabel,
          routeLongName: route?.routeLongName,
          tripId: actualTripId,
          routeId: routeId,
          boardingStopId: leg.fromStopId,
          alightingStopId: leg.toStopId,
          orderedStops: orderedStops,
          departureTime: departureDateTime,
          arrivalTime: _secondsToDateTime(referenceTime, leg.arrivalSeconds),
        ));
      }
    }

    final lastStop = timetable.allStopsById[legs.last.toStopId];
    if (lastStop == null) return null;
    final finalWalkDistance = haversineDistanceMeters(lastStop.stopLat, lastStop.stopLon, destinationLat, destinationLon);
    final finalWalkDuration = Duration(seconds: (finalWalkDistance / walkingSpeedMetersPerSecond).ceil());
    final lastArrival = segments.last.arrivalTime ?? referenceTime;
    final finalArrival = lastArrival.add(finalWalkDuration);
    segments.add(JourneySegment(
      type: JourneySegmentType.walking,
      description: 'Walk to your destination',
      duration: finalWalkDuration,
      fromStopName: lastStop.stopName,
      walkingDistanceMeters: finalWalkDistance,
      departureTime: lastArrival,
      arrivalTime: finalArrival,
      toLat: destinationLat,
      toLon: destinationLon,
    ));

    final totalWalking =
        segments.where((s) => s.walkingDistanceMeters != null).fold(0.0, (sum, s) => sum + s.walkingDistanceMeters!);

    return Journey(
      segments: segments,
      departureTime: referenceTime,
      arrivalTime: finalArrival,
      totalTravelTime: finalArrival.difference(referenceTime),
      totalWalkingDistanceMeters: totalWalking,
      transferCount: transferCount,
    );
  }

  // ---------------------------------------------------------------------
  // Dedupe + ranking
  // ---------------------------------------------------------------------

  /// Different boarding caps can converge on the same actual journey
  /// (a higher cap finding no NEW path just re-reports the same one) —
  /// deduped by the ordered sequence of route_ids actually ridden,
  /// keeping the first (lowest-transfer-count) occurrence.
  List<Journey> _dedupeByTripSequence(List<Journey> journeys) {
    final seen = <String>{};
    final deduped = <Journey>[];
    for (final j in journeys) {
      final signature = j.segments
          .where((s) =>
              s.type == JourneySegmentType.bus ||
              s.type == JourneySegmentType.metro ||
              s.type == JourneySegmentType.train)
          .map((s) => s.tripId ?? '')
          .join('>');
      if (signature.isEmpty || seen.add(signature)) deduped.add(j);
    }
    return deduped;
  }

  /// Composite score across earliest arrival / least travel time (the
  /// same underlying value), minimum walking, minimum transfers,
  /// accessibility, and confidence. Weights are stated explicitly, not
  /// hidden. See [_confidenceScore]'s doc comment for what
  /// "confidence" concretely means here.
  List<Journey> _rankJourneys(List<Journey> journeys, {required bool accessibilityPreferFewerTransfers}) {
    if (journeys.length <= 1) return journeys;

    double normLowerBetter(double v, double lo, double hi) => hi == lo ? 1.0 : 1.0 - ((v - lo) / (hi - lo));

    final travel = journeys.map((j) => j.totalTravelTime.inSeconds.toDouble()).toList();
    final walking = journeys.map((j) => j.totalWalkingDistanceMeters).toList();
    final transfers = journeys.map((j) => j.transferCount.toDouble()).toList();
    final confidence = journeys.map(_confidenceScore).toList();

    final transferWeight = accessibilityPreferFewerTransfers ? 0.30 : 0.15;
    const travelWeight = 0.40;
    const walkWeight = 0.15;
    final confidenceWeight = 1.0 - travelWeight - walkWeight - transferWeight;

    final scored = <MapEntry<Journey, double>>[];
    for (int i = 0; i < journeys.length; i++) {
      final score = travelWeight * normLowerBetter(travel[i], travel.reduce(min), travel.reduce(max)) +
          walkWeight * normLowerBetter(walking[i], walking.reduce(min), walking.reduce(max)) +
          transferWeight * normLowerBetter(transfers[i], transfers.reduce(min), transfers.reduce(max)) +
          confidenceWeight * confidence[i];
      scored.add(MapEntry(journeys[i], score));
    }
    scored.sort((a, b) => b.value.compareTo(a.value));
    return scored.map((e) => e.key).toList();
  }

  /// Confidence, scoped honestly: this feed has no real-time vehicle
  /// positions, so "confidence" can't mean "how sure are we this bus
  /// is actually on time" — it means how much SCHEDULED slack a
  /// journey's tightest GENUINE transfer has beyond the minimum
  /// required buffer. A transfer with only the bare minimum connection
  /// time is more likely to be missed if the first vehicle runs even
  /// slightly late; 5+ minutes of scheduled slack is more robust to
  /// that. Journeys with no genuine transfers score 1.0.
  ///
  /// AUDIT FIX (Porur -> Velachery 472-minute-journey investigation):
  /// EXCLUDES `isInitialWait` segments — the "Wait at <origin stop>"
  /// segment before the very first boarding is not a transfer
  /// connection at all, it is simply how long until the chosen trip
  /// departs, and that risk is already fully captured by
  /// `totalTravelTime`'s own ranking weight. Previously this method
  /// treated ANY `transfer`-typed segment (including that initial
  /// wait) as "slack," so a journey whose only bus doesn't leave for
  /// ~7 hours scored confidence 1.0 (clamped) — read as maximally
  /// ROBUST rather than the severe drawback it is — which was just
  /// enough, combined with its 0-transfer/less-walking advantage, to
  /// outrank a genuinely practical 39-minute 2-transfer alternative
  /// that RAPTOR had also found. Root-caused by tracing both
  /// candidates' full segment breakdowns before ranking; not a
  /// candidate-generation gap (both journeys were already found) and
  /// not an arbitrary new threshold (this reuses the `isFirstLeg`
  /// distinction `_buildJourneyFromLegChain` already computes).
  double _confidenceScore(Journey j) {
    final transferSegments =
        j.segments.where((s) => s.type == JourneySegmentType.transfer && !s.isInitialWait).toList();
    if (transferSegments.isEmpty) return 1.0;
    const comfortableSeconds = 300;
    final tightest = transferSegments.map((s) => s.duration.inSeconds).reduce((a, b) => a < b ? a : b);
    return (tightest / comfortableSeconds).clamp(0.0, 1.0);
  }

  // ---------------------------------------------------------------------
  // Time helpers
  // ---------------------------------------------------------------------

  int _clockToSeconds(DateTime dt) => dt.hour * 3600 + dt.minute * 60 + dt.second;

  DateTime _secondsToDateTime(DateTime referenceTime, int seconds) {
    final midnight = DateTime(referenceTime.year, referenceTime.month, referenceTime.day);
    return midnight.add(Duration(seconds: seconds));
  }

  String _dateOnly(DateTime dt) =>
      '${dt.year.toString().padLeft(4, '0')}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';

  void _log(String message) {
    if (!debugMode) return;
    // ignore: avoid_print
    print('[JourneyPlannerService] $message');
  }
}
