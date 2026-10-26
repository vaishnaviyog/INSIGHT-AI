import 'package:geolocator/geolocator.dart';

import '../../models/journey/journey.dart';
import '../../models/journey/journey_segment.dart';
import '../location_service.dart';

/// AUDIT ADD (transit-journey walking-leg accuracy fix — "why should I
/// walk from Chrompet to Tambaram TB Hospital" investigation): every
/// walking/transfer leg inside a [Journey] was built from
/// `haversineDistanceMeters` — straight-line distance, with zero
/// awareness of real streets, highways, or railway crossings. For a
/// blind-pedestrian navigation app, a confidently-stated "62m walk"
/// that's actually blocked by a highway with no safe crossing is a
/// real safety problem, not just a cosmetic inaccuracy.
///
/// SCOPE, DELIBERATELY NARROW: this corrects each walking/transfer
/// segment's [JourneySegment.walkingDistanceMeters] (and the journey's
/// own [Journey.totalWalkingDistanceMeters]) using a real routing
/// engine (via [LocationService], already used elsewhere for the
/// walking-only fallback route). It does NOT recompute `duration`,
/// `departureTime`, or `arrivalTime` on any segment, and does NOT
/// retime the journey's scheduled transit legs. Those times are
/// locked to the real GTFS schedule (a bus/train departs when it
/// departs, not when the app decides a walk took longer) — correctly
/// handling "the real walk to the first stop takes longer than
/// estimated, so this scheduled departure may no longer be
/// achievable" is a genuine schedule-feasibility question, not a
/// display-accuracy one, and deliberately out of scope here. See
/// [firstWalkLikelyExceedsSchedule] below for a simple, honest signal
/// a caller can act on instead of silently re-timing anything.
///
/// Called ONCE, by the caller (`NavigationScreen`) on the small number
/// of journeys actually about to be shown to the user — never from
/// inside `JourneyPlannerService`/RAPTOR itself, which must stay fast
/// and network-free for its own correctness tests (400-pair stress
/// test, golden journeys) to remain deterministic and quick.
class JourneyWalkingEnrichmentResult {
  final Journey journey;

  /// True if the FIRST walking leg's real routed distance implies a
  /// walking time long enough that the journey's first scheduled
  /// departure may already be missed by the time the rider would
  /// realistically reach the boarding stop. A caller should surface
  /// this as a caution, not silently hide it — the same honesty
  /// principle `Journey.hasTightConnection` already follows for a
  /// different risk (a short transfer buffer).
  final bool firstWalkLikelyExceedsSchedule;

  const JourneyWalkingEnrichmentResult({
    required this.journey,
    required this.firstWalkLikelyExceedsSchedule,
  });
}

Future<JourneyWalkingEnrichmentResult> enrichJourneyWalkingLegs({
  required Journey journey,
  required double originLat,
  required double originLon,
  required LocationService locationService,
}) async {
  double currentLat = originLat;
  double currentLon = originLon;
  final newSegments = <JourneySegment>[];
  double walkingDistanceDelta = 0;
  bool firstWalkLikelyExceedsSchedule = false;
  bool isFirstWalkSegment = true;

  for (final segment in journey.segments) {
    final isWalkLikeSegment =
        (segment.type == JourneySegmentType.walking || segment.type == JourneySegmentType.transfer) &&
            segment.walkingDistanceMeters != null &&
            segment.toLat != null &&
            segment.toLon != null;

    if (!isWalkLikeSegment) {
      newSegments.add(segment);
      // Keep the position tracker current for the NEXT walking leg:
      // a transit segment's own last real stop (not estimated).
      if (segment.orderedStops.isNotEmpty) {
        final lastStop = segment.orderedStops.last;
        currentLat = lastStop.stopLat;
        currentLon = lastStop.stopLon;
      }
      continue;
    }

    RouteData? real;
    try {
      final fromPosition = Position(
        latitude: currentLat,
        longitude: currentLon,
        timestamp: DateTime.now(),
        accuracy: 5.0,
        altitude: 0.0,
        altitudeAccuracy: 0.0,
        heading: 0.0,
        headingAccuracy: 0.0,
        speed: 0.0,
        speedAccuracy: 0.0,
      );
      real = await locationService.getRouteInstructions(fromPosition, segment.toLat!, segment.toLon!);
    } catch (_) {
      real = null;
    }

    final realDistance = real?.totalDistanceMeters;
    if (realDistance == null || realDistance <= 0) {
      // Real routing unavailable (offline, provider error, no path
      // found) — keep the original straight-line estimate rather than
      // silently drop the segment or guess. Honest degradation, same
      // convention as every other "fall back to the estimate" path in
      // this codebase.
      newSegments.add(segment);
    } else {
      final oldDistance = segment.walkingDistanceMeters!;
      walkingDistanceDelta += realDistance - oldDistance;

      if (isFirstWalkSegment) {
        // Same implied walking speed the original estimate used (not
        // hardcoded — different user profiles/preferences can set a
        // different speed), so this check doesn't invent a new
        // assumption, just reapplies the existing one to the
        // corrected distance.
        final impliedSpeedMetersPerSecond =
            segment.duration.inSeconds > 0 ? oldDistance / segment.duration.inSeconds : 1.4;
        final realWalkSeconds = (realDistance / impliedSpeedMetersPerSecond).ceil();
        if (realWalkSeconds > segment.duration.inSeconds) {
          firstWalkLikelyExceedsSchedule = true;
        }
      }

      newSegments.add(JourneySegment(
        type: segment.type,
        description: segment.description,
        duration: segment.duration,
        fromStopName: segment.fromStopName,
        toStopName: segment.toStopName,
        routeShortName: segment.routeShortName,
        routeLongName: segment.routeLongName,
        tripId: segment.tripId,
        routeId: segment.routeId,
        boardingStopId: segment.boardingStopId,
        alightingStopId: segment.alightingStopId,
        orderedStops: segment.orderedStops,
        walkingDistanceMeters: realDistance,
        departureTime: segment.departureTime,
        arrivalTime: segment.arrivalTime,
        toLat: segment.toLat,
        toLon: segment.toLon,
        isInitialWait: segment.isInitialWait,
      ));
    }

    isFirstWalkSegment = false;
    currentLat = segment.toLat!;
    currentLon = segment.toLon!;
  }

  final enrichedJourney = Journey(
    segments: newSegments,
    departureTime: journey.departureTime,
    arrivalTime: journey.arrivalTime,
    totalTravelTime: journey.totalTravelTime,
    totalWalkingDistanceMeters: journey.totalWalkingDistanceMeters + walkingDistanceDelta,
    transferCount: journey.transferCount,
  );

  return JourneyWalkingEnrichmentResult(
    journey: enrichedJourney,
    firstWalkLikelyExceedsSchedule: firstWalkLikelyExceedsSchedule,
  );
}
