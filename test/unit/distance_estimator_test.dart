import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/detected_hazard.dart';
import 'package:vaishnavi/services/hazard_detectors/distance_estimator.dart';

void main() {
  group('DistanceEstimationConfig.estimateDistanceMeters', () {
    test('returns null for an unknown label (no configured height)', () {
      expect(DistanceEstimationConfig.estimateDistanceMeters('unicorn', 100.0), isNull);
    });

    test('returns null for non-positive bounding box height (never divides by zero)', () {
      expect(DistanceEstimationConfig.estimateDistanceMeters('car', 0.0), isNull);
      expect(DistanceEstimationConfig.estimateDistanceMeters('car', -5.0), isNull);
    });

    test('a larger bounding box height yields a smaller estimated distance', () {
      final near = DistanceEstimationConfig.estimateDistanceMeters('car', 200.0);
      final far = DistanceEstimationConfig.estimateDistanceMeters('car', 50.0);
      expect(near, isNotNull);
      expect(far, isNotNull);
      expect(near!, lessThan(far!));
    });

    test('result is always positive and finite for valid inputs', () {
      final distance = DistanceEstimationConfig.estimateDistanceMeters('person', 150.0);
      expect(distance, isNotNull);
      expect(distance!.isFinite, isTrue);
      expect(distance, greaterThan(0));
    });
  });

  group('DistanceEstimationConfig.calibrateFocalLengthPixels', () {
    test('returns null for any non-positive input rather than a nonsensical value', () {
      expect(
        DistanceEstimationConfig.calibrateFocalLengthPixels(
          knownObjectHeightMeters: 0,
          distanceMeters: 5,
          boundingBoxHeightPixels: 100,
        ),
        isNull,
      );
      expect(
        DistanceEstimationConfig.calibrateFocalLengthPixels(
          knownObjectHeightMeters: 1.7,
          distanceMeters: -1,
          boundingBoxHeightPixels: 100,
        ),
        isNull,
      );
      expect(
        DistanceEstimationConfig.calibrateFocalLengthPixels(
          knownObjectHeightMeters: 1.7,
          distanceMeters: 5,
          boundingBoxHeightPixels: 0,
        ),
        isNull,
      );
    });

    test('returns a positive finite value for valid measurements', () {
      final focal = DistanceEstimationConfig.calibrateFocalLengthPixels(
        knownObjectHeightMeters: 1.7,
        distanceMeters: 5.0,
        boundingBoxHeightPixels: 238.0,
      );
      expect(focal, isNotNull);
      expect(focal!.isFinite, isTrue);
      expect(focal, greaterThan(0));
    });
  });

  group('DistanceEstimationConfig.distanceBandForMeters', () {
    test('boundaries map to the expected bands', () {
      expect(DistanceEstimationConfig.distanceBandForMeters(1.0), DistanceBand.veryNear);
      expect(DistanceEstimationConfig.distanceBandForMeters(3.0), DistanceBand.near);
      expect(DistanceEstimationConfig.distanceBandForMeters(6.0), DistanceBand.far);
      expect(DistanceEstimationConfig.distanceBandForMeters(20.0), DistanceBand.unknown);
    });
  });
}
