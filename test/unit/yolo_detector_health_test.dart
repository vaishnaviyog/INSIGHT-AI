import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/hazard_detectors/yolo_tflite_hazard_detector.dart';

Map<YoloDetectorCheck, bool> _allChecks({required bool value}) => {
      for (final c in YoloDetectorCheck.values) c: value,
    };

void main() {
  group('YoloDetectorHealth.computeInferenceReady — P0-1 regression', () {
    test('is true when all six prerequisites pass and there is no failure reason', () {
      final checks = _allChecks(value: true);
      // inferenceReady itself starts false in the map, exactly as it
      // does in real initialize() — this must NOT prevent readiness
      // from becoming true (that was the exact bug: the old formula
      // read `checks.values.every(...)`, which included this same
      // still-false entry).
      checks[YoloDetectorCheck.inferenceReady] = false;
      expect(YoloDetectorHealth.computeInferenceReady(checks, null), isTrue);
    });

    test('is false if any single prerequisite is false', () {
      for (final prerequisite in YoloDetectorHealth.prerequisiteChecks) {
        final checks = _allChecks(value: true);
        checks[prerequisite] = false;
        expect(
          YoloDetectorHealth.computeInferenceReady(checks, null),
          isFalse,
          reason: '$prerequisite=false should make readiness false',
        );
      }
    });

    test('is false whenever a failure reason is present, even if all prerequisites pass', () {
      final checks = _allChecks(value: true);
      expect(YoloDetectorHealth.computeInferenceReady(checks, 'some failure'), isFalse);
    });

    test('a map missing a prerequisite key entirely is treated as that check failing', () {
      final checks = _allChecks(value: true);
      checks.remove(YoloDetectorCheck.outputShapeValid);
      expect(YoloDetectorHealth.computeInferenceReady(checks, null), isFalse);
    });
  });

  group('YoloDetectorHealth.allPassed — consistency with the fixed formula', () {
    test('allPassed is true once inferenceReady is correctly computed as true', () {
      final checks = _allChecks(value: true);
      checks[YoloDetectorCheck.inferenceReady] =
          YoloDetectorHealth.computeInferenceReady(checks, null);
      final health = YoloDetectorHealth(checks: checks);
      expect(health.allPassed, isTrue);
      expect(health.statusMessage, 'YOLO object detection ready.');
    });

    test('allPassed is false and statusMessage explains why when a prerequisite failed', () {
      final checks = _allChecks(value: true);
      checks[YoloDetectorCheck.labelsLoaded] = false;
      checks[YoloDetectorCheck.inferenceReady] = YoloDetectorHealth.computeInferenceReady(
        checks,
        'Label file loaded but contained no labels.',
      );
      final health = YoloDetectorHealth(
        checks: checks,
        failureReason: 'Label file loaded but contained no labels.',
      );
      expect(health.allPassed, isFalse);
      expect(health.statusMessage, contains('YOLO object detection unavailable'));
      expect(health.statusMessage, contains('Label file loaded but contained no labels.'));
    });
  });
}
