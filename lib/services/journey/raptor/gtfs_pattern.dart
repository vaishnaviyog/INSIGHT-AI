import 'dart:typed_data';

/// A "pattern" in transit-routing terminology: the set of trips on a
/// route that share the EXACT SAME ordered stop sequence. Real GTFS
/// routes often have branches/short-turns (a route_id whose trips
/// visit different stop subsets) — grouping by pattern rather than
/// raw route_id is what makes RAPTOR's route-scanning step correct;
/// grouping by route_id alone would silently misalign trips that
/// don't actually share a stop sequence.
///
/// Trip arrival/departure times are stored as parallel `Int32List`s
/// (seconds since the reference date's midnight, GTFS-style — may
/// exceed 86400 for a post-midnight trip) rather than one Dart object
/// per stop_time row: at ~1.36M source rows, that reduces per-trip
/// memory to two flat typed-int arrays instead of N small boxed
/// objects, which matters for "avoid unnecessary allocations."
class GtfsPattern {
  final String patternId;
  final String routeId;
  final List<String> stopIds; // ordered

  /// tripArrivalSeconds[tripIndex][stopIndexInPattern]. Trips are
  /// sorted ascending by their departure at stop index 0 — required
  /// by RAPTOR's earliest-trip-catchable scan.
  final List<Int32List> tripArrivalSeconds;
  final List<Int32List> tripDepartureSeconds;
  final List<String> tripIds; // parallel to the two arrays above

  const GtfsPattern({
    required this.patternId,
    required this.routeId,
    required this.stopIds,
    required this.tripArrivalSeconds,
    required this.tripDepartureSeconds,
    required this.tripIds,
  });

  int get numStops => stopIds.length;
  int get numTrips => tripIds.length;
}

/// One (pattern, stopIndex) reference — how `GtfsTimetable` answers
/// "which patterns serve this stop, and at which position."
class PatternStopRef {
  final GtfsPattern pattern;
  final int stopIndex;
  const PatternStopRef(this.pattern, this.stopIndex);
}
