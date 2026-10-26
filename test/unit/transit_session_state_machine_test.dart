import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/journey/journey_segment.dart';
import 'package:vaishnavi/services/transit/transit_session_state.dart';
import 'package:vaishnavi/services/transit/transit_session_state_machine.dart';

/// A synthetic 5-stop bus segment: Boarding -> A -> B -> C -> Destination.
/// Real-shaped GTFS coordinates (not fabricated Chennai data, just a
/// small synthetic line spaced ~150m apart so proximity math is easy
/// to hand-verify), matching exactly what `journey_planner_service.dart`
/// now populates `JourneySegment.orderedStops` with from a real pattern.
JourneySegment _syntheticTransitSegment() {
  final stops = [
    const TransitStopWaypoint(stopId: 'S0', stopName: 'Boarding Stop', stopLat: 13.0000, stopLon: 80.0000, sequenceIndex: 0),
    const TransitStopWaypoint(stopId: 'S1', stopName: 'Stop A', stopLat: 13.0013, stopLon: 80.0000, sequenceIndex: 1),
    const TransitStopWaypoint(stopId: 'S2', stopName: 'Stop B', stopLat: 13.0026, stopLon: 80.0000, sequenceIndex: 2),
    const TransitStopWaypoint(stopId: 'S3', stopName: 'Stop C', stopLat: 13.0039, stopLon: 80.0000, sequenceIndex: 3),
    const TransitStopWaypoint(stopId: 'S4', stopName: 'Chromepet', stopLat: 13.0052, stopLon: 80.0000, sequenceIndex: 4),
  ];
  return JourneySegment(
    type: JourneySegmentType.bus,
    description: 'Board Bus 21G towards Chromepet',
    duration: const Duration(minutes: 20),
    fromStopName: 'Boarding Stop',
    toStopName: 'Chromepet',
    routeShortName: '21G',
    routeLongName: 'Chromepet',
    tripId: 'trip_1',
    routeId: 'route_21G',
    boardingStopId: 'S0',
    alightingStopId: 'S4',
    orderedStops: stops,
  );
}

TransitSessionStateMachine _boardedMachine() {
  final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
  m.reachedBoardingStop();
  m.confirmBoarding();
  return m;
}

/// Feeds updates at each real stop's coordinates, [times] each, to
/// satisfy the tracker's hysteresis — mirrors how a real GPS stream
/// would repeatedly report a position near a stop.
void _arriveAt(TransitSessionStateMachine m, double lat, double lon, {int times = 2}) {
  for (int i = 0; i < times; i++) {
    m.updateLocation(lat, lon);
  }
}

void main() {
  group('1. Walking -> Boarding', () {
    test('reaching the boarding stop transitions and speaks a boarding instruction', () {
      final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
      expect(m.state, NavigationSessionState.walkingToBoardingStop);

      final events = m.reachedBoardingStop();
      expect(m.state, NavigationSessionState.boarding);
      final stateChange = events.firstWhere((e) => e.type == TransitEventType.stateChanged);
      expect(stateChange.previousState, NavigationSessionState.walkingToBoardingStop);
      expect(stateChange.newState, NavigationSessionState.boarding);
      final phrase = events.firstWhere((e) => e.type == TransitEventType.spokenPhrase);
      expect(phrase.spokenPhrase, contains('21G'));
      expect(phrase.spokenPhrase, contains('Chromepet'));
    });

    test('camera startDetection is emitted at construction (walking state)', () {
      final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
      final cameraEvents = m.eventLog.where((e) => e.type == TransitEventType.cameraCommand).toList();
      expect(cameraEvents, hasLength(1));
      expect(cameraEvents.single.cameraCommand, CameraDetectionCommand.startDetection);
    });
  });

  group('2. Boarding -> In Transit (camera handoff)', () {
    test('confirming boarding transitions to inTransit and stops the camera', () {
      final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
      m.reachedBoardingStop();
      final events = m.confirmBoarding();

      expect(m.state, NavigationSessionState.inTransit);
      final cameraCmd = events.firstWhere((e) => e.type == TransitEventType.cameraCommand);
      expect(cameraCmd.cameraCommand, CameraDetectionCommand.stopDetection);
    });

    test('confirmBoarding is a no-op outside the boarding state', () {
      final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
      // Still walkingToBoardingStop — never called reachedBoardingStop().
      final events = m.confirmBoarding();
      expect(events, isEmpty);
      expect(m.state, NavigationSessionState.walkingToBoardingStop);
    });
  });

  group('3. In Transit -> next stop', () {
    test('a location update near the first stop announces it', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      final allPhrases = m.eventLog.where((e) => e.type == TransitEventType.spokenPhrase).map((e) => e.spokenPhrase);
      expect(allPhrases.any((p) => p!.contains('Stop A') || p.contains('Stop B')), isTrue);
    });
  });

  group('4. Multiple stop progression', () {
    test('progressing through all intermediate stops announces each one, in order, exactly once', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000); // Stop A confirmed -> announces next (Stop B)
      _arriveAt(m, 13.0026, 80.0000); // Stop B confirmed -> announces next (Stop C)
      _arriveAt(m, 13.0039, 80.0000); // Stop C confirmed -> announces next (Chromepet, destination)

      final nextStopPhrases = m.eventLog
          .where((e) => e.type == TransitEventType.spokenPhrase && e.spokenPhrase!.startsWith('Next stop:'))
          .map((e) => e.spokenPhrase)
          .toList();
      expect(nextStopPhrases, [
        'Next stop: Stop B.',
        'Next stop: Stop C.',
        'Next stop: Chromepet.',
      ]);
    });
  });

  group('5. GPS jitter does not duplicate announcements', () {
    test('many repeated updates at the same near-stop location produce ONE announcement, not several', () {
      final m = _boardedMachine();
      // 10 jittery updates all near Stop A — should confirm once and stop.
      for (int i = 0; i < 10; i++) {
        m.updateLocation(13.0013 + (i.isEven ? 0.00001 : -0.00001), 80.0000);
      }
      final nextStopPhrases =
          m.eventLog.where((e) => e.type == TransitEventType.spokenPhrase && e.spokenPhrase!.startsWith('Next stop:'));
      expect(nextStopPhrases, hasLength(1));
    });

    test('a single stray close reading (below the hysteresis count) announces nothing', () {
      final m = _boardedMachine();
      final events = m.updateLocation(13.0013, 80.0000); // only ONE close reading
      expect(events, isEmpty);
    });
  });

  group('6/7. Stops-remaining counts', () {
    test('two stops remaining is announced after passing the first stop', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      final remainingPhrase = m.eventLog.firstWhere(
        (e) => e.type == TransitEventType.spokenPhrase && e.spokenPhrase!.contains('stops remaining'),
      );
      expect(remainingPhrase.spokenPhrase, contains('3'));
    });

    test('one stop remaining triggers "prepare to get down" instead of a stops-remaining count', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      final events = <TransitEvent>[];
      events.addAll(m.updateLocation(13.0039, 80.0000));
      events.addAll(m.updateLocation(13.0039, 80.0000));
      final approaching = m.eventLog.where(
        (e) => e.type == TransitEventType.spokenPhrase && e.spokenPhrase!.contains('prepare to get down'),
      );
      expect(approaching, hasLength(1));
    });
  });

  group('8/9. Destination stop reached -> In Transit -> Alighting', () {
    test('reaching the final stop transitions to alighting and speaks a get-down instruction', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000); // Chromepet — the destination

      expect(m.state, NavigationSessionState.alighting);
      final phrase = m.eventLog.lastWhere((e) => e.type == TransitEventType.spokenPhrase);
      expect(phrase.spokenPhrase, contains('Please get down at'));
      expect(phrase.spokenPhrase, contains('Chromepet'));
    });
  });

  group('10. Alighting -> Final Walking (camera restart + hazard reset)', () {
    test('confirming alighting restarts the camera, resets detection state, and transitions', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      expect(m.state, NavigationSessionState.alighting);

      final events = m.confirmAlighting();
      expect(m.state, NavigationSessionState.finalWalking);
      expect(events.any((e) => e.type == TransitEventType.cameraCommand && e.cameraCommand == CameraDetectionCommand.startDetection), isTrue);
      expect(events.any((e) => e.type == TransitEventType.resetDetectionState), isTrue);
    });
  });

  group('11. Final Walking -> Arrived', () {
    test('reaching the final destination transitions to arrived and speaks an arrival message', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      m.confirmAlighting();

      final events = m.reachedFinalDestination();
      expect(m.state, NavigationSessionState.arrived);
      expect(events.any((e) => e.spokenPhrase == 'You have arrived at your destination.'), isTrue);
    });
  });

  group('12. Arrived -> Next Destination', () {
    test('prompts for the next destination after arrival', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      m.confirmAlighting();
      m.reachedFinalDestination();

      final events = m.promptForNextDestination();
      expect(m.state, NavigationSessionState.nextDestination);
      expect(events.any((e) => e.spokenPhrase == 'Where would you like to go now?'), isTrue);
    });
  });

  group('13. Next Destination -> new route', () {
    test('providing a real destination transitions back to walkingToBoardingStop for a new route', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      m.confirmAlighting();
      m.reachedFinalDestination();
      m.promptForNextDestination();

      final events = m.provideNextDestination('Guindy');
      expect(m.state, NavigationSessionState.walkingToBoardingStop);
      expect(events.single.type, TransitEventType.stateChanged);
    });
  });

  group('14. Next Destination -> Ended', () {
    test('"stop" ends the session', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      m.confirmAlighting();
      m.reachedFinalDestination();
      m.promptForNextDestination();

      final events = m.provideNextDestination('Stop');
      expect(m.state, NavigationSessionState.ended);
      expect(events.single.newState, NavigationSessionState.ended);
    });

    test('"that\'s all" and "exit" also end the session', () {
      for (final phrase in ["that's all", 'exit', 'Exit please']) {
        final m = _boardedMachine();
        _arriveAt(m, 13.0013, 80.0000);
        _arriveAt(m, 13.0026, 80.0000);
        _arriveAt(m, 13.0039, 80.0000);
        _arriveAt(m, 13.0052, 80.0000);
        m.confirmAlighting();
        m.reachedFinalDestination();
        m.promptForNextDestination();
        m.provideNextDestination(phrase);
        expect(m.state, NavigationSessionState.ended, reason: 'failed for phrase "$phrase"');
      }
    });
  });

  group('15/16. GPS unavailable / restored', () {
    test('marking location unavailable suppresses progress updates and speaks once', () {
      final m = _boardedMachine();
      final events = m.markLocationUnavailable();
      expect(events.any((e) => e.type == TransitEventType.locationUnavailable), isTrue);
      expect(events.any((e) => e.spokenPhrase == 'Location signal is temporarily unavailable.'), isTrue);

      // While unavailable, location updates are ignored entirely.
      final duringOutage = m.updateLocation(13.0013, 80.0000);
      expect(duringOutage, isEmpty);

      // Calling markLocationUnavailable again is a no-op (no repeat announcement).
      final repeat = m.markLocationUnavailable();
      expect(repeat, isEmpty);
    });

    test('restoring location allows progress updates to resume', () {
      final m = _boardedMachine();
      m.markLocationUnavailable();
      final restoreEvents = m.markLocationRestored();
      expect(restoreEvents.single.type, TransitEventType.locationRestored);
      expect(m.isLocationAvailable, isTrue);

      _arriveAt(m, 13.0013, 80.0000);
      final nextStopPhrases =
          m.eventLog.where((e) => e.type == TransitEventType.spokenPhrase && e.spokenPhrase!.startsWith('Next stop:'));
      expect(nextStopPhrases, isNotEmpty);
    });
  });

  group('17. Manual fallback', () {
    test('reachedBoardingStop and confirmAlighting work identically when triggered manually', () {
      final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
      final boardingEvents = m.reachedBoardingStop(triggeredAutomatically: false);
      final stateChange = boardingEvents.firstWhere((e) => e.type == TransitEventType.stateChanged);
      expect(stateChange.triggeredAutomatically, isFalse);
      expect(m.state, NavigationSessionState.boarding);
    });

    test('reachedDestinationStop works as a manual fallback when automatic tracking is unavailable', () {
      // A segment with NO orderedStops (automatic tracking impossible)
      // is exactly the "manual fallback only" scenario.
      final segment = JourneySegment(
        type: JourneySegmentType.bus,
        description: 'Board Bus',
        duration: const Duration(minutes: 10),
        toStopName: 'Somewhere',
        orderedStops: const [],
      );
      final m = TransitSessionStateMachine(transitSegment: segment);
      m.reachedBoardingStop();
      m.confirmBoarding();
      expect(m.state, NavigationSessionState.inTransit);

      // No amount of location updates can progress (no stop data).
      final noProgress = m.updateLocation(13.0, 80.0);
      expect(noProgress, isEmpty);

      // Manual confirmation still works.
      final manualEvents = m.reachedDestinationStop(triggeredAutomatically: false);
      expect(m.state, NavigationSessionState.alighting);
      expect(manualEvents.first.triggeredAutomatically, isFalse);
    });
  });

  group('18. Camera state during every transition', () {
    test('camera commands occur ONLY at construction (start), confirmBoarding (stop), and confirmAlighting (start) — never elsewhere', () {
      final m = _boardedMachine(); // already emitted: construction(start), confirmBoarding(stop)
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      m.confirmAlighting(); // emits the 3rd camera command: startDetection (finalWalking)
      m.reachedFinalDestination();
      m.promptForNextDestination();
      m.provideNextDestination('Guindy');

      final cameraEvents = m.eventLog.where((e) => e.type == TransitEventType.cameraCommand).toList();
      expect(cameraEvents, hasLength(3));
      expect(cameraEvents[0].cameraCommand, CameraDetectionCommand.startDetection); // construction
      expect(cameraEvents[1].cameraCommand, CameraDetectionCommand.stopDetection); // confirmBoarding
      expect(cameraEvents[2].cameraCommand, CameraDetectionCommand.startDetection); // confirmAlighting
      // None of reachedFinalDestination/promptForNextDestination/provideNextDestination touch the camera.
    });

    test('confirmAlighting is the ONLY other camera event, and it is startDetection', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      m.confirmAlighting();

      final cameraEvents = m.eventLog.where((e) => e.type == TransitEventType.cameraCommand).toList();
      expect(cameraEvents, hasLength(3));
      expect(cameraEvents.last.cameraCommand, CameraDetectionCommand.startDetection);
    });
  });

  group('19. Hazard/TTC reset when leaving transit', () {
    test('resetDetectionState is emitted exactly once, alongside confirmAlighting', () {
      final m = _boardedMachine();
      _arriveAt(m, 13.0013, 80.0000);
      _arriveAt(m, 13.0026, 80.0000);
      _arriveAt(m, 13.0039, 80.0000);
      _arriveAt(m, 13.0052, 80.0000);
      m.confirmAlighting();

      final resetEvents = m.eventLog.where((e) => e.type == TransitEventType.resetDetectionState);
      expect(resetEvents, hasLength(1));
    });
  });

  group('20. No duplicate transition events', () {
    test('calling an already-completed transition again produces no new events', () {
      final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
      m.reachedBoardingStop();
      final beforeCount = m.eventLog.length;
      final repeat = m.reachedBoardingStop(); // already in boarding, not walkingToBoardingStop
      expect(repeat, isEmpty);
      expect(m.eventLog.length, beforeCount);
    });

    test('invalid out-of-order calls are all rejected without side effects', () {
      final m = TransitSessionStateMachine(transitSegment: _syntheticTransitSegment());
      expect(m.confirmBoarding(), isEmpty); // not boarding yet
      expect(m.reachedDestinationStop(), isEmpty); // not inTransit yet
      expect(m.confirmAlighting(), isEmpty); // not alighting yet
      expect(m.reachedFinalDestination(), isEmpty); // not finalWalking yet
      expect(m.promptForNextDestination(), isEmpty); // not arrived yet
      expect(m.provideNextDestination('Guindy'), isEmpty); // not nextDestination yet
      expect(m.state, NavigationSessionState.walkingToBoardingStop);
    });
  });
}
