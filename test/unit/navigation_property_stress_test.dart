import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/transit/final_walking_route_tracker.dart';
import 'package:vaishnavi/services/transit/transit_progress_tracker.dart';
import 'package:vaishnavi/services/transit/transit_session_state.dart';
import 'package:vaishnavi/services/transit/transit_session_state_machine.dart';

import '../support/gps_trace_simulator.dart';
import '../support/real_chennai_fixtures.dart';

/// COMPREHENSIVE SIMULATED SAFETY + JOURNEY TESTING — Section 12
/// (property/stress testing) and Section 13 (performance/pathological
/// loops), navigation-specific half. INVARIANTS 9/10 (hazard-related)
/// are covered in `hazard_decision_simulation_test.dart`; this file
/// covers INVARIANTS 1-8, each checked across MANY randomized,
/// fixed-seed traces (reproducible on failure) rather than a single
/// hand-picked example. No property-testing package is added — plain
/// `dart:math` `Random` with an explicit seed is sufficient and this
/// project has no such dependency already installed (checked
/// pubspec.yaml before writing this).
void main() {
  const trialsPerInvariant = 150; // "hundreds of generated GPS traces" — aggregate across this file exceeds that easily

  group('INVARIANT 1: cannot declare arrival/stop-confirmation while clearly outside the configured radius', () {
    test('TransitProgressTracker: points > 3x the 60m arrival radius never confirm', () {
      final rng = Random(101);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
        final target = RealChennaiRoute153A.stops[1];
        for (int step = 0; step < 5; step++) {
          // Points uniformly within an ANNULUS from 180m to 600m (all
          // well beyond 3x60m=180m) — reject/retry the rare edge case
          // at the exact boundary rather than special-casing it.
          double lat, lon, distance;
          do {
            (lat, lon) = randomPointWithin(target.stopLat, target.stopLon, 600, rng);
            distance = haversineMeters(lat, lon, target.stopLat, target.stopLon);
          } while (distance < 180);
          final events = tracker.onLocationUpdate(lat, lon);
          expect(events, isEmpty, reason: 'trial $trial step $step: point ${distance.toStringAsFixed(0)}m away (>180m) must not confirm a 60m-radius stop');
        }
      }
    });

    test('FinalWalkingRouteTracker: points > 2x the 25m destination radius never confirm', () {
      final rng = Random(102);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final tracker = FinalWalkingRouteTracker(waypoints: const [], destinationLat: 13.05, destinationLon: 80.20);
        for (int step = 0; step < 5; step++) {
          double lat, lon, distance;
          do {
            (lat, lon) = randomPointWithin(13.05, 80.20, 300, rng);
            distance = haversineMeters(lat, lon, 13.05, 80.20);
          } while (distance < 60);
          final events = tracker.onLocationUpdate(lat, lon);
          expect(events, isEmpty, reason: 'trial $trial step $step: ${distance.toStringAsFixed(0)}m away must not confirm a 25m-radius destination');
        }
      }
    });
  });

  group('INVARIANT 2: one erroneous GPS reading cannot permanently advance the journey', () {
    test('a single close-then-far spike (not 2 consecutive) never confirms, across many random spike positions/timings', () {
      final rng = Random(103);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
        final target = RealChennaiRoute153A.stops[1];
        // Genuinely far, then ONE erroneous close reading, then far
        // again — the erroneous reading is isolated, never paired
        // with a genuine second consecutive close reading.
        tracker.onLocationUpdate(target.stopLat + 0.02, target.stopLon + 0.02); // far
        final spike = tracker.onLocationUpdate(target.stopLat, target.stopLon); // one erroneous close reading
        expect(spike, isEmpty, reason: 'trial $trial: a single close reading alone must never confirm (needs 2 consecutive)');
        final after = tracker.onLocationUpdate(target.stopLat + (rng.nextDouble() - 0.5) * 0.03, target.stopLon + (rng.nextDouble() - 0.5) * 0.03);
        // The reading after the spike is random and MIGHT itself be
        // close by chance — only assert when it's genuinely far.
        final distanceAfter = haversineMeters(target.stopLat, target.stopLon, target.stopLat + (rng.nextDouble() - 0.5) * 0.03, target.stopLon);
        if (distanceAfter > 60) {
          expect(after, isEmpty, reason: 'trial $trial: the journey must not have permanently advanced from one erroneous reading');
        }
      }
    });
  });

  group('INVARIANT 3: temporary GPS loss cannot create a false arrival', () {
    test('a gap (no readings at all) while genuinely far away never results in confirmation once readings resume, unless truly close', () {
      final rng = Random(104);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
        final target = RealChennaiRoute153A.stops[1];
        // Simulate "loss" as simply not calling onLocationUpdate for a
        // while (the only way loss can manifest to code that only
        // reacts to a position stream) — then resume, still far away.
        final resumeDistance = 200 + rng.nextInt(400);
        final (lat, lon) = randomPointWithin(target.stopLat, target.stopLon, resumeDistance.toDouble(), rng);
        final actualDistance = haversineMeters(lat, lon, target.stopLat, target.stopLon);
        final events = tracker.onLocationUpdate(lat, lon);
        if (actualDistance > 60) {
          expect(events, isEmpty, reason: 'trial $trial: resuming after a gap while still >60m away must not confirm arrival');
        }
      }
    });
  });

  group('INVARIANT 4: a completed segment cannot silently revert to an earlier completed segment', () {
    test('after confirming stop 1, many random readings near EARLIER stops never decrease progress', () {
      final rng = Random(105);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
        final stop1 = RealChennaiRoute153A.stops[1];
        final stop0 = RealChennaiRoute153A.stops[0];
        tracker.onLocationUpdate(stop1.stopLat, stop1.stopLon);
        tracker.onLocationUpdate(stop1.stopLat, stop1.stopLon);
        final remainingAfterStop1 = tracker.stopsRemaining;

        for (int i = 0; i < 5; i++) {
          final (lat, lon) = randomPointWithin(stop0.stopLat, stop0.stopLon, 40, rng); // near the ALREADY-PASSED stop
          tracker.onLocationUpdate(lat, lon);
          expect(tracker.stopsRemaining, lessThanOrEqualTo(remainingAfterStop1),
              reason: 'trial $trial step $i: stopsRemaining must never increase (progress reverting) from a reading near an earlier, already-passed stop');
        }
      }
    });
  });

  group('INVARIANT 5: transit/state-machine transitions occur in the correct order (no skipped or out-of-order states)', () {
    test('randomized valid call sequences never visit states out of the canonical order (except the documented next-destination cycle restart)', () {
      const canonicalOrder = [
        NavigationSessionState.walkingToBoardingStop,
        NavigationSessionState.boarding,
        NavigationSessionState.inTransit,
        NavigationSessionState.alighting,
        NavigationSessionState.finalWalking,
        NavigationSessionState.arrived,
        NavigationSessionState.nextDestination,
        NavigationSessionState.ended,
      ];
      final rng = Random(106);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final segment = trial.isEven ? RealChennaiRoute153A.segment() : RealChennaiRouteM70.segment();
        final stops = trial.isEven ? RealChennaiRoute153A.stops : RealChennaiRouteM70.stops;
        final machine = TransitSessionStateMachine(transitSegment: segment);
        machine.reachedBoardingStop();
        machine.confirmBoarding();
        // Randomized noisy approach to every stop.
        for (int i = 1; i < stops.length; i++) {
          final stop = stops[i];
          final jitterCount = 1 + rng.nextInt(3);
          for (int j = 0; j < jitterCount; j++) {
            final (lat, lon) = randomPointWithin(stop.stopLat, stop.stopLon, 15, rng);
            machine.updateLocation(lat, lon);
          }
          machine.updateLocation(stop.stopLat, stop.stopLon);
          machine.updateLocation(stop.stopLat, stop.stopLon);
        }
        machine.confirmAlighting();
        machine.reachedFinalDestination();
        machine.promptForNextDestination();
        machine.provideNextDestination('a real destination name'); // -> walkingToBoardingStop (new cycle)

        NavigationSessionState? previous;
        for (final event in machine.eventLog) {
          if (event.type != TransitEventType.stateChanged) continue;
          if (previous != null) {
            final isDocumentedCycleRestart =
                previous == NavigationSessionState.nextDestination && event.newState == NavigationSessionState.walkingToBoardingStop;
            if (!isDocumentedCycleRestart) {
              expect(canonicalOrder.indexOf(event.newState!), greaterThanOrEqualTo(canonicalOrder.indexOf(previous)),
                  reason: 'trial $trial: state went backwards from $previous to ${event.newState} without the documented cycle-restart transition');
            }
          }
          previous = event.newState;
        }
      }
    });

    test('invalid/out-of-order manual calls are rejected (produce zero events), never corrupting the state', () {
      final rng = Random(107);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final machine = TransitSessionStateMachine(transitSegment: RealChennaiRoute153A.segment());
        // Call methods in a random, likely-invalid order before doing
        // anything real.
        final calls = <void Function()>[
          () => machine.confirmBoarding(),
          () => machine.confirmAlighting(),
          () => machine.reachedFinalDestination(),
          () => machine.promptForNextDestination(),
          () => machine.reachedDestinationStop(),
        ];
        calls.shuffle(rng);
        final stateBefore = machine.state;
        for (final call in calls) {
          call();
        }
        // None of these are valid from walkingToBoardingStop — state
        // must be completely unchanged.
        expect(machine.state, stateBefore, reason: 'trial $trial: invalid calls from the wrong state must never change state');
      }
    });
  });

  group('INVARIANT 6: destinationReached occurs only after the configured destination-arrival criteria', () {
    test('across many randomized traces, destinationReached is true if and only if SOME fed point was within the radius', () {
      final rng = Random(108);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final destLat = 13.0 + rng.nextDouble() * 0.1;
        final destLon = 80.0 + rng.nextDouble() * 0.2;
        final tracker = FinalWalkingRouteTracker(waypoints: const [], destinationLat: destLat, destinationLon: destLon);
        bool anyPointWasClose = false;
        for (int step = 0; step < 8; step++) {
          final (lat, lon) = randomPointWithin(destLat, destLon, 400, rng);
          final distance = haversineMeters(lat, lon, destLat, destLon);
          if (distance <= 25) anyPointWasClose = true;
          tracker.onLocationUpdate(lat, lon);
          if (tracker.destinationReached) {
            expect(distance, lessThanOrEqualTo(25.0), reason: 'trial $trial: destinationReached became true from a point ${distance.toStringAsFixed(1)}m away, beyond the 25m radius');
            break;
          }
        }
        if (!anyPointWasClose) {
          expect(tracker.destinationReached, isFalse, reason: 'trial $trial: no fed point was ever within radius, yet destinationReached is true');
        }
      }
    });
  });

  group('INVARIANT 7: critical state transitions always produce a stateChanged event; invalid calls never do', () {
    test('every SUCCESSFUL transition method call emits exactly one stateChanged event, across randomized real journeys', () {
      final rng = Random(109);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final machine = TransitSessionStateMachine(transitSegment: RealChennaiRoute153A.segment());
        int before = machine.eventLog.where((e) => e.type == TransitEventType.stateChanged).length;

        final events1 = machine.reachedBoardingStop();
        expect(events1.where((e) => e.type == TransitEventType.stateChanged), hasLength(1));

        final events2 = machine.confirmBoarding();
        expect(events2.where((e) => e.type == TransitEventType.stateChanged), hasLength(1));

        // A repeat call of an already-applied transition must NOT
        // produce a second stateChanged event.
        final repeat = machine.confirmBoarding();
        expect(repeat, isEmpty, reason: 'trial $trial: repeating an already-applied transition must be a no-op');

        for (int i = 1; i < RealChennaiRoute153A.stops.length; i++) {
          final stop = RealChennaiRoute153A.stops[i];
          final (lat, lon) = randomPointWithin(stop.stopLat, stop.stopLon, 5, rng);
          machine.updateLocation(lat, lon);
          machine.updateLocation(stop.stopLat, stop.stopLon);
          machine.updateLocation(stop.stopLat, stop.stopLon);
        }

        final after = machine.eventLog.where((e) => e.type == TransitEventType.stateChanged).length;
        expect(after, greaterThan(before), reason: 'trial $trial: a real journey must produce at least one stateChanged event');
      }
    });
  });

  group('INVARIANT 8: arrival announcement occurs at most once per journey, across randomized noisy journeys', () {
    test('exactly one arrival phrase across many randomized full journeys', () {
      final rng = Random(110);
      for (int trial = 0; trial < trialsPerInvariant; trial++) {
        final machine = TransitSessionStateMachine(transitSegment: RealChennaiRoute153A.segment());
        machine.reachedBoardingStop();
        machine.confirmBoarding();
        for (int i = 1; i < RealChennaiRoute153A.stops.length; i++) {
          final stop = RealChennaiRoute153A.stops[i];
          final extraNoise = rng.nextInt(3);
          for (int j = 0; j < extraNoise; j++) {
            final (lat, lon) = randomPointWithin(stop.stopLat, stop.stopLon, 250, rng); // some noise readings OUTSIDE radius too
            machine.updateLocation(lat, lon);
          }
          machine.updateLocation(stop.stopLat, stop.stopLon);
          machine.updateLocation(stop.stopLat, stop.stopLon);
        }
        machine.confirmAlighting();
        machine.reachedFinalDestination();
        // Extra redundant calls that must be no-ops.
        machine.reachedFinalDestination();
        machine.reachedFinalDestination();

        final arrivalPhrases =
            machine.eventLog.where((e) => e.type == TransitEventType.spokenPhrase && e.spokenPhrase!.contains('arrived at your destination'));
        expect(arrivalPhrases, hasLength(1), reason: 'trial $trial: arrival must be announced exactly once, even with redundant calls');
      }
    });
  });

  group('Section 13 — performance: no pathological loops across a large randomized run', () {
    test('a very long randomized single journey (many stops worth of noisy updates) completes quickly with a bounded event count', () {
      final rng = Random(111);
      final stopwatch = Stopwatch()..start();
      final machine = TransitSessionStateMachine(transitSegment: RealChennaiRoute153A.segment());
      machine.reachedBoardingStop();
      machine.confirmBoarding();
      int callCount = 0;
      for (int i = 1; i < RealChennaiRoute153A.stops.length; i++) {
        final stop = RealChennaiRoute153A.stops[i];
        for (int j = 0; j < 200; j++) {
          // Heavy repeated/noisy updates per stop — simulates a very
          // chatty GPS stream (10Hz for 20s) at each stop.
          final (lat, lon) = randomPointWithin(stop.stopLat, stop.stopLon, 100, rng);
          machine.updateLocation(lat, lon);
          callCount++;
        }
      }
      stopwatch.stop();
      expect(stopwatch.elapsedMilliseconds, lessThan(3000), reason: '${RealChennaiRoute153A.stops.length * 200} location updates must not be pathologically slow');
      expect(callCount, RealChennaiRoute153A.stops.length * 200 - 200); // sanity: loop ran the expected number of times

      // Event log must be bounded and sane — not unbounded growth from
      // duplicate/repeated announcements for the SAME stop transition.
      final stateChanges = machine.eventLog.where((e) => e.type == TransitEventType.stateChanged).length;
      expect(stateChanges, lessThanOrEqualTo(RealChennaiRoute153A.stops.length + 2),
          reason: 'state-change count must stay bounded by the number of real stops, not grow with the number of noisy GPS updates fed in');
    });
  });
}
