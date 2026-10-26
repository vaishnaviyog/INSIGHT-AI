import 'dart:math' as math;

/// TEST-ONLY GPS simulation harness (comprehensive safety/journey
/// simulation pass). Feeds SYNTHETIC location readings into the REAL,
/// unmodified production progress-tracking classes
/// (`TransitProgressTracker`, `FinalWalkingRouteTracker`,
/// `TransitSessionStateMachine`) — this file contains no navigation
/// logic of its own, only trace generation and geometry helpers. It is
/// never imported by `lib/`.
///
/// Not a permanent production capability — production still reads real
/// GPS via `Geolocator`. This exists purely so the existing pure
/// progress-tracking classes (which already accept plain
/// `double latitude, double longitude` — no platform dependency) can
/// be driven deterministically and repeatedly under adverse conditions
/// that are impractical or unsafe to reproduce by physically walking
/// Chennai streets.
class SimulatedGpsReading {
  final double latitude;
  final double longitude;
  final DateTime timestamp;
  final double? accuracyMeters;
  final double? speedMetersPerSecond;
  final double? headingDegrees;

  const SimulatedGpsReading({
    required this.latitude,
    required this.longitude,
    required this.timestamp,
    this.accuracyMeters,
    this.speedMetersPerSecond,
    this.headingDegrees,
  });

  @override
  String toString() => 'GPS(${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)} '
      '@ $timestamp${accuracyMeters != null ? ', ±${accuracyMeters!.toStringAsFixed(0)}m' : ''})';
}

/// Haversine distance in meters — deliberately the SAME formula
/// `TransitProgressTracker`/`FinalWalkingRouteTracker`/`RaptorRouter`
/// already use, reimplemented identically here ONLY so simulation
/// fixtures/assertions can compute real distances without importing a
/// private function from production files. Any test asserting
/// production behavior calls the production classes themselves, not
/// this — this is for constructing/verifying trace geometry only.
double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * (math.pi / 180.0);
  final dLon = (lon2 - lon1) * (math.pi / 180.0);
  final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180.0) * math.cos(lat2 * math.pi / 180.0) * math.sin(dLon / 2) * math.sin(dLon / 2);
  final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  return earthRadiusMeters * c;
}

/// Moves [meters] from ([lat], [lon]) along [bearingDegrees] (0 =
/// north, 90 = east), returning the new (lat, lon). Standard
/// destination-point-given-distance-and-bearing formula — used only to
/// build deterministic synthetic traces.
(double, double) _destinationPoint(double lat, double lon, double meters, double bearingDegrees) {
  const earthRadiusMeters = 6371000.0;
  final bearing = bearingDegrees * math.pi / 180.0;
  final latRad = lat * math.pi / 180.0;
  final lonRad = lon * math.pi / 180.0;
  final angularDistance = meters / earthRadiusMeters;

  final newLatRad = math.asin(
    math.sin(latRad) * math.cos(angularDistance) + math.cos(latRad) * math.sin(angularDistance) * math.cos(bearing),
  );
  final newLonRad = lonRad +
      math.atan2(
        math.sin(bearing) * math.sin(angularDistance) * math.cos(latRad),
        math.cos(angularDistance) - math.sin(latRad) * math.sin(newLatRad),
      );
  return (newLatRad * 180.0 / math.pi, newLonRad * 180.0 / math.pi);
}

/// A straight-line trace from (fromLat, fromLon) to (toLat, toLon) in
/// [steps] evenly-spaced readings (inclusive of both ends), one
/// [interval] apart starting at [start]. The basic building block every
/// other generator in this file starts from.
List<SimulatedGpsReading> straightLineTrace({
  required double fromLat,
  required double fromLon,
  required double toLat,
  required double toLon,
  required int steps,
  Duration interval = const Duration(seconds: 3),
  DateTime? start,
  double? accuracyMeters,
}) {
  final startTime = start ?? DateTime(2026, 1, 1, 9, 0, 0);
  final readings = <SimulatedGpsReading>[];
  for (int i = 0; i < steps; i++) {
    final t = steps <= 1 ? 1.0 : i / (steps - 1);
    readings.add(SimulatedGpsReading(
      latitude: fromLat + (toLat - fromLat) * t,
      longitude: fromLon + (toLon - fromLon) * t,
      timestamp: startTime.add(interval * i),
      accuracyMeters: accuracyMeters,
    ));
  }
  return readings;
}

/// Adds small random offsets (uniform up to [jitterMeters] in a random
/// direction) to every reading — simulates realistic consumer-GPS
/// jitter around a true position, per the explicit "small random
/// jitter" scenario requirement.
List<SimulatedGpsReading> withJitter(
  List<SimulatedGpsReading> trace, {
  required double jitterMeters,
  required math.Random random,
}) {
  return [
    for (final r in trace)
      () {
        final distance = random.nextDouble() * jitterMeters;
        final bearing = random.nextDouble() * 360.0;
        final (lat, lon) = _destinationPoint(r.latitude, r.longitude, distance, bearing);
        return SimulatedGpsReading(
          latitude: lat,
          longitude: lon,
          timestamp: r.timestamp,
          accuracyMeters: r.accuracyMeters ?? jitterMeters,
          speedMetersPerSecond: r.speedMetersPerSecond,
          headingDegrees: r.headingDegrees,
        );
      }(),
  ];
}

/// Inserts one wildly-incorrect reading (a large, fixed displacement
/// in a random direction) at [atIndex] — simulates a single GPS
/// multipath/reflection spike.
List<SimulatedGpsReading> withOneSpike(
  List<SimulatedGpsReading> trace, {
  required int atIndex,
  required double spikeMeters,
  required math.Random random,
}) {
  final copy = List<SimulatedGpsReading>.of(trace);
  if (atIndex < 0 || atIndex >= copy.length) return copy;
  final r = copy[atIndex];
  final bearing = random.nextDouble() * 360.0;
  final (lat, lon) = _destinationPoint(r.latitude, r.longitude, spikeMeters, bearing);
  copy[atIndex] = SimulatedGpsReading(
    latitude: lat,
    longitude: lon,
    timestamp: r.timestamp,
    accuracyMeters: spikeMeters,
    speedMetersPerSecond: r.speedMetersPerSecond,
    headingDegrees: r.headingDegrees,
  );
  return copy;
}

/// Removes readings in [range] entirely — simulates a temporary GPS
/// signal loss (no fixes delivered at all, not merely inaccurate
/// ones) for that stretch of the journey.
List<SimulatedGpsReading> withGap(List<SimulatedGpsReading> trace, {required int startIndex, required int count}) {
  final copy = List<SimulatedGpsReading>.of(trace);
  final end = math.min(startIndex + count, copy.length);
  if (startIndex < 0 || startIndex >= copy.length) return copy;
  copy.removeRange(startIndex, end);
  return copy;
}

/// A trace that approaches a target, moves back away, then approaches
/// again — the "close -> far -> close" and "far -> close -> close"
/// families of scenarios, expressed as reusable geometry rather than
/// per-test hand-written coordinates.
List<SimulatedGpsReading> approachRetreatApproach({
  required double targetLat,
  required double targetLon,
  required double startDistanceMeters,
  required double retreatToDistanceMeters,
  required double closeDistanceMeters,
  int stepsPerLeg = 5,
  double bearingFromTargetDegrees = 0,
  Duration interval = const Duration(seconds: 3),
  DateTime? start,
}) {
  final (farLat, farLon) = _destinationPoint(targetLat, targetLon, startDistanceMeters, bearingFromTargetDegrees);
  final (retreatLat, retreatLon) =
      _destinationPoint(targetLat, targetLon, retreatToDistanceMeters, bearingFromTargetDegrees);
  final (closeLat, closeLon) = _destinationPoint(targetLat, targetLon, closeDistanceMeters, bearingFromTargetDegrees);

  final startTime = start ?? DateTime(2026, 1, 1, 9, 0, 0);
  final leg1 = straightLineTrace(
      fromLat: farLat, fromLon: farLon, toLat: closeLat, toLon: closeLon, steps: stepsPerLeg, interval: interval, start: startTime);
  final leg2 = straightLineTrace(
    fromLat: closeLat,
    fromLon: closeLon,
    toLat: retreatLat,
    toLon: retreatLon,
    steps: stepsPerLeg,
    interval: interval,
    start: leg1.last.timestamp.add(interval),
  );
  final leg3 = straightLineTrace(
    fromLat: retreatLat,
    fromLon: retreatLon,
    toLat: targetLat,
    toLon: targetLon,
    steps: stepsPerLeg,
    interval: interval,
    start: leg2.last.timestamp.add(interval),
  );
  return [...leg1, ...leg2, ...leg3];
}

/// A trace that oscillates back and forth across a boundary distance
/// from [targetLat]/[targetLon] — simulates GPS noise straddling an
/// arrival-radius boundary exactly, which is the hardest case for any
/// hysteresis/consecutive-reading rule to get right.
List<SimulatedGpsReading> oscillateAroundRadius({
  required double targetLat,
  required double targetLon,
  required double radiusMeters,
  required int oscillations,
  double insideOffsetMeters = 5,
  double outsideOffsetMeters = 5,
  Duration interval = const Duration(seconds: 3),
  DateTime? start,
}) {
  final startTime = start ?? DateTime(2026, 1, 1, 9, 0, 0);
  final readings = <SimulatedGpsReading>[];
  for (int i = 0; i < oscillations; i++) {
    final insideDistance = (radiusMeters - insideOffsetMeters).clamp(0.0, double.infinity);
    final outsideDistance = radiusMeters + outsideOffsetMeters;
    final (inLat, inLon) = _destinationPoint(targetLat, targetLon, insideDistance, (i * 47) % 360);
    final (outLat, outLon) = _destinationPoint(targetLat, targetLon, outsideDistance, (i * 47 + 180) % 360);
    readings.add(SimulatedGpsReading(latitude: inLat, longitude: inLon, timestamp: startTime.add(interval * (i * 2))));
    readings.add(SimulatedGpsReading(latitude: outLat, longitude: outLon, timestamp: startTime.add(interval * (i * 2 + 1))));
  }
  return readings;
}

/// A single random point uniformly within [radiusMeters] of a center —
/// used by property/stress tests to generate varied traces from a
/// fixed seed.
(double, double) randomPointWithin(double centerLat, double centerLon, double radiusMeters, math.Random random) {
  final distance = random.nextDouble() * radiusMeters;
  final bearing = random.nextDouble() * 360.0;
  return _destinationPoint(centerLat, centerLon, distance, bearing);
}
