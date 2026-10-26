import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:vaishnavi/models/journey/journey.dart';
import 'package:vaishnavi/models/journey/journey_segment.dart';
import 'package:vaishnavi/services/journey/journey_walking_enrichment.dart';
import 'package:vaishnavi/services/location_service.dart';

/// Stands in for real network routing — returns a fixed, caller-
/// controlled distance instead of calling OSRM/ORS, so this test is
/// fast, deterministic, and offline, matching every other test in this
/// project's suite.
class _FakeLocationService extends LocationService {
  _FakeLocationService(this.fixedDistanceMeters);
  final double? fixedDistanceMeters;
  int callCount = 0;

  @override
  Future<RouteData?> getRouteInstructions(Position start, double endLat, double endLon) async {
    callCount++;
    if (fixedDistanceMeters == null) return null;
    return RouteData([], [], totalDistanceMeters: fixedDistanceMeters);
  }
}

void main() {
  group('enrichJourneyWalkingLegs', () {
    test('replaces a walking segment\'s straight-line estimate with the real routed distance', () async {
      final journey = Journey(
        segments: [
          JourneySegment(
            type: JourneySegmentType.walking,
            description: 'Walk to Stop A',
            duration: const Duration(minutes: 1),
            walkingDistanceMeters: 62, // the straight-line estimate from the real bug report
            toLat: 12.95,
            toLon: 80.14,
          ),
          JourneySegment(
            type: JourneySegmentType.train,
            description: 'Board Train X',
            duration: const Duration(minutes: 10),
            routeShortName: 'X',
          ),
        ],
        departureTime: DateTime(2026, 1, 1, 9, 0),
        arrivalTime: DateTime(2026, 1, 1, 9, 11),
        totalTravelTime: const Duration(minutes: 11),
        totalWalkingDistanceMeters: 62,
        transferCount: 0,
      );

      // The real reported case: straight-line said 900m, the actual
      // street-level walk (crossing a road properly, not through a
      // building) is meaningfully longer.
      final fakeLocationService = _FakeLocationService(1450.0);

      final result = await enrichJourneyWalkingLegs(
        journey: journey,
        originLat: 12.9434,
        originLon: 80.1429,
        locationService: fakeLocationService,
      );

      expect(result.journey.segments.first.walkingDistanceMeters, 1450.0,
          reason: 'the walking segment itself must show the real routed distance, not the straight-line estimate');
      expect(result.journey.totalWalkingDistanceMeters, 1450.0,
          reason: 'the journey-level total must reflect the same correction, not the stale sum');
      // Schedule-locked fields must be completely untouched — see the
      // module's own doc comment for why retiming is out of scope.
      expect(result.journey.departureTime, journey.departureTime);
      expect(result.journey.arrivalTime, journey.arrivalTime);
      expect(result.journey.totalTravelTime, journey.totalTravelTime);
      expect(result.journey.segments.last.duration, journey.segments.last.duration);
    });

    test('falls back to the original estimate when real routing is unavailable', () async {
      final journey = Journey(
        segments: [
          JourneySegment(
            type: JourneySegmentType.walking,
            description: 'Walk to Stop A',
            duration: const Duration(minutes: 1),
            walkingDistanceMeters: 62,
            toLat: 12.95,
            toLon: 80.14,
          ),
        ],
        departureTime: DateTime(2026, 1, 1, 9, 0),
        arrivalTime: DateTime(2026, 1, 1, 9, 1),
        totalTravelTime: const Duration(minutes: 1),
        totalWalkingDistanceMeters: 62,
        transferCount: 0,
      );
      final fakeLocationService = _FakeLocationService(null);

      final result = await enrichJourneyWalkingLegs(
        journey: journey,
        originLat: 12.9434,
        originLon: 80.1429,
        locationService: fakeLocationService,
      );

      expect(result.journey.segments.first.walkingDistanceMeters, 62,
          reason: 'no real route available — must keep the original estimate, never fabricate a distance');
      expect(result.journey.totalWalkingDistanceMeters, 62);
    });

    test('flags firstWalkLikelyExceedsSchedule when the real first-walk time exceeds the original estimate',
        () async {
      final journey = Journey(
        segments: [
          JourneySegment(
            type: JourneySegmentType.walking,
            description: 'Walk to Stop A',
            duration: const Duration(seconds: 60), // implies ~1 m/s for the 62m estimate
            walkingDistanceMeters: 62,
            toLat: 12.95,
            toLon: 80.14,
          ),
        ],
        departureTime: DateTime(2026, 1, 1, 9, 0),
        arrivalTime: DateTime(2026, 1, 1, 9, 1),
        totalTravelTime: const Duration(minutes: 1),
        totalWalkingDistanceMeters: 62,
        transferCount: 0,
      );
      // A real distance far longer than the estimate, at the same
      // implied speed, clearly takes longer than the original 60s.
      final fakeLocationService = _FakeLocationService(1450.0);

      final result = await enrichJourneyWalkingLegs(
        journey: journey,
        originLat: 12.9434,
        originLon: 80.1429,
        locationService: fakeLocationService,
      );

      expect(result.firstWalkLikelyExceedsSchedule, isTrue);
    });

    test('does not call real routing for segments with no toLat/toLon (nothing to route to)', () async {
      final journey = Journey(
        segments: [
          JourneySegment(
            type: JourneySegmentType.bus,
            description: 'Board Bus 1',
            duration: const Duration(minutes: 5),
            routeShortName: '1',
          ),
        ],
        departureTime: DateTime(2026, 1, 1, 9, 0),
        arrivalTime: DateTime(2026, 1, 1, 9, 5),
        totalTravelTime: const Duration(minutes: 5),
        totalWalkingDistanceMeters: 0,
        transferCount: 0,
      );
      final fakeLocationService = _FakeLocationService(1450.0);

      await enrichJourneyWalkingLegs(
        journey: journey,
        originLat: 12.9434,
        originLon: 80.1429,
        locationService: fakeLocationService,
      );

      expect(fakeLocationService.callCount, 0,
          reason: 'a non-walking segment with no walking distance must never trigger a routing call');
    });
  });
}
