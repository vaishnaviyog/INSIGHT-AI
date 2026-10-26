import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/detected_hazard.dart';
import 'package:vaishnavi/models/risk_assessment.dart';
import 'package:vaishnavi/services/risk_assessment_service.dart';

void main() {
  final service = RiskAssessmentService();

  group('RiskAssessmentService.assess — missing-value handling', () {
    test('a call with every parameter null still returns a valid, low assessment', () {
      final result = service.assess();
      expect(result.overallRiskScore, greaterThanOrEqualTo(0.0));
      expect(result.overallRiskScore, lessThanOrEqualTo(1.0));
      expect(result.riskLevel, RiskLevel.low);
      expect(result.explanation, isNotEmpty);
    });

    test('overall score is always clamped to [0, 1]', () {
      final hazard = DetectedHazard(
        label: 'car',
        priority: HazardPriority.critical,
        confidence: 1.0,
        distanceBand: DistanceBand.veryNear,
        sourceDetector: 'test',
        timeToCollisionSeconds: 0.5,
      );
      final result = service.assess(hazard: hazard, currentSpeedMetersPerSecond: 5.0);
      expect(result.overallRiskScore, greaterThanOrEqualTo(0.0));
      expect(result.overallRiskScore, lessThanOrEqualTo(1.0));
    });
  });

  group('RiskAssessmentService.assess — hazard factor ordering', () {
    test('a closer hazard (veryNear) scores higher than a farther one (far), all else equal', () {
      final near = DetectedHazard(
        label: 'car',
        priority: HazardPriority.critical,
        confidence: 0.9,
        distanceBand: DistanceBand.veryNear,
        sourceDetector: 'test',
      );
      final far = DetectedHazard(
        label: 'car',
        priority: HazardPriority.critical,
        confidence: 0.9,
        distanceBand: DistanceBand.far,
        sourceDetector: 'test',
      );
      final nearResult = service.assess(hazard: near);
      final farResult = service.assess(hazard: far);
      expect(nearResult.overallRiskScore, greaterThan(farResult.overallRiskScore));
    });

    test('a short TTC increases risk over the same hazard with no TTC data', () {
      final withoutTtc = DetectedHazard(
        label: 'car',
        priority: HazardPriority.critical,
        confidence: 0.9,
        distanceBand: DistanceBand.near,
        sourceDetector: 'test',
      );
      final withShortTtc = DetectedHazard(
        label: 'car',
        priority: HazardPriority.critical,
        confidence: 0.9,
        distanceBand: DistanceBand.near,
        sourceDetector: 'test',
        timeToCollisionSeconds: 1.0,
      );
      final baseline = service.assess(hazard: withoutTtc);
      final withTtc = service.assess(hazard: withShortTtc);
      expect(withTtc.overallRiskScore, greaterThan(baseline.overallRiskScore));
    });

    test('an informational-priority hazard never reaches critical risk level on its own', () {
      final bench = DetectedHazard(
        label: 'bench',
        priority: HazardPriority.informational,
        confidence: 0.7,
        distanceBand: DistanceBand.near,
        sourceDetector: 'test',
      );
      final result = service.assess(hazard: bench);
      expect(result.riskLevel, isNot(RiskLevel.critical));
    });

    test('risk factor weights sum to 1.0 (documented invariant)', () {
      final result = service.assess();
      final totalWeight = result.riskFactors.fold<double>(0.0, (sum, f) => sum + f.weight);
      expect(totalWeight, closeTo(1.0, 0.0001));
    });
  });

  group('RiskAssessmentService.assess — explanation', () {
    test('a call with nothing known still produces a non-empty explanation', () {
      // NOTE: with no profile, the Route Familiarity factor defaults to
      // "unfamiliar" (score 1.0 — see _familiarityFactor's null-profile
      // branch), so this is NOT the "no significant risk factors" case;
      // it correctly explains itself via that default instead.
      final result = service.assess();
      expect(result.explanation, isNotEmpty);
      expect(result.explanation, contains('unfamiliar route'));
    });

    test('a critical hazard produces a non-generic explanation mentioning it', () {
      final hazard = DetectedHazard(
        label: 'truck',
        priority: HazardPriority.critical,
        confidence: 0.95,
        distanceBand: DistanceBand.veryNear,
        sourceDetector: 'test',
      );
      final result = service.assess(hazard: hazard);
      expect(result.explanation, contains('truck'));
    });
  });
}
