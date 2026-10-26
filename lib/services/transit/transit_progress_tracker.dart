import 'dart:math' as math;

import '../../models/journey/journey_segment.dart';

enum TransitProgressEventType { nextStop, stopsRemaining, destinationApproaching, destinationReached }

/// One resolved, DEBOUNCED progress update — see
/// [TransitProgressTracker]'s class doc comment for what "resolved"
/// means. A caller (the state machine) can react to every event it
/// receives without its own deduplication logic.
class TransitProgressEvent {
  final TransitProgressEventType type;
  final TransitStopWaypoint? stop;
  final int? stopsRemaining;

  const TransitProgressEvent({required this.type, this.stop, this.stopsRemaining});

  @override
  String toString() => 'TransitProgressEvent($type, stop=${stop?.stopName}, remaining=$stopsRemaining)';
}

/// Haversine distance in meters — same formula this project already
/// uses elsewhere (`GtfsQueryService`/`RaptorRouter`), reused here
/// rather than reimplemented differently.
double _haversineDistanceMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * (math.pi / 180.0);
  final dLon = (lon2 - lon1) * (math.pi / 180.0);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

/// Determines current/next-stop progress along a transit segment's
/// [JourneySegment.orderedStops] from live location updates — pure
/// logic, no GPS/platform-channel dependency, so this is fully
/// unit-testable with synthetic coordinates (see
/// `test/unit/transit_progress_tracker_test.dart`).
///
/// PROGRESS IS MONOTONIC: once a stop is confirmed "passed," this
/// never regresses to an earlier stop, even if a later noisy GPS fix
/// happens to land closer to that earlier stop again (a real vehicle
/// moving along its route does not go backwards; treating a jittery
/// fix as "we went back a stop" would be actively wrong, not merely
/// imprecise).
///
/// HYSTERESIS / DEBOUNCING: a candidate "next stop" must be within
/// [arrivalRadiusMeters] for [requiredConsecutiveCloseUpdates]
/// CONSECUTIVE updates before it's committed as passed and an event
/// is emitted — a single close GPS fix (easily produced by jitter
/// near a stop the bus is only passing, not stopping at) cannot
/// trigger an announcement on its own. A reading OUTSIDE the radius
/// resets the streak — close -> far -> close does NOT count as two
/// consecutive close observations toward confirmation; it restarts
/// the count. Every event type is also emitted AT MOST ONCE per stop
/// transition — calling [onLocationUpdate] again with the same
/// resolved progress produces an empty event list, not a repeat
/// announcement.
class TransitProgressTracker {
  final List<TransitStopWaypoint> orderedStops;
  final double arrivalRadiusMeters;
  final int requiredConsecutiveCloseUpdates;

  /// Index into [orderedStops] of the last CONFIRMED-passed stop.
  /// Starts at 0 — boarding is stop 0, already "current" the moment
  /// transit begins (nothing to announce for reaching the stop you
  /// literally just boarded at).
  int _lastConfirmedStopIndex = 0;

  int? _candidateStopIndex;
  int _consecutiveCloseUpdates = 0;

  TransitProgressTracker({
    required this.orderedStops,
    this.arrivalRadiusMeters = 60.0,
    this.requiredConsecutiveCloseUpdates = 2,
  });

  bool get destinationReached => orderedStops.isNotEmpty && _lastConfirmedStopIndex == orderedStops.length - 1;

  int get stopsRemaining => orderedStops.isEmpty ? 0 : (orderedStops.length - 1 - _lastConfirmedStopIndex).clamp(0, orderedStops.length);

  /// Feeds one location fix through the tracker. Returns the events
  /// this update resolved — usually empty (most updates don't change
  /// anything meaningful), never more than one full "advance" worth
  /// per call even if a single low-frequency update happened to land
  /// well past the next stop (this only ever advances ONE stop per
  /// confirmed transition, exactly like a rider passing stops one at
  /// a time — see [onLocationUpdate]'s doc comment on this specific
  /// behavior for why skipping stops in one jump is never emitted).
  List<TransitProgressEvent> onLocationUpdate(double latitude, double longitude) {
    if (destinationReached || orderedStops.isEmpty) return const [];

    final nextIndex = _lastConfirmedStopIndex + 1;
    if (nextIndex >= orderedStops.length) return const [];
    final nextStop = orderedStops[nextIndex];
    final distance = _haversineDistanceMeters(latitude, longitude, nextStop.stopLat, nextStop.stopLon);

    if (distance > arrivalRadiusMeters) {
      // AUDIT FIX: a reading outside the radius now unconditionally
      // resets the consecutive-close streak. Requiring genuinely
      // CONSECUTIVE close observations (close -> far -> close does
      // NOT count as two toward confirmation) is the explicit
      // requirement — a design earlier in this file's history left
      // the streak intact across a far reading, on the reasoning that
      // there's only ever one candidate stop to track; that reasoning
      // doesn't change the requirement, which is about observation
      // CONTINUITY, not candidate identity.
      _candidateStopIndex = null;
      _consecutiveCloseUpdates = 0;
      return const [];
    }

    if (_candidateStopIndex != nextIndex) {
      _candidateStopIndex = nextIndex;
      _consecutiveCloseUpdates = 1;
    } else {
      _consecutiveCloseUpdates++;
    }

    if (_consecutiveCloseUpdates < requiredConsecutiveCloseUpdates) return const [];

    // Confirmed — advance exactly one stop, emit events for the NEW
    // current position, and reset the hysteresis streak for the next
    // leg of the journey.
    _lastConfirmedStopIndex = nextIndex;
    _candidateStopIndex = null;
    _consecutiveCloseUpdates = 0;

    final events = <TransitProgressEvent>[];
    final remaining = stopsRemaining;

    if (destinationReached) {
      events.add(TransitProgressEvent(type: TransitProgressEventType.destinationReached, stop: nextStop));
      return events;
    }

    events.add(TransitProgressEvent(
      type: TransitProgressEventType.nextStop,
      stop: orderedStops[_lastConfirmedStopIndex + 1],
    ));
    events.add(TransitProgressEvent(type: TransitProgressEventType.stopsRemaining, stopsRemaining: remaining));
    if (remaining == 1) {
      events.add(TransitProgressEvent(
        type: TransitProgressEventType.destinationApproaching,
        stop: orderedStops.last,
      ));
    }
    return events;
  }
}
