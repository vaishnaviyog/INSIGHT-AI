import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/detected_hazard.dart';
import 'package:vaishnavi/services/hazard_detectors/collision_time_estimator.dart';

DetectedHazard _hazard(String label, double? distance) => DetectedHazard(
      label: label,
      priority: HazardPriority.critical,
      confidence: 0.9,
      distanceBand: DistanceBand.near,
      sourceDetector: 'test',
      estimatedDistanceMeters: distance,
    );

void main() {
  group('CollisionTimeEstimator', () {
    test('first observation of a label returns null TTC', () {
      final estimator = CollisionTimeEstimator();
      final result = estimator.annotate([_hazard('car', 10.0)]);
      expect(result.single.timeToCollisionSeconds, isNull);
    });

    test('approaching object (distance decreasing) yields positive TTC', () async {
      final estimator = CollisionTimeEstimator();
      estimator.annotate([_hazard('car', 10.0)]);
      // Real dt is used internally via DateTime.now(); simulate a
      // later frame by waiting briefly so dt > 0. The wait must be
      // long enough, relative to the distance drop, that the implied
      // closing speed stays under
      // _maxPlausibleClosingSpeedMetersPerSecond (15 m/s) — otherwise
      // this looks like a same-label identity switch rather than a
      // genuine approach (see the P1-13 tests below). 2m over >=300ms
      // is <=6.67 m/s, safely under the cap regardless of scheduling
      // jitter (Future.delayed only guarantees a lower bound on dt).
      await Future.delayed(const Duration(milliseconds: 300));
      final second = estimator.annotate([_hazard('car', 8.0)]);
      final ttc = second.single.timeToCollisionSeconds;
      expect(ttc, isNotNull);
      expect(ttc, greaterThan(0));
    });

    test('stationary object (same distance) yields null TTC, not infinity', () async {
      final estimator = CollisionTimeEstimator();
      estimator.annotate([_hazard('car', 10.0)]);
      await Future.delayed(const Duration(milliseconds: 50));
      final second = estimator.annotate([_hazard('car', 10.0)]);
      expect(second.single.timeToCollisionSeconds, isNull);
    });

    test('receding object (distance increasing) yields null TTC, never negative', () async {
      final estimator = CollisionTimeEstimator();
      estimator.annotate([_hazard('car', 8.0)]);
      await Future.delayed(const Duration(milliseconds: 50));
      final second = estimator.annotate([_hazard('car', 10.0)]);
      expect(second.single.timeToCollisionSeconds, isNull);
    });

    test('hazard with no distance estimate is left untouched', () {
      final estimator = CollisionTimeEstimator();
      final result = estimator.annotate([_hazard('bench', null)]);
      expect(result.single.timeToCollisionSeconds, isNull);
    });

    test('a label that disappears and reappears is treated as a new first observation', () {
      final estimator = CollisionTimeEstimator();
      estimator.annotate([_hazard('car', 10.0)]);
      // 'car' absent this frame — its sample must be dropped.
      estimator.annotate([_hazard('bicycle', 5.0)]);
      final result = estimator.annotate([_hazard('car', 6.0)]);
      expect(result.single.timeToCollisionSeconds, isNull);
    });

    test('reset() clears tracked state so the next sample is a first observation', () async {
      final estimator = CollisionTimeEstimator();
      estimator.annotate([_hazard('car', 10.0)]);
      estimator.reset();
      await Future.delayed(const Duration(milliseconds: 50));
      final result = estimator.annotate([_hazard('car', 8.0)]);
      expect(result.single.timeToCollisionSeconds, isNull);
    });

    test('two different labels in the same frame are tracked independently', () async {
      final estimator = CollisionTimeEstimator();
      estimator.annotate([_hazard('car', 10.0), _hazard('bicycle', 5.0)]);
      // See the "approaching object" test above for why this needs to
      // be long enough to keep the implied closing speed under the
      // plausibility cap.
      await Future.delayed(const Duration(milliseconds: 300));
      final second = estimator.annotate([_hazard('car', 8.0), _hazard('bicycle', 5.0)]);
      final car = second.firstWhere((h) => h.label == 'car');
      final bike = second.firstWhere((h) => h.label == 'bicycle');
      expect(car.timeToCollisionSeconds, isNotNull); // approaching
      expect(bike.timeToCollisionSeconds, isNull); // stationary
    });

    test('P1-13: an implausibly large distance jump (likely a same-label identity switch) yields null, not a fabricated fast-approach TTC', () async {
      final estimator = CollisionTimeEstimator();
      // 'car' at 50m...
      estimator.annotate([_hazard('car', 50.0)]);
      await Future.delayed(const Duration(milliseconds: 50));
      // ...then 'car' at 1m barely 50ms later. Implied closing speed
      // is ~980 m/s — physically impossible for a real single object
      // in this scenario, far more likely two different cars.
      final second = estimator.annotate([_hazard('car', 1.0)]);
      expect(second.single.timeToCollisionSeconds, isNull);
    });

    test('P1-13: a genuinely fast but plausible approach still yields a TTC', () async {
      final estimator = CollisionTimeEstimator();
      estimator.annotate([_hazard('car', 20.0)]);
      await Future.delayed(const Duration(milliseconds: 200));
      // ~10 m/s closing speed over 200ms (20m -> ~18m) — fast but
      // within _maxPlausibleClosingSpeedMetersPerSecond (15 m/s).
      final second = estimator.annotate([_hazard('car', 18.0)]);
      expect(second.single.timeToCollisionSeconds, isNotNull);
    });
  });
}
