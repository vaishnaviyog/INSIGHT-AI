// AUDIT ADD (Southern Railway suburban-rail data merge): `train` is a
// distinct mode from `metro` — GTFS route_type 2 (Rail/suburban
// commuter train) vs. 1 (Subway/Metro). Before this, any non-bus
// route was labeled "Metro" regardless of which it actually was, so a
// real suburban-rail leg would have been announced to the user as
// "Board Metro X" — wrong mode, wrong platform/boarding expectations
// for a blind rider relying on that announcement to find the right
// platform at a station that serves both.
enum JourneySegmentType { walking, bus, metro, train, transfer }

/// One stop along an ordered transit-segment stop sequence — real
/// GTFS data (a `GtfsStop` reduced to what a progress tracker needs),
/// never fabricated. Added alongside [JourneySegment.orderedStops].
class TransitStopWaypoint {
  final String stopId;
  final String stopName;
  final double stopLat;
  final double stopLon;

  /// Position within the segment's stop sequence, 0 = boarding stop.
  final int sequenceIndex;

  const TransitStopWaypoint({
    required this.stopId,
    required this.stopName,
    required this.stopLat,
    required this.stopLon,
    required this.sequenceIndex,
  });
}

/// One leg of a [Journey]. Walking segments carry a distance;
/// transit segments carry a route label, boarding/alighting stop
/// names, and real departure/arrival clock times drawn from the
/// actual `stop_times` rows matched by `JourneyPlannerService` — never
/// estimated or fabricated once a real trip is found.
class JourneySegment {
  final JourneySegmentType type;

  /// Human-readable one-liner, e.g. "Walk to Anna Square Bus Stop",
  /// "Board Bus 29A towards Perambur B.T", "Transfer to Metro Blue Line".
  final String description;

  final String? fromStopName;
  final String? toStopName;
  final String? routeShortName;
  final String? routeLongName;
  final String? tripId;

  /// AUDIT ADD (transit state machine — BLOCKER 6): the GTFS route
  /// this segment's trip belongs to. Only set for bus/metro segments.
  final String? routeId;
  final String? boardingStopId;
  final String? alightingStopId;

  /// AUDIT ADD: the FULL ordered stop sequence for THIS transit
  /// segment (boarding stop through alighting stop, inclusive), drawn
  /// directly from the matched GTFS pattern's own `stopIds` — the
  /// exact real sequence the rider will pass through, not
  /// interpolated or guessed. Empty for walking/transfer segments.
  /// This is what `TransitProgressTracker` consumes to determine
  /// current/next stop and stops-remaining from live location
  /// updates — see `lib/services/transit/transit_progress_tracker.dart`.
  final List<TransitStopWaypoint> orderedStops;

  final double? walkingDistanceMeters;
  final Duration duration;
  final DateTime? departureTime;
  final DateTime? arrivalTime;

  /// AUDIT ADD (Fix 1 — intermediate transfer walking): the real
  /// destination coordinates for a WALKING/transfer segment — the
  /// same coordinates already computed at each such segment's
  /// construction site in `JourneyPlannerService` (the boarding
  /// stop's, an intermediate transfer stop's, or the trip's final
  /// destination's own lat/lon — never estimated or guessed). Null
  /// for a segment where this genuinely isn't available; a caller
  /// (`TransitJourneyGuideScreen`) must treat null as "route-based
  /// tracking isn't possible for this segment" and fall back to
  /// manual confirmation, never fabricate a target.
  final double? toLat;
  final double? toLon;

  /// AUDIT FIX (Porur -> Velachery 472-minute-journey investigation):
  /// true only for the `transfer`-typed segment representing "waiting
  /// at the origin stop for your very first boarding" (the "Wait at
  /// X" segment `JourneyPlannerService._buildJourneyFromLegChain`
  /// builds when `isFirstLeg` is true) — false for every other segment,
  /// including genuine mid-journey transfers ("Transfer at X"/"Walk to
  /// X to transfer"). This is NOT a new concept: the segment's own
  /// `description` text already distinguished "Wait at" from "Transfer
  /// at" at construction time — this field just makes that same,
  /// already-computed distinction available to callers (like
  /// `JourneyPlannerService._confidenceScore`) without parsing
  /// description text. See that method's doc comment for why the
  /// distinction matters: a long initial wait is not the same risk as
  /// a tight transfer connection, and conflating them let a
  /// technically-direct journey with an ~7-hour wait for its only bus
  /// score as maximally "confident" instead of being penalized.
  final bool isInitialWait;

  const JourneySegment({
    required this.type,
    required this.description,
    required this.duration,
    this.fromStopName,
    this.toStopName,
    this.routeShortName,
    this.routeLongName,
    this.tripId,
    this.routeId,
    this.boardingStopId,
    this.alightingStopId,
    this.orderedStops = const [],
    this.walkingDistanceMeters,
    this.departureTime,
    this.arrivalTime,
    this.toLat,
    this.toLon,
    this.isInitialWait = false,
  });
}
