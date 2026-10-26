import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/transit/final_walking_route_tracker.dart';
import 'package:vaishnavi/services/transit/transit_session_state.dart';
import 'package:vaishnavi/services/transit/transit_session_state_machine.dart';

import '../support/real_chennai_fixtures.dart';

/// COMPREHENSIVE SIMULATED SAFETY + JOURNEY TESTING — Section 3
/// (complete synthetic journey) and Section 7 (transit progression,
/// including a transfer between two real routes).
///
/// Drives the REAL production classes directly —
/// `TransitSessionStateMachine`, `TransitProgressTracker` (via
/// `updateLocation`), `FinalWalkingRouteTracker` — exactly the way
/// `TransitJourneyGuideScreen` orchestrates them (a FRESH
/// `TransitSessionStateMachine` per transit leg, matching
/// `_enterTransitSegment`), with real Chennai route/stop data (see
/// `test/support/real_chennai_fixtures.dart`) instead of fabricated
/// coordinates. No parallel state machine is introduced.
void main() {
  group('Complete journey: walk -> board -> transit (multi-stop) -> alight -> final walk -> arrive', () {
    test('every expected state is visited in order, with the correct voice events', () {
      final segment = RealChennaiRoute153A.segment();
      final machine = TransitSessionStateMachine(transitSegment: segment, finalDestinationDescription: 'Koyambedu');

      final visitedStates = <NavigationSessionState>[machine.state];
      void record(List<TransitEvent> events) {
        for (final e in events) {
          if (e.type == TransitEventType.stateChanged) visitedStates.add(e.newState!);
        }
      }

      expect(machine.state, NavigationSessionState.walkingToBoardingStop);

      // WALKING_TO_BOARDING_STOP -> BOARDING
      record(machine.reachedBoardingStop());
      expect(machine.state, NavigationSessionState.boarding);

      // BOARDING -> IN_TRANSIT
      record(machine.confirmBoarding());
      expect(machine.state, NavigationSessionState.inTransit);

      // Feed real GPS positions for every stop after boarding (stop 0
      // is the boarding stop itself, already "current") — two
      // consecutive close readings per stop, matching
      // TransitProgressTracker's real hysteresis requirement.
      for (int i = 1; i < RealChennaiRoute153A.stops.length; i++) {
        final stop = RealChennaiRoute153A.stops[i];
        machine.updateLocation(stop.stopLat, stop.stopLon);
        record(machine.updateLocation(stop.stopLat, stop.stopLon));
      }

      // The last stop's second reading must have auto-advanced to ALIGHTING.
      expect(machine.state, NavigationSessionState.alighting);

      // ALIGHTING -> FINAL_WALKING (manual confirm — no GPS signal for
      // "physically stepped off", per TransitSessionStateMachine's own
      // doc comment)
      record(machine.confirmAlighting());
      expect(machine.state, NavigationSessionState.finalWalking);

      // FINAL_WALKING -> ARRIVED, via the real FinalWalkingRouteTracker
      // (straight-line fallback — no OSRM route needed to prove the
      // state machine wiring).
      final finalTracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: 13.0700, // a plausible nearby destination
        destinationLon: 80.2060,
      );
      finalTracker.onLocationUpdate(13.0700, 80.2060); // 1st close reading (hysteresis)
      final walkEvents = finalTracker.onLocationUpdate(13.0700, 80.2060); // 2nd consecutive close reading — confirmed
      expect(walkEvents.any((e) => e.type == FinalWalkingEventType.destinationReached), isTrue);
      record(machine.reachedFinalDestination());
      expect(machine.state, NavigationSessionState.arrived);

      // ARRIVED -> NEXT_DESTINATION -> ENDED
      record(machine.promptForNextDestination());
      expect(machine.state, NavigationSessionState.nextDestination);
      record(machine.provideNextDestination('stop'));
      expect(machine.state, NavigationSessionState.ended);

      expect(
        visitedStates,
        [
          NavigationSessionState.walkingToBoardingStop,
          NavigationSessionState.boarding,
          NavigationSessionState.inTransit,
          NavigationSessionState.alighting,
          NavigationSessionState.finalWalking,
          NavigationSessionState.arrived,
          NavigationSessionState.nextDestination,
          NavigationSessionState.ended,
        ],
      );

      // Voice events: every stop announcement present, arrival spoken
      // exactly once, no internal implementation detail ever spoken.
      final spoken = machine.eventLog
          .where((e) => e.type == TransitEventType.spokenPhrase)
          .map((e) => e.spokenPhrase!)
          .toList();
      expect(spoken.where((p) => p.contains('arrived at your destination')), hasLength(1),
          reason: 'arrival must be announced exactly once');
      expect(spoken.any((p) => p.toLowerCase().contains('please get down')), isTrue);
      for (final p in spoken) {
        for (final forbidden in ['sqlite', 'raptor', 'gtfs', 'database', 'stopwatch', 'ms', 'query']) {
          expect(p.toLowerCase().contains(forbidden), isFalse, reason: 'spoken phrase leaks internal detail: "$p"');
        }
      }
    });
  });

  group('Multi-segment journey with a real transfer (two different real routes)', () {
    test('camera contract and voice events stay correct across a transfer between two transit legs', () {
      // Leg 1: K.K.Nagar -> Koyambedu (route 153A).
      final leg1Segment = RealChennaiRoute153A.segment();
      final leg1 = TransitSessionStateMachine(transitSegment: leg1Segment);
      expect(leg1.eventLog.first.type, TransitEventType.cameraCommand);
      expect(leg1.eventLog.first.cameraCommand, CameraDetectionCommand.startDetection);

      leg1.reachedBoardingStop();
      leg1.confirmBoarding();
      // confirmBoarding must have stopped the camera (CAMERA CONTRACT).
      expect(
        leg1.eventLog.where((e) => e.type == TransitEventType.cameraCommand).last.cameraCommand,
        CameraDetectionCommand.stopDetection,
      );

      for (int i = 1; i < RealChennaiRoute153A.stops.length; i++) {
        final stop = RealChennaiRoute153A.stops[i];
        leg1.updateLocation(stop.stopLat, stop.stopLon);
        leg1.updateLocation(stop.stopLat, stop.stopLon);
      }
      expect(leg1.state, NavigationSessionState.alighting);
      leg1.confirmAlighting();
      expect(leg1.state, NavigationSessionState.finalWalking);
      // confirmAlighting restarts the camera + resets detection state —
      // this is the "transfer walk" camera-on period.
      expect(
        leg1.eventLog.where((e) => e.type == TransitEventType.cameraCommand).last.cameraCommand,
        CameraDetectionCommand.startDetection,
      );
      expect(leg1.eventLog.any((e) => e.type == TransitEventType.resetDetectionState), isTrue);

      // Real transfer walk (Koyambedu Bus Terminus is the shared stop
      // between the two real routes) — production would route-track
      // this via FinalWalkingRouteTracker; here we just confirm arrival
      // at the SAME coordinates the next leg boards from.
      final transferTracker = FinalWalkingRouteTracker(
        waypoints: const [],
        destinationLat: RealChennaiRouteM70.stops.first.stopLat,
        destinationLon: RealChennaiRouteM70.stops.first.stopLon,
      );
      transferTracker.onLocationUpdate(
        RealChennaiRouteM70.stops.first.stopLat,
        RealChennaiRouteM70.stops.first.stopLon,
      ); // 1st close reading (hysteresis)
      final transferEvents = transferTracker.onLocationUpdate(
        RealChennaiRouteM70.stops.first.stopLat,
        RealChennaiRouteM70.stops.first.stopLon,
      ); // 2nd consecutive close reading — confirmed
      expect(transferEvents.any((e) => e.type == FinalWalkingEventType.destinationReached), isTrue);

      // Leg 2: a FRESH TransitSessionStateMachine, exactly as
      // TransitJourneyGuideScreen._enterTransitSegment constructs one
      // per transit leg — Koyambedu -> K.K.Nagar (route M70).
      final leg2Segment = RealChennaiRouteM70.segment();
      final leg2 = TransitSessionStateMachine(transitSegment: leg2Segment);
      // Leg 2's construction requests camera start again — idempotent
      // in production (NavigationScreen's start/stop are no-ops if
      // already in that state), so a second start request here is
      // correct, not a bug.
      expect(leg2.eventLog.first.cameraCommand, CameraDetectionCommand.startDetection);

      leg2.reachedBoardingStop();
      leg2.confirmBoarding();
      expect(
        leg2.eventLog.where((e) => e.type == TransitEventType.cameraCommand).last.cameraCommand,
        CameraDetectionCommand.stopDetection,
      );

      for (int i = 1; i < RealChennaiRouteM70.stops.length; i++) {
        final stop = RealChennaiRouteM70.stops[i];
        leg2.updateLocation(stop.stopLat, stop.stopLon);
        leg2.updateLocation(stop.stopLat, stop.stopLon);
      }
      expect(leg2.state, NavigationSessionState.alighting);
      leg2.confirmAlighting();
      expect(leg2.state, NavigationSessionState.finalWalking);

      // Neither leg ever skipped a transit segment: both independently
      // reached alighting exactly once, with the full stop sequence
      // acknowledged (destinationReached only true once all stops but
      // the first were passed).
      expect(leg1.eventLog.where((e) => e.type == TransitEventType.stateChanged && e.newState == NavigationSessionState.alighting), hasLength(1));
      expect(leg2.eventLog.where((e) => e.type == TransitEventType.stateChanged && e.newState == NavigationSessionState.alighting), hasLength(1));
    });
  });

  group('Voice announcement correctness across a full journey', () {
    test('no duplicate "stops remaining" announcements, no repeated "please wait"', () {
      final segment = RealChennaiRoute153A.segment();
      final machine = TransitSessionStateMachine(transitSegment: segment);
      machine.reachedBoardingStop();
      machine.confirmBoarding();

      for (int i = 1; i < RealChennaiRoute153A.stops.length; i++) {
        final stop = RealChennaiRoute153A.stops[i];
        // Feed EACH stop's position several extra times (simulating a
        // stationary/slow-moving bus at a stop) to prove no duplicate
        // "next stop"/"stops remaining" announcements fire.
        machine.updateLocation(stop.stopLat, stop.stopLon);
        machine.updateLocation(stop.stopLat, stop.stopLon);
        machine.updateLocation(stop.stopLat, stop.stopLon);
        machine.updateLocation(stop.stopLat, stop.stopLon);
      }

      final spoken = machine.eventLog
          .where((e) => e.type == TransitEventType.spokenPhrase)
          .map((e) => e.spokenPhrase!)
          .toList();
      // Each distinct "stops remaining: N" phrase must appear at most once.
      final remainingPhrases = spoken.where((p) => p.contains('stops remaining')).toList();
      expect(remainingPhrases.toSet().length, remainingPhrases.length,
          reason: 'a specific stops-remaining count was announced more than once: $remainingPhrases');
      expect(spoken.where((p) => p.toLowerCase().contains('please wait')), isEmpty,
          reason: 'the voice UX must never use repeated "please wait" phrasing');
    });
  });
}
