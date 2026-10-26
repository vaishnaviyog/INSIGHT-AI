import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/transit/final_walking_route_tracker.dart';

void main() {
  group('FinalWalkingRouteTracker — route created', () {
    test('a tracker with real waypoints reports hasRoute true', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [
          FinalWalkingWaypoint(instruction: 'Turn left', lat: 13.0010, lon: 80.0000),
        ],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      expect(tracker.hasRoute, isTrue);
    });

    test('reaching a waypoint emits its instruction exactly once', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [
          FinalWalkingWaypoint(instruction: 'Turn left onto Main Street', lat: 13.0010, lon: 80.0000),
        ],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      final events = tracker.onLocationUpdate(13.0010, 80.0000);
      expect(events.any((e) => e.type == FinalWalkingEventType.stepInstruction && e.instruction == 'Turn left onto Main Street'), isTrue);

      // Lingering near the same waypoint again must not re-trigger it.
      final again = tracker.onLocationUpdate(13.0010, 80.0000);
      expect(again.where((e) => e.type == FinalWalkingEventType.stepInstruction), isEmpty);
    });

    test('multiple waypoints are announced in order as they are reached', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [
          FinalWalkingWaypoint(instruction: 'Turn left', lat: 13.0010, lon: 80.0000),
          FinalWalkingWaypoint(instruction: 'Turn right', lat: 13.0015, lon: 80.0000),
        ],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      final first = tracker.onLocationUpdate(13.0010, 80.0000);
      expect(first.single.instruction, 'Turn left');
      final second = tracker.onLocationUpdate(13.0015, 80.0000);
      expect(second.first.instruction, 'Turn right');
    });
  });

  group('FinalWalkingRouteTracker — route unavailable (fallback)', () {
    test('an empty waypoint list reports hasRoute false', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      expect(tracker.hasRoute, isFalse);
    });

    test('destination arrival still works with NO route (straight-line fallback)', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      // AUDIT FIX (hysteresis): confirmation now requires
      // requiredConsecutiveCloseUpdates (default 2) consecutive close
      // readings, the same rule TransitProgressTracker already uses —
      // see final_walking_route_tracker.dart's doc comment.
      final first = tracker.onLocationUpdate(13.0020, 80.0000);
      expect(first, isEmpty, reason: 'one close reading alone must not confirm');
      final events = tracker.onLocationUpdate(13.0020, 80.0000);
      expect(events.single.type, FinalWalkingEventType.destinationReached);
      expect(tracker.destinationReached, isTrue);
    });

    test('no step instructions are ever produced without a route', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      final events = tracker.onLocationUpdate(13.0010, 80.0000);
      expect(events.where((e) => e.type == FinalWalkingEventType.stepInstruction), isEmpty);
    });
  });

  group('FinalWalkingRouteTracker — arrival detection', () {
    test('destination reached fires exactly once even with a real route present', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [
          FinalWalkingWaypoint(instruction: 'Turn left', lat: 13.0010, lon: 80.0000),
        ],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      tracker.onLocationUpdate(13.0010, 80.0000); // step
      tracker.onLocationUpdate(13.0020, 80.0000); // 1st close reading — not yet confirmed (hysteresis)
      final arrival = tracker.onLocationUpdate(13.0020, 80.0000); // 2nd consecutive close reading — confirmed
      expect(arrival.any((e) => e.type == FinalWalkingEventType.destinationReached), isTrue);
      expect(tracker.destinationReached, isTrue);

      final afterArrival = tracker.onLocationUpdate(13.0020, 80.0000);
      expect(afterArrival, isEmpty); // no repeat once already reached
    });

    test('being far from the destination produces no destinationReached event', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0020,
        destinationLon: 80.0000,
      );
      final events = tracker.onLocationUpdate(14.0, 81.0);
      expect(events, isEmpty);
      expect(tracker.destinationReached, isFalse);
    });
  });

  group('FinalWalkingRouteTracker — reused for intermediate transfer walking (Fix 1)', () {
    test('a transfer-walk tracker (same class, different target) creates a route and tracks it identically', () {
      // Deliberately using the SAME class for a transfer walk as for
      // final walking — there is no separate "transfer tracker" per
      // the explicit "reuse existing infrastructure, do not create a
      // new navigation engine" requirement.
      final transferTracker = FinalWalkingRouteTracker(
        waypoints: const [
          FinalWalkingWaypoint(instruction: 'Cross the road', lat: 13.0005, lon: 80.0000),
        ],
        destinationLat: 13.0010, // the transfer stop, not the trip's final destination
        destinationLon: 80.0000,
      );
      expect(transferTracker.hasRoute, isTrue);
      transferTracker.onLocationUpdate(13.0010, 80.0000); // 1st close reading
      final events = transferTracker.onLocationUpdate(13.0010, 80.0000); // 2nd consecutive close reading
      expect(events.any((e) => e.type == FinalWalkingEventType.destinationReached), isTrue);
    });

    test('a transfer-walk tracker with no route available still falls back to straight-line arrival', () {
      final transferTracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0010,
        destinationLon: 80.0000,
      );
      expect(transferTracker.hasRoute, isFalse);
      transferTracker.onLocationUpdate(13.0010, 80.0000); // 1st close reading
      final events = transferTracker.onLocationUpdate(13.0010, 80.0000); // 2nd consecutive close reading
      expect(events.single.type, FinalWalkingEventType.destinationReached);
    });

    test('two SEPARATE tracker instances (e.g. transfer walk then final walk) never leak state into each other', () {
      final transferTracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0010,
        destinationLon: 80.0000,
      );
      transferTracker.onLocationUpdate(13.0010, 80.0000); // reaches transfer stop
      transferTracker.onLocationUpdate(13.0010, 80.0000); // 2nd consecutive close reading — confirmed
      expect(transferTracker.destinationReached, isTrue);

      // A NEW tracker for the NEXT leg (e.g. final walking after
      // boarding the next transit segment) starts completely fresh —
      // this is what TransitJourneyGuideScreen._startWalkingRouteTracking
      // does for every walking segment (a new FinalWalkingRouteTracker
      // per call), so no stale "already reached" state can carry over.
      final finalTracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0050,
        destinationLon: 80.0000,
      );
      expect(finalTracker.destinationReached, isFalse);
      final tooFar = finalTracker.onLocationUpdate(13.0010, 80.0000); // old transfer-stop position
      expect(tooFar, isEmpty); // not near the NEW destination — no spurious arrival
    });
  });

  group('FinalWalkingRouteTracker — destination arrival hysteresis (AUDIT FIX)', () {
    // Mirrors TransitProgressTracker's requiredConsecutiveCloseUpdates
    // hysteresis — see final_walking_route_tracker.dart's doc comment
    // for the discovered false-arrival scenario this fixes.
    test('1. one false close reading followed by a far reading must NOT reach destination', () {
      final tracker = FinalWalkingRouteTracker(waypoints: const [], destinationLat: 13.0500, destinationLon: 80.2000);
      final falseClose = tracker.onLocationUpdate(13.05017, 80.2000); // ~19m — inside 25m radius
      expect(falseClose, isEmpty, reason: 'one close reading alone must not confirm');
      expect(tracker.destinationReached, isFalse);
      final farAfter = tracker.onLocationUpdate(13.0400, 80.2000); // ~1.1km — genuinely far
      expect(farAfter, isEmpty);
      expect(tracker.destinationReached, isFalse, reason: 'a far reading before confirmation must prevent false arrival');
    });

    test('2. one false close reading followed by several close readings only confirms after the required consecutive count', () {
      final tracker = FinalWalkingRouteTracker(waypoints: const [], destinationLat: 13.0500, destinationLon: 80.2000);
      // A far reading first, to prove any earlier streak (if one
      // existed) would have been reset — then the "false" close
      // reading is really just the first of a genuine approach.
      tracker.onLocationUpdate(13.0400, 80.2000); // far
      final firstClose = tracker.onLocationUpdate(13.0500, 80.2000); // 1st close (the "false" reading)
      expect(firstClose, isEmpty);
      expect(tracker.destinationReached, isFalse);
      final secondClose = tracker.onLocationUpdate(13.0500, 80.2000); // 2nd consecutive close — required count reached
      expect(secondClose.any((e) => e.type == FinalWalkingEventType.destinationReached), isTrue);
      expect(tracker.destinationReached, isTrue);
    });

    test('3. GPS jitter around the destination radius boundary must not falsely trigger', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0500,
        destinationLon: 80.2000,
        requiredConsecutiveCloseUpdates: 3,
      );
      // Alternating just-inside / just-outside the 25m radius — never
      // 3 GENUINELY consecutive close readings.
      const insideOffset = 0.00015; // ~16m
      const outsideOffset = 0.00035; // ~39m
      for (int i = 0; i < 6; i++) {
        final events = i.isEven
            ? tracker.onLocationUpdate(13.0500 + insideOffset, 80.2000)
            : tracker.onLocationUpdate(13.0500 + outsideOffset, 80.2000);
        expect(events, isEmpty, reason: 'oscillation step $i must never confirm arrival');
      }
      expect(tracker.destinationReached, isFalse);
    });

    test('4. genuine arrival with the required consecutive close readings confirms exactly once', () {
      final tracker = FinalWalkingRouteTracker(waypoints: const [], destinationLat: 13.0500, destinationLon: 80.2000);
      final r1 = tracker.onLocationUpdate(13.0500, 80.2000);
      expect(r1, isEmpty);
      final r2 = tracker.onLocationUpdate(13.0500, 80.2000);
      expect(r2, hasLength(1));
      expect(r2.single.type, FinalWalkingEventType.destinationReached);
      // Further genuinely-close readings must not re-announce.
      final r3 = tracker.onLocationUpdate(13.0500, 80.2000);
      expect(r3, isEmpty);
    });

    test('5. after destinationReached, subsequent GPS updates never produce duplicate arrival events', () {
      final tracker = FinalWalkingRouteTracker(waypoints: const [], destinationLat: 13.0500, destinationLon: 80.2000);
      tracker.onLocationUpdate(13.0500, 80.2000);
      tracker.onLocationUpdate(13.0500, 80.2000); // confirmed here
      expect(tracker.destinationReached, isTrue);
      for (int i = 0; i < 20; i++) {
        final events = tracker.onLocationUpdate(13.0500, 80.2000);
        expect(events, isEmpty, reason: 'no duplicate arrival events after confirmation (update $i)');
      }
    });
  });
}
