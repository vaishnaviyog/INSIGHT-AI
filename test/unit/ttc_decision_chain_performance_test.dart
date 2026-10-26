import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/adaptive_risk/adaptive_risk_input.dart';
import 'package:vaishnavi/models/detected_hazard.dart';
import 'package:vaishnavi/services/adaptive_risk/adaptive_risk_engine.dart';
import 'package:vaishnavi/services/adaptive_risk/navigation_decision_engine.dart';
import 'package:vaishnavi/services/adaptive_risk/warning_prioritizer.dart';
import 'package:vaishnavi/services/hazard_detectors/collision_time_estimator.dart';
import 'package:vaishnavi/services/hazard_temporal_filter.dart';
import 'package:vaishnavi/services/risk_assessment_service.dart';

void main() {
  test('PERF: detection -> TTC -> risk -> decision chain is negligible vs ~1.82s YOLO inference', () {
    final filter = HazardTemporalFilter(requiredConsecutiveFrames: 3);
    final ttc = CollisionTimeEstimator();
    final riskService = RiskAssessmentService();
    final adaptiveEngine = AdaptiveRiskEngine();
    final prioritizer = WarningPrioritizer();
    final decisionEngine = NavigationDecisionEngine();

    final hazard = DetectedHazard(
      label: 'car',
      priority: HazardPriority.critical,
      confidence: 0.9,
      distanceBand: DistanceBand.far,
      sourceDetector: 'test',
      estimatedDistanceMeters: 20.0,
    );

    filter.confirm([hazard]);
    filter.confirm([hazard]);

    final stopwatch = Stopwatch()..start();
    const iterations = 1000;
    for (int i = 0; i < iterations; i++) {
      final confirmed = filter.confirm([hazard]);
      final withTtc = ttc.annotate(confirmed);
      final top = withTtc.isNotEmpty ? withTtc.first : hazard;
      final risk = riskService.assess(hazard: top);
      final adaptive = adaptiveEngine.assess(AdaptiveRiskInput(topHazard: top), risk);
      final warning = prioritizer.prioritize(withTtc);
      decisionEngine.decide(
        risk: adaptive,
        warning: warning,
        transitPhase: TransitPhase.walking,
        awaitingVoiceConfirmation: false,
      );
    }
    stopwatch.stop();
    final perCallMicros = stopwatch.elapsedMicroseconds / iterations;
    print('Full TTC->risk->adaptive->warning->decision chain: ${perCallMicros.toStringAsFixed(1)} microseconds/call '
        '(${(perCallMicros / 1000).toStringAsFixed(4)} ms/call), $iterations iterations, '
        'total ${stopwatch.elapsedMilliseconds}ms');
    // Sanity bound: must be a tiny fraction of YOLO inference time.
    //
    // AUDIT FIX (Phase E6 — hazard-latency investigation): this bound
    // previously cited "2.05s" as the measured YOLO inference time —
    // that number was never actually measured anywhere in this
    // codebase; it was an assumed reference constant. The real,
    // in-source measured figure (4 CPU threads, OPPO CPH2421,
    // yolo_tflite_hazard_detector.dart's own benchmark comment) is
    // ~1.82s. Both numbers support the same conclusion this test
    // exists to prove — this decision chain (54 microseconds/call
    // measured here) is negligible next to EITHER figure — so the
    // assertion threshold (50ms) was never wrong, only the comment
    // explaining WHY 50ms is a safe bound. Corrected to the real
    // number rather than continuing to repeat the stale one.
    expect(perCallMicros, lessThan(50000), reason: 'must stay far below YOLO inference time (~1.82s = 1,820,000 microseconds)');
  });
}
