import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/journey/journey_segment.dart';
import 'package:vaishnavi/services/transit/transit_progress_tracker.dart';

List<TransitStopWaypoint> _threeStopLine() => const [
      TransitStopWaypoint(stopId: 'S0', stopName: 'Board', stopLat: 13.0000, stopLon: 80.0000, sequenceIndex: 0),
      TransitStopWaypoint(stopId: 'S1', stopName: 'Middle', stopLat: 13.0013, stopLon: 80.0000, sequenceIndex: 1),
      TransitStopWaypoint(stopId: 'S2', stopName: 'End', stopLat: 13.0026, stopLon: 80.0000, sequenceIndex: 2),
    ];

void main() {
  group('TransitProgressTracker — basic proximity + hysteresis', () {
    test('a single close reading does not confirm (needs requiredConsecutiveCloseUpdates)', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      final events = tracker.onLocationUpdate(13.0013, 80.0000);
      expect(events, isEmpty);
      expect(tracker.stopsRemaining, 2); // unchanged
    });

    test('two consecutive close readings (default requirement) confirm the stop', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(13.0013, 80.0000);
      final events = tracker.onLocationUpdate(13.0013, 80.0000);
      expect(events, isNotEmpty);
      expect(tracker.stopsRemaining, 1);
    });

    test('a reading far outside the arrival radius produces no events and no progress', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      final events = tracker.onLocationUpdate(14.0, 81.0); // far away
      expect(events, isEmpty);
      expect(tracker.stopsRemaining, 2);
    });
  });

  group('TransitProgressTracker — monotonic progress', () {
    test('progress never regresses even if a later reading is close to an earlier, already-passed stop', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(13.0013, 80.0000);
      tracker.onLocationUpdate(13.0013, 80.0000); // confirms "Middle" (index 1)
      expect(tracker.stopsRemaining, 1);

      // A jittery GPS fix lands back near the boarding stop (index 0)
      // — must NOT un-confirm progress.
      tracker.onLocationUpdate(13.0000, 80.0000);
      expect(tracker.stopsRemaining, 1);
    });

    test('close -> close -> advance (2 required consecutive close readings confirm)', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(13.0013, 80.0000);
      final events = tracker.onLocationUpdate(13.0013, 80.0000);
      expect(events, isNotEmpty);
      expect(tracker.stopsRemaining, 1);
    });

    test('close -> far -> close does NOT advance (the far reading resets the streak)', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(13.0013, 80.0000); // 1st close reading
      tracker.onLocationUpdate(20.0, 90.0); // far reading — resets streak
      final events = tracker.onLocationUpdate(13.0013, 80.0000); // only 1 close reading since the reset
      expect(events, isEmpty);
      expect(tracker.stopsRemaining, 2);
    });

    test('far -> close -> close advances (the leading far reading is irrelevant once the streak restarts)', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(20.0, 90.0); // far — no streak yet anyway
      tracker.onLocationUpdate(13.0013, 80.0000); // 1st close
      final events = tracker.onLocationUpdate(13.0013, 80.0000); // 2nd close — confirms
      expect(events, isNotEmpty);
      expect(tracker.stopsRemaining, 1);
    });

    test('repeated jitter that oscillates in/out of the radius never confirms until 2 TRUE consecutive closes occur', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      // close, far, close, far, close, far — never 2 in a row.
      for (int i = 0; i < 3; i++) {
        final events1 = tracker.onLocationUpdate(13.0013, 80.0000); // close
        expect(events1, isEmpty, reason: 'iteration $i: a single close reading must never confirm alone');
        tracker.onLocationUpdate(20.0, 90.0); // far — resets
      }
      expect(tracker.stopsRemaining, 2); // still not advanced
      // NOW two true consecutive closes:
      tracker.onLocationUpdate(13.0013, 80.0000);
      final finalEvents = tracker.onLocationUpdate(13.0013, 80.0000);
      expect(finalEvents, isNotEmpty);
      expect(tracker.stopsRemaining, 1);
    });

    test('destination-stop confirmation also requires genuinely consecutive close readings', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(13.0013, 80.0000);
      tracker.onLocationUpdate(13.0013, 80.0000); // Middle confirmed
      tracker.onLocationUpdate(13.0026, 80.0000); // 1st close toward End
      tracker.onLocationUpdate(20.0, 90.0); // far — resets the streak toward End
      final notYet = tracker.onLocationUpdate(13.0026, 80.0000); // only 1 close since reset
      expect(notYet, isEmpty);
      expect(tracker.destinationReached, isFalse);

      final confirmed = tracker.onLocationUpdate(13.0026, 80.0000); // 2nd true consecutive close
      expect(confirmed, isNotEmpty);
      expect(confirmed.single.type, TransitProgressEventType.destinationReached);
      expect(tracker.destinationReached, isTrue);
    });
  });

  group('TransitProgressTracker — destination reached', () {
    test('confirming the final stop sets destinationReached and stopsRemaining reaches 0', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(13.0013, 80.0000);
      tracker.onLocationUpdate(13.0013, 80.0000); // Middle confirmed
      tracker.onLocationUpdate(13.0026, 80.0000);
      final events = tracker.onLocationUpdate(13.0026, 80.0000); // End confirmed

      expect(tracker.destinationReached, isTrue);
      expect(tracker.stopsRemaining, 0);
      expect(events.single.type, TransitProgressEventType.destinationReached);
    });

    test('once destinationReached, further updates produce no events at all', () {
      final tracker = TransitProgressTracker(orderedStops: _threeStopLine());
      tracker.onLocationUpdate(13.0013, 80.0000);
      tracker.onLocationUpdate(13.0013, 80.0000);
      tracker.onLocationUpdate(13.0026, 80.0000);
      tracker.onLocationUpdate(13.0026, 80.0000);
      expect(tracker.destinationReached, isTrue);

      final events = tracker.onLocationUpdate(13.0026, 80.0000);
      expect(events, isEmpty);
    });
  });

  group('TransitProgressTracker — edge cases', () {
    test('an empty stop list produces no events for any location', () {
      final tracker = TransitProgressTracker(orderedStops: const []);
      final events = tracker.onLocationUpdate(13.0, 80.0);
      expect(events, isEmpty);
      expect(tracker.stopsRemaining, 0);
      expect(tracker.destinationReached, isFalse);
    });

    test('a single-stop list (boarding stop == destination) is already "reached"', () {
      final tracker = TransitProgressTracker(orderedStops: const [
        TransitStopWaypoint(stopId: 'S0', stopName: 'Only Stop', stopLat: 13.0, stopLon: 80.0, sequenceIndex: 0),
      ]);
      expect(tracker.destinationReached, isTrue);
      expect(tracker.onLocationUpdate(13.0, 80.0), isEmpty);
    });

    test('a custom arrivalRadiusMeters and requiredConsecutiveCloseUpdates are honored', () {
      final tracker = TransitProgressTracker(
        orderedStops: _threeStopLine(),
        arrivalRadiusMeters: 10.0, // much tighter than default
        requiredConsecutiveCloseUpdates: 1, // confirm on first close reading
      );
      // 13.0013 is exactly the stop's own coordinate — distance 0m, within 10m.
      final events = tracker.onLocationUpdate(13.0013, 80.0000);
      expect(events, isNotEmpty); // confirmed on the very first reading
    });
  });
}
