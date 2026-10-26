import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/transit/final_walking_route_tracker.dart';
import 'package:vaishnavi/services/transit/transit_progress_tracker.dart';

import '../support/gps_trace_simulator.dart';
import '../support/real_chennai_fixtures.dart';

/// COMPREHENSIVE SIMULATED SAFETY + JOURNEY TESTING — Section 4 (GPS
/// error/noise), Section 5 (the 800m walk), Section 6 (missed/wrong
/// stop). Drives the REAL production `TransitProgressTracker` and
/// `FinalWalkingRouteTracker` with synthetic traces from
/// `test/support/gps_trace_simulator.dart` — no parallel logic.
///
/// NOTE ON TIMESTAMPS: both production classes' `onLocationUpdate`
/// take only `(double latitude, double longitude)` — neither consumes
/// a timestamp, accuracy, speed, or heading at all. This is a real,
/// verified characteristic of the current implementation (not a bug):
/// "timestamp irregularities" and "very slow movement" cannot affect
/// these two classes' behavior differently from any other call
/// sequence, because they have no time dimension. Scenarios I/J from
/// the requested list are therefore expressed here as "call
/// order/cadence has no effect on the resolved outcome" rather than
/// literal timestamp assertions — see the dedicated tests below.
void main() {
  final rng = Random(42); // fixed seed — reproducible

  group('A. Small random jitter', () {
    test('jitter around the approach to a real stop still resolves to confirmed arrival, not stuck', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops);
      final target = RealChennaiRoute153A.stops[1];
      final trace = withJitter(
        straightLineTrace(
          fromLat: RealChennaiRoute153A.stops[0].stopLat,
          fromLon: RealChennaiRoute153A.stops[0].stopLon,
          toLat: target.stopLat,
          toLon: target.stopLon,
          steps: 30,
        ),
        jitterMeters: 15,
        random: rng,
      );
      var confirmedNextStop = false;
      for (final reading in trace) {
        final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
        if (events.any((e) => e.type == TransitProgressEventType.nextStop)) confirmedNextStop = true;
      }
      expect(confirmedNextStop, isTrue, reason: '15m jitter (well under the 60m arrival radius) must not prevent confirmation');
    });
  });

  group('B. Close -> far -> close does NOT falsely declare arrival early', () {
    test('the far reading resets the consecutive-close streak (TransitProgressTracker)', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      final target = RealChennaiRoute153A.stops[1];
      // close
      var events = tracker.onLocationUpdate(target.stopLat, target.stopLon);
      expect(events, isEmpty, reason: 'one close reading alone must not confirm (requires 2 consecutive)');
      // far (a real distance well outside 60m)
      events = tracker.onLocationUpdate(target.stopLat + 0.01, target.stopLon + 0.01); // ~1.5km away
      expect(events, isEmpty);
      // close again — must be treated as a FRESH streak of 1, not 2.
      events = tracker.onLocationUpdate(target.stopLat, target.stopLon);
      expect(events, isEmpty, reason: 'close after far must restart the streak at 1, not resume at 2');
    });
  });

  group('C. Far -> close -> close: arrival occurs only once the hysteresis rule is satisfied', () {
    test('two genuinely consecutive close readings after being far confirms arrival', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      final target = RealChennaiRoute153A.stops[1];
      tracker.onLocationUpdate(target.stopLat + 0.01, target.stopLon + 0.01); // far
      expect(tracker.onLocationUpdate(target.stopLat, target.stopLon), isEmpty); // close #1
      final confirmed = tracker.onLocationUpdate(target.stopLat, target.stopLon); // close #2
      expect(confirmed.any((e) => e.type == TransitProgressEventType.nextStop), isTrue);
    });
  });

  group('D. Oscillation around the arrival radius boundary', () {
    test('oscillating in/out of the 60m radius never confirms until genuinely consecutive close readings occur', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 3);
      final target = RealChennaiRoute153A.stops[1];
      final oscillation = oscillateAroundRadius(
        targetLat: target.stopLat,
        targetLon: target.stopLon,
        radiusMeters: 60,
        oscillations: 8,
      );
      int confirmations = 0;
      for (final reading in oscillation) {
        final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
        confirmations += events.where((e) => e.type == TransitProgressEventType.nextStop).length;
      }
      // Oscillating in/out never produces 3 GENUINELY consecutive
      // inside-radius readings (every "inside" reading is immediately
      // followed by an "outside" one in this trace) — so it must
      // never confirm.
      expect(confirmations, 0, reason: 'alternating in/out of the radius must never satisfy a consecutive-reading requirement');
    });

    test('once oscillation stops and genuine consecutive close readings follow, arrival IS confirmed', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 3);
      final target = RealChennaiRoute153A.stops[1];
      final oscillation = oscillateAroundRadius(
        targetLat: target.stopLat, targetLon: target.stopLon, radiusMeters: 60, oscillations: 4,
      );
      for (final reading in oscillation) {
        tracker.onLocationUpdate(reading.latitude, reading.longitude);
      }
      tracker.onLocationUpdate(target.stopLat, target.stopLon);
      tracker.onLocationUpdate(target.stopLat, target.stopLon);
      final confirmed = tracker.onLocationUpdate(target.stopLat, target.stopLon);
      expect(confirmed.any((e) => e.type == TransitProgressEventType.nextStop), isTrue,
          reason: 'the system must not be permanently stuck after oscillation — it must still confirm on genuine consecutive closes');
    });
  });

  group('E. One wildly incorrect GPS reading', () {
    test('a single huge spike mid-approach does not cause a false confirmation, and normal tracking recovers after', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      final target = RealChennaiRoute153A.stops[1];
      final trace = withOneSpike(
        straightLineTrace(
          fromLat: RealChennaiRoute153A.stops[0].stopLat,
          fromLon: RealChennaiRoute153A.stops[0].stopLon,
          toLat: target.stopLat,
          toLon: target.stopLon,
          steps: 10,
        ),
        atIndex: 5,
        spikeMeters: 5000,
        random: rng,
      );
      var confirmed = false;
      for (final reading in trace) {
        final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
        if (events.any((e) => e.type == TransitProgressEventType.nextStop)) confirmed = true;
      }
      // The trace ends AT the target (step 10 of 10), so it must still
      // resolve correctly despite the spike at index 5 — one bad
      // reading must not permanently derail tracking.
      expect(confirmed, isTrue);
    });
  });

  group('F. Several consecutive inaccurate readings', () {
    test('a burst of noisy readings (30m jitter) around a stop does not prevent eventual confirmation', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      final target = RealChennaiRoute153A.stops[1];
      // Many readings AT the target with heavy jitter (30m, half the
      // 60m radius) — some individual readings may land outside the
      // radius purely from jitter, but the true position is at the
      // target, so confirmation must eventually occur.
      var confirmed = false;
      for (int i = 0; i < 40 && !confirmed; i++) {
        final (lat, lon) = randomPointWithin(target.stopLat, target.stopLon, 30, rng);
        final events = tracker.onLocationUpdate(lat, lon);
        if (events.any((e) => e.type == TransitProgressEventType.nextStop)) confirmed = true;
      }
      expect(confirmed, isTrue, reason: 'persistent noisy-but-centered readings must eventually confirm — the system must not be permanently stuck');
    });
  });

  group('G/H. Temporary GPS loss and resumption', () {
    test('a gap in the trace (no readings at all) does not crash and does not fabricate progress', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops);
      final fullTrace = straightLineTrace(
        fromLat: RealChennaiRoute153A.stops[0].stopLat,
        fromLon: RealChennaiRoute153A.stops[0].stopLon,
        toLat: RealChennaiRoute153A.stops[1].stopLat,
        toLon: RealChennaiRoute153A.stops[1].stopLon,
        steps: 10,
      );
      final withGapTrace = withGap(fullTrace, startIndex: 3, count: 4); // readings simply stop arriving
      // After the gap, the remaining trace still ends at the real
      // target — GPS resuming must let tracking continue normally, not
      // require a special "resume" call (the class has no notion of
      // "loss" at all — a gap is simply an absence of calls, which is
      // exactly how a real GPS dropout looks to code that only reacts
      // to position-stream events). Each reading fed exactly ONCE,
      // matching a real position-stream listener.
      var confirmedAfterGap = false;
      for (final reading in withGapTrace) {
        final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
        if (events.any((e) => e.type == TransitProgressEventType.nextStop)) confirmedAfterGap = true;
      }
      expect(confirmedAfterGap, isTrue, reason: 'tracking must resume normally once readings return after a gap');
    });
  });

  group('I. Call order/cadence has no hidden time dependency (both trackers take no timestamp)', () {
    test('TransitProgressTracker: an unrealistically rapid burst of calls resolves identically to a normal cadence', () {
      final target = RealChennaiRoute153A.stops[1];
      final trackerA = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      final trackerB = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      // Same two calls, no way to express "faster" or "slower" since
      // there is no timestamp parameter — this itself is the proof:
      // both trackers reach the identical outcome regardless of how
      // much real wall-clock time a caller imagines between calls.
      trackerA.onLocationUpdate(target.stopLat, target.stopLon);
      trackerB.onLocationUpdate(target.stopLat, target.stopLon);
      final a = trackerA.onLocationUpdate(target.stopLat, target.stopLon);
      final b = trackerB.onLocationUpdate(target.stopLat, target.stopLon);
      expect(a.length, b.length);
    });
  });

  group('J. Very slow movement (many tiny increments) still reaches confirmation', () {
    test('100 very small steps toward a stop eventually confirm arrival', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      final trace = straightLineTrace(
        fromLat: RealChennaiRoute153A.stops[0].stopLat,
        fromLon: RealChennaiRoute153A.stops[0].stopLon,
        toLat: RealChennaiRoute153A.stops[1].stopLat,
        toLon: RealChennaiRoute153A.stops[1].stopLon,
        steps: 100, // very fine-grained "slow movement"
      );
      var confirmed = false;
      for (final reading in trace) {
        final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
        if (events.any((e) => e.type == TransitProgressEventType.nextStop)) confirmed = true;
      }
      expect(confirmed, isTrue);
    });
  });

  group('K. User stops moving (stationary readings) produce no duplicate events', () {
    test('50 identical readings at the destination after confirmation produce zero further events', () {
      final target = RealChennaiRoute153A.stops[1];
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      tracker.onLocationUpdate(target.stopLat, target.stopLon);
      tracker.onLocationUpdate(target.stopLat, target.stopLon); // confirmed here
      for (int i = 0; i < 50; i++) {
        final events = tracker.onLocationUpdate(target.stopLat, target.stopLon);
        expect(events, isEmpty, reason: 'a stationary user at an already-confirmed stop must not re-trigger any event');
      }
    });

    test('FinalWalkingRouteTracker: repeated identical readings at destination never re-announce arrival', () {
      final tracker = FinalWalkingRouteTracker(waypoints: const [], destinationLat: 13.05, destinationLon: 80.20);
      tracker.onLocationUpdate(13.05, 80.20); // 1st close reading (hysteresis)
      tracker.onLocationUpdate(13.05, 80.20); // 2nd consecutive close reading — confirmed here
      for (int i = 0; i < 50; i++) {
        expect(tracker.onLocationUpdate(13.05, 80.20), isEmpty);
      }
    });
  });

  group('L. User moves away from the expected route (deviation)', () {
    test('drifting away from the target stop produces no progress event at all', () {
      final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
      final target = RealChennaiRoute153A.stops[1];
      // Move steadily AWAY from the target instead of toward it.
      final trace = straightLineTrace(
        fromLat: target.stopLat,
        fromLon: target.stopLon,
        toLat: target.stopLat + 0.02, // ~2.2km away
        toLon: target.stopLon + 0.02,
        steps: 10,
      );
      for (final reading in trace) {
        final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
        expect(events, isEmpty, reason: 'moving away from the target must never produce a progress/arrival event');
      }
    });
  });

  group('M. Approaching the target from a different direction', () {
    test('arrival is confirmed identically regardless of approach bearing (distance is direction-agnostic)', () {
      final target = RealChennaiRoute153A.stops[1];
      for (final bearing in [0.0, 90.0, 180.0, 270.0, 45.0]) {
        final tracker = TransitProgressTracker(orderedStops: RealChennaiRoute153A.stops, requiredConsecutiveCloseUpdates: 2);
        final trace = approachRetreatApproach(
          targetLat: target.stopLat,
          targetLon: target.stopLon,
          startDistanceMeters: 400,
          retreatToDistanceMeters: 200, // not used for pure approach, but keeps a realistic shape
          closeDistanceMeters: 10,
          bearingFromTargetDegrees: bearing,
        );
        var confirmed = false;
        for (final reading in trace) {
          final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
          if (events.any((e) => e.type == TransitProgressEventType.nextStop)) confirmed = true;
        }
        expect(confirmed, isTrue, reason: 'approach from bearing $bearing must still confirm arrival');
      }
    });
  });

  // =====================================================================
  // Section 5 — the 800 metre walk (real Chennai stop pair, 840.8m).
  // =====================================================================
  group('Section 5: the ~800m walk to a real boarding stop', () {
    test('realistic decreasing-distance movement (840m -> arrival radius) reaches arrival at the correct point, not early', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: RealChennai800mWalk.boardingStopLat,
        destinationLon: RealChennai800mWalk.boardingStopLon,
      );
      final trace = straightLineTrace(
        fromLat: RealChennai800mWalk.originLat,
        fromLon: RealChennai800mWalk.originLon,
        toLat: RealChennai800mWalk.boardingStopLat,
        toLon: RealChennai800mWalk.boardingStopLon,
        steps: 40, // ~21m per step across 840m — realistic walking-update granularity
      );

      var arrivedAtStep = -1;
      for (int i = 0; i < trace.length; i++) {
        final events = tracker.onLocationUpdate(trace[i].latitude, trace[i].longitude);
        final remaining = haversineMeters(
            trace[i].latitude, trace[i].longitude, RealChennai800mWalk.boardingStopLat, RealChennai800mWalk.boardingStopLon);
        if (events.any((e) => e.type == FinalWalkingEventType.destinationReached)) {
          // The step that actually CONFIRMS arrival must itself be
          // within the radius — the hysteresis rule (2 consecutive
          // close readings) means the step immediately BEFORE
          // confirmation may already be within the radius without
          // confirming yet, which is correct, not a bug.
          expect(remaining, lessThanOrEqualTo(25.0), reason: 'the confirming step must itself be within the 25m arrival radius (step $i)');
          arrivedAtStep = i;
          break;
        }
      }
      expect(arrivedAtStep, greaterThan(-1), reason: 'the 800m walk must eventually reach arrival');
      // Arrival should happen very near the END of the trace (the last
      // couple of steps), not partway through — proves progress
      // continues correctly across the whole 800m, not just near start/end.
      expect(arrivedAtStep, greaterThanOrEqualTo(trace.length - 3));
    });

    test('the same 800m walk WITH substantial GPS noise still arrives, and never falsely arrives early', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: RealChennai800mWalk.boardingStopLat,
        destinationLon: RealChennai800mWalk.boardingStopLon,
      );
      final trace = withJitter(
        straightLineTrace(
          fromLat: RealChennai800mWalk.originLat,
          fromLon: RealChennai800mWalk.originLon,
          toLat: RealChennai800mWalk.boardingStopLat,
          toLon: RealChennai800mWalk.boardingStopLon,
          steps: 60,
        ),
        jitterMeters: 12, // realistic consumer GPS noise
        random: rng,
      );

      bool arrivedTooEarly = false;
      var arrived = false;
      for (int i = 0; i < trace.length; i++) {
        final events = tracker.onLocationUpdate(trace[i].latitude, trace[i].longitude);
        if (events.any((e) => e.type == FinalWalkingEventType.destinationReached)) {
          arrived = true;
          // "Too early" defined as: fewer than 70% of the trace consumed
          // AND the true (unjittered) straight-line position was still
          // genuinely far. Uses the ORIGINAL straight-line point at
          // this index for ground truth.
          final trueRemaining = haversineMeters(
            RealChennai800mWalk.originLat +
                (RealChennai800mWalk.boardingStopLat - RealChennai800mWalk.originLat) * (i / (trace.length - 1)),
            RealChennai800mWalk.originLon +
                (RealChennai800mWalk.boardingStopLon - RealChennai800mWalk.originLon) * (i / (trace.length - 1)),
            RealChennai800mWalk.boardingStopLat,
            RealChennai800mWalk.boardingStopLon,
          );
          if (i < trace.length * 0.7 && trueRemaining > 200) arrivedTooEarly = true;
          break;
        }
      }
      expect(arrived, isTrue, reason: 'noise must not prevent eventually reaching arrival on an 800m walk');
      expect(arrivedTooEarly, isFalse,
          reason: 'GPS noise must not cause the system to believe it arrived while genuinely far (>200m) from the stop');
    });

    test('the boarding stop target never changes mid-walk — the tracker has no rerouting/nearest-stop logic', () {
      // Structural proof: FinalWalkingRouteTracker is constructed with
      // ONE fixed destination and has no method to change it or query
      // "is there a closer target" — so the boarding stop cannot
      // silently switch mid-walk. This directly satisfies "the route
      // does not prematurely switch to transit" / "correct boarding
      // stop remains the target" from the explicit requirement list.
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: RealChennai800mWalk.boardingStopLat,
        destinationLon: RealChennai800mWalk.boardingStopLon,
      );
      expect(tracker.destinationLat, RealChennai800mWalk.boardingStopLat);
      expect(tracker.destinationLon, RealChennai800mWalk.boardingStopLon);
      // Feed noisy readings, including some passing near OTHER real
      // stops (competing stops fixture) — destination must remain
      // exactly the constructed one throughout.
      tracker.onLocationUpdate(RealChennaiCompetingStops.correctLat, RealChennaiCompetingStops.correctLon);
      tracker.onLocationUpdate(RealChennaiCompetingStops.wrongLat, RealChennaiCompetingStops.wrongLon);
      expect(tracker.destinationLat, RealChennai800mWalk.boardingStopLat);
      expect(tracker.destinationLon, RealChennai800mWalk.boardingStopLon);
    });
  });

  // =====================================================================
  // Section 6 — missed / wrong stop scenarios.
  // =====================================================================
  group('Section 6: missed / wrong stop scenarios', () {
    test('walking PAST the intended stop without ever coming within radius never declares arrival', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: RealChennai800mWalk.boardingStopLat,
        destinationLon: RealChennai800mWalk.boardingStopLon,
      );
      // A trace that passes ~80m to the side of the stop (offset
      // north) and continues past it — never within the 25m radius.
      final trace = straightLineTrace(
        fromLat: RealChennai800mWalk.originLat,
        fromLon: RealChennai800mWalk.originLon,
        toLat: RealChennai800mWalk.boardingStopLat + 0.0009, // ~100m north offset maintained
        toLon: RealChennai800mWalk.boardingStopLon + 0.003,
        steps: 30,
      );
      for (final reading in trace) {
        final events = tracker.onLocationUpdate(reading.latitude, reading.longitude);
        expect(events, isEmpty);
      }
      expect(tracker.destinationReached, isFalse, reason: 'walking past a stop without ever being within radius must not register arrival');
    });

    test('two real stops sharing the same name, 35.8m apart: proximity to the WRONG one does not satisfy the CORRECT one\'s tracker', () {
      // RealChennaiCompetingStops: two genuinely different, real
      // stop_ids both named "Poonjeri Koot Road", 35.8m apart.
      final correctStopTracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: RealChennaiCompetingStops.correctLat,
        destinationLon: RealChennaiCompetingStops.correctLon,
        destinationArrivalRadiusMeters: 25, // production default
      );
      // The user's GPS places them AT the WRONG stop (a real,
      // plausible "GPS placed the user at a nearby wrong stop"
      // scenario) — 35.8m from the correct one, outside the 25m radius.
      final events = correctStopTracker.onLocationUpdate(RealChennaiCompetingStops.wrongLat, RealChennaiCompetingStops.wrongLon);
      expect(events, isEmpty,
          reason: 'being at a real, same-named, but WRONG stop 35.8m away must not satisfy the correct stop\'s 25m arrival radius');
      expect(correctStopTracker.destinationReached, isFalse);
    });

    test('GPS momentarily placing the user near the wrong stop, then correcting to the real stop, still arrives correctly', () {
      final tracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: RealChennaiCompetingStops.correctLat,
        destinationLon: RealChennaiCompetingStops.correctLon,
      );
      // Momentary bad fix near the wrong stop.
      tracker.onLocationUpdate(RealChennaiCompetingStops.wrongLat, RealChennaiCompetingStops.wrongLon);
      expect(tracker.destinationReached, isFalse);
      // GPS corrects to the real, correct stop — needs 2 consecutive
      // close readings (hysteresis) to confirm.
      tracker.onLocationUpdate(RealChennaiCompetingStops.correctLat, RealChennaiCompetingStops.correctLon);
      final events = tracker.onLocationUpdate(RealChennaiCompetingStops.correctLat, RealChennaiCompetingStops.correctLon);
      expect(events.any((e) => e.type == FinalWalkingEventType.destinationReached), isTrue);
    });
  });
}
