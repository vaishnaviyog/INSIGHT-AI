import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/detected_hazard.dart';
import 'package:vaishnavi/services/hazard_temporal_filter.dart';

DetectedHazard _hazard(String label, {double confidence = 0.9}) => DetectedHazard(
      label: label,
      priority: HazardPriority.critical,
      confidence: confidence,
      distanceBand: DistanceBand.near,
      sourceDetector: 'test',
    );

void main() {
  group('HazardTemporalFilter', () {
    test('a single-frame flicker never gets confirmed', () {
      final filter = HazardTemporalFilter(requiredConsecutiveFrames: 3);
      expect(filter.confirm([_hazard('car')]), isEmpty);
      // Disappears immediately — streak resets per the documented
      // "strict, not a grace period" behavior.
      expect(filter.confirm([]), isEmpty);
      expect(filter.confirm([_hazard('car')]), isEmpty); // streak restarts at 1
    });

    test('a hazard present for the required consecutive frames is confirmed', () {
      final filter = HazardTemporalFilter(requiredConsecutiveFrames: 3);
      expect(filter.confirm([_hazard('car')]), isEmpty); // 1
      expect(filter.confirm([_hazard('car')]), isEmpty); // 2
      final result = filter.confirm([_hazard('car')]); // 3 — confirmed
      expect(result, hasLength(1));
      expect(result.single.label, 'car');
    });

    test('a gap resets the streak even after two consecutive frames', () {
      final filter = HazardTemporalFilter(requiredConsecutiveFrames: 3);
      filter.confirm([_hazard('car')]); // 1
      filter.confirm([_hazard('car')]); // 2
      filter.confirm([]); // gap — resets
      filter.confirm([_hazard('car')]); // restart at 1
      final result = filter.confirm([_hazard('car')]); // 2 — not yet confirmed
      expect(result, isEmpty);
    });

    test('two different labels are tracked independently', () {
      final filter = HazardTemporalFilter(requiredConsecutiveFrames: 2);
      filter.confirm([_hazard('car')]); // car: 1
      filter.confirm([_hazard('car'), _hazard('bicycle')]); // car: 2 (confirmed), bicycle: 1
      final result = filter.confirm([_hazard('bicycle')]); // bicycle: 2 (confirmed)
      expect(result.map((h) => h.label), contains('bicycle'));
    });

    test('a duplicate label within one frame only increments the streak once', () {
      final filter = HazardTemporalFilter(requiredConsecutiveFrames: 2);
      // Two cars in the same frame — must not fast-track confirmation
      // to 1 frame by counting both.
      filter.confirm([_hazard('car'), _hazard('car')]);
      final result = filter.confirm([_hazard('car')]);
      expect(result, hasLength(1)); // confirmed on the 2nd frame, not the 1st
    });

    test('reset() clears all streaks', () {
      final filter = HazardTemporalFilter(requiredConsecutiveFrames: 2);
      filter.confirm([_hazard('car')]);
      filter.reset();
      final result = filter.confirm([_hazard('car')]);
      expect(result, isEmpty); // streak restarted from zero, not from 1
    });
  });
}
