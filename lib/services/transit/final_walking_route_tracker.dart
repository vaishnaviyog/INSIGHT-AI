import 'dart:math' as math;

enum FinalWalkingEventType { stepInstruction, destinationReached }

class FinalWalkingEvent {
  final FinalWalkingEventType type;
  final String? instruction;

  const FinalWalkingEvent._({required this.type, this.instruction});

  factory FinalWalkingEvent.stepInstruction(String instruction) =>
      FinalWalkingEvent._(type: FinalWalkingEventType.stepInstruction, instruction: instruction);

  factory FinalWalkingEvent.destinationReached() => const FinalWalkingEvent._(type: FinalWalkingEventType.destinationReached);
}

class FinalWalkingWaypoint {
  final String instruction;
  final double lat;
  final double lon;

  const FinalWalkingWaypoint({required this.instruction, required this.lat, required this.lon});
}

double _haversineDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * (math.pi / 180.0);
  final dLon = (lon2 - lon1) * (math.pi / 180.0);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

/// Turn-by-turn progress for the FINAL walking leg (after alighting,
/// or any walking-only trip) — a minimal, pure, dependency-free helper
/// extracted from the existing routing architecture, NOT a second
/// navigation engine. [waypoints] should come directly from a real
/// `RouteData.steps` (`LocationService.getRouteInstructions` —
/// already-existing OSRM integration; see that file), never
/// fabricated. An EMPTY waypoint list is the explicit, honest
/// "route unavailable" case — see [hasRoute] — and this class still
/// works correctly in that case: [onLocationUpdate] simply never
/// produces a [FinalWalkingEventType.stepInstruction], but destination
/// arrival (the straight-line safety-net check, ALWAYS active
/// regardless of route availability) still works.
///
/// STEP PROGRESS IS ONE-SHOT PER WAYPOINT (no hysteresis, unlike
/// [TransitProgressTracker]): once a waypoint is reached, it's removed
/// from consideration — repeated GPS updates near an already-passed
/// waypoint cannot re-trigger its instruction. This is deliberately
/// simpler than a bus stop's hysteresis requirement: a pedestrian
/// turn-by-turn instruction is a one-time cue at a specific point, not
/// a "have we truly arrived at a stop" determination with the same
/// jitter-sensitivity stakes.
///
/// DESTINATION ARRIVAL, UNLIKE STEP PROGRESS, DOES USE THE SAME
/// CONSECUTIVE-CLOSE-READING HYSTERESIS AS [TransitProgressTracker]
/// (AUDIT FIX — comprehensive simulated safety/journey testing pass):
/// a single GPS reading inside [destinationArrivalRadiusMeters] used
/// to confirm arrival immediately and irreversibly. A synthetic
/// simulation (`test/unit/final_walking_and_transit_progression_edge_cases_test.dart`)
/// demonstrated that one erroneous reading (realistic multipath/urban-
/// canyon noise) can land inside the 25m radius while the true
/// position is ~150m away — falsely telling a blind user "you have
/// arrived." [requiredConsecutiveCloseUpdates] (same default, 2, as
/// [TransitProgressTracker]) now requires genuinely CONSECUTIVE close
/// readings before confirming, with the identical "a far reading
/// resets the streak" rule that class already uses — see its own doc
/// comment for why close -> far -> close must not count as two.
class FinalWalkingRouteTracker {
  final List<FinalWalkingWaypoint> waypoints;
  final double destinationLat;
  final double destinationLon;
  final double stepArrivalRadiusMeters;
  final double destinationArrivalRadiusMeters;
  final int requiredConsecutiveCloseUpdates;

  int _nextWaypointIndex = 0;
  bool _destinationReached = false;
  int _consecutiveCloseUpdates = 0;

  FinalWalkingRouteTracker({
    required this.waypoints,
    required this.destinationLat,
    required this.destinationLon,
    this.stepArrivalRadiusMeters = 20.0,
    this.destinationArrivalRadiusMeters = 25.0,
    this.requiredConsecutiveCloseUpdates = 2,
  });

  /// False means "route unavailable" — the honest fallback case, not
  /// an error. Callers should tell the user turn-by-turn guidance
  /// isn't available while this is false, rather than silently acting
  /// as if a route exists.
  bool get hasRoute => waypoints.isNotEmpty;

  bool get destinationReached => _destinationReached;

  List<FinalWalkingEvent> onLocationUpdate(double latitude, double longitude) {
    if (_destinationReached) return const [];
    final events = <FinalWalkingEvent>[];

    while (_nextWaypointIndex < waypoints.length) {
      final waypoint = waypoints[_nextWaypointIndex];
      final distance = _haversineDistanceMeters(latitude, longitude, waypoint.lat, waypoint.lon);
      if (distance > stepArrivalRadiusMeters) break;
      events.add(FinalWalkingEvent.stepInstruction(waypoint.instruction));
      _nextWaypointIndex++;
    }

    // Safety-net arrival check — ALWAYS runs, regardless of route
    // availability or step progress, per the explicit requirement
    // that straight-line distance remains the arrival fallback.
    //
    // AUDIT FIX (comprehensive simulated safety/journey testing pass):
    // requires [requiredConsecutiveCloseUpdates] genuinely CONSECUTIVE
    // close readings — the same hysteresis rule
    // TransitProgressTracker.onLocationUpdate already uses for stop
    // arrival, applied here identically: a reading outside the radius
    // unconditionally resets the streak (close -> far -> close does
    // NOT count as two consecutive close readings).
    final distanceToDestination = _haversineDistanceMeters(latitude, longitude, destinationLat, destinationLon);
    if (distanceToDestination > destinationArrivalRadiusMeters) {
      _consecutiveCloseUpdates = 0;
    } else {
      _consecutiveCloseUpdates++;
      if (_consecutiveCloseUpdates >= requiredConsecutiveCloseUpdates) {
        _destinationReached = true;
        events.add(FinalWalkingEvent.destinationReached());
      }
    }
    return events;
  }
}
