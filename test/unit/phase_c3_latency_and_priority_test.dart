import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/adaptive_risk/adaptive_risk_assessment.dart';
import 'package:vaishnavi/models/adaptive_risk/adaptive_risk_input.dart';
import 'package:vaishnavi/models/adaptive_risk/navigation_decision.dart';
import 'package:vaishnavi/models/detected_hazard.dart';
import 'package:vaishnavi/models/risk_assessment.dart';
import 'package:vaishnavi/services/adaptive_risk/adaptive_risk_engine.dart';
import 'package:vaishnavi/services/adaptive_risk/navigation_decision_engine.dart';
import 'package:vaishnavi/services/adaptive_risk/warning_prioritizer.dart';
import 'package:vaishnavi/services/hazard_detectors/collision_time_estimator.dart';
import 'package:vaishnavi/services/hazard_temporal_filter.dart';
import 'package:vaishnavi/services/risk_assessment_service.dart';

/// PHASE C3 — WARNING LATENCY: TTS DECOUPLING + ADAPTIVE CONFIRMATION.
///
/// This file covers Part H's 16 deterministic scenarios and Part I's
/// 10 safety invariants, driving the REAL production decision pipeline
/// (HazardTemporalFilter -> CollisionTimeEstimator -> RiskAssessment
/// Service -> AdaptiveRiskEngine -> WarningPrioritizer ->
/// NavigationDecisionEngine) — none of these classes were modified in
/// Phase C3 (see the final report's Part E/F/G: adaptive confirmation
/// was investigated and NOT implemented, for reasons explained there).
///
/// What Phase C3 DID change — the TTS/detection concurrency fix in
/// `AudioService` and its `navigation_screen.dart` call site — is
/// tested separately and more directly in
/// `audio_service_tts_queue_test.dart` (mocked platform channel,
/// verifying no concurrent native speak() calls and correct interrupt
/// behavior) and on the physical device (see final report Part H).
/// Scenarios 15/16 here instead verify the DECISION layer's own output
/// — `NavigationDecisionResult.interrupt` / `PrioritizedWarning.
/// interrupt` — which is the exact signal `navigation_screen.dart`
/// reads to decide whether to call `AudioService.stopSpeaking()`
/// before speaking; that's the correct boundary for this file to test
/// (decision correctness), leaving actual audio-engine behavior to the
/// dedicated AudioService test and on-device verification.
class _Pipeline {
  final filter = HazardTemporalFilter(requiredConsecutiveFrames: 3);
  final ttc = CollisionTimeEstimator();
  final riskService = RiskAssessmentService();
  final adaptiveEngine = AdaptiveRiskEngine();
  final prioritizer = WarningPrioritizer();
  final decisionEngine = NavigationDecisionEngine();

  _StepResult? step(List<DetectedHazard> rawDetections) {
    final confirmed = filter.confirm(rawDetections);
    if (confirmed.isEmpty) return null;
    final withTtc = ttc.annotate(confirmed);
    final topHazard = withTtc.first;

    final risk = riskService.assess(hazard: topHazard);
    final adaptive = adaptiveEngine.assess(AdaptiveRiskInput(topHazard: topHazard), risk);
    final warning = prioritizer.prioritize(withTtc);
    final decision = decisionEngine.decide(
      risk: adaptive,
      warning: warning,
      transitPhase: TransitPhase.walking,
      awaitingVoiceConfirmation: false,
    );

    return _StepResult(hazards: withTtc, hazard: topHazard, risk: risk, adaptive: adaptive, warning: warning, decision: decision);
  }
}

class _StepResult {
  final List<DetectedHazard> hazards;
  final DetectedHazard hazard;
  final RiskAssessment risk;
  final AdaptiveRiskAssessment adaptive;
  final PrioritizedWarning warning;
  final NavigationDecisionResult decision;
  _StepResult({required this.hazards, required this.hazard, required this.risk, required this.adaptive, required this.warning, required this.decision});
}

DetectedHazard _hazard(
  String label, {
  double distance = 15.0,
  DistanceBand distanceBand = DistanceBand.far,
  double confidence = 0.9,
  HazardPriority priority = HazardPriority.critical,
  double? ttc,
}) =>
    DetectedHazard(
      label: label,
      priority: priority,
      confidence: confidence,
      distanceBand: distanceBand,
      sourceDetector: 'test',
      estimatedDistanceMeters: distance,
      timeToCollisionSeconds: ttc,
    );

/// Same deterministic-TTC-injection technique established in Phase
/// C2's test file (see that file's own doc comment for why: avoids
/// `Future.delayed` wall-clock timing, which was found to be flaky
/// under full-suite system load).
_StepResult stepWithInjectedTtc(_Pipeline p, {required double ttc, HazardPriority priority = HazardPriority.critical, String label = 'car'}) {
  const distance = 15.0;
  p.step([_hazard(label, distance: distance, priority: priority)]);
  p.step([_hazard(label, distance: distance, priority: priority)]);
  final r = p.step([_hazard(label, distance: distance, priority: priority, ttc: ttc)]);
  return r!;
}

void main() {
  group('PART H — 16 deterministic scenarios', () {
    test('1. Stationary person: confirms after 3 frames, no TTC, non-emergency decision', () {
      final p = _Pipeline();
      p.step([_hazard('person', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      p.step([_hazard('person', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      final r = p.step([_hazard('person', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      expect(r, isNotNull, reason: 'confirmation count: exactly 3 frames');
      expect(r!.hazard.timeToCollisionSeconds, isNull);
      expect(r.decision.decision, isNot(NavigationDecision.stopImmediately));
    });

    test('2. Stationary car (far): confirms after 3 frames, no TTC, warning=high not immediate', () {
      final p = _Pipeline();
      p.step([_hazard('car')]);
      p.step([_hazard('car')]);
      final r = p.step([_hazard('car')]);
      expect(r, isNotNull, reason: 'confirmation count: exactly 3 frames');
      expect(r!.hazard.timeToCollisionSeconds, isNull, reason: 'stationary object must not be treated as approaching (INVARIANT 4)');
      expect(r.warning.urgency, WarningUrgency.high);
    });

    test('3. Approaching car (long TTC, not urgent): warning stays high, not promoted', () {
      final p = _Pipeline();
      final r = stepWithInjectedTtc(p, ttc: 20.0);
      expect(r.warning.urgency, WarningUrgency.high, reason: 'final warning level: not urgent enough to promote');
    });

    test('4. RAPIDLY approaching car (short TTC): promoted to immediate without unnecessary delay', () {
      final p = _Pipeline();
      final r = stepWithInjectedTtc(p, ttc: 2.0);
      expect(r.warning.urgency, WarningUrgency.immediate, reason: 'INVARIANT 3: a rapidly approaching credible vehicle must not be delayed unnecessarily');
      expect(r.decision.decision, NavigationDecision.stopImmediately);
      expect(r.decision.interrupt, isTrue, reason: 'warning latency: reaches decision at exactly the 3rd confirmed frame, same as any other hazard -- confirmation count is NOT reduced (Part E/F/G: not implemented, see report)');
    });

    test('5. Approaching motorcycle (critical tier): promoted to immediate', () {
      final p = _Pipeline();
      final r = stepWithInjectedTtc(p, ttc: 1.5, label: 'motorcycle');
      expect(r.warning.urgency, WarningUrgency.immediate);
    });

    test('6. Approaching bicycle (caution tier): promoted to high, ceiling respected (not immediate)', () {
      final p = _Pipeline();
      final r = stepWithInjectedTtc(p, ttc: 1.5, priority: HazardPriority.caution, label: 'bicycle');
      expect(r.warning.urgency, WarningUrgency.high);
      expect(r.warning.urgency, isNot(WarningUrgency.immediate));
    });

    test('7. One-frame false detection: never confirms -> false-positive behavior is total suppression', () {
      final p = _Pipeline();
      final r = p.step([_hazard('car', confidence: 0.99)]);
      expect(r, isNull, reason: 'INVARIANT 1: one noisy detection cannot automatically create an emergency stop -- it cannot create ANY decision at all');
    });

    test('8. Two-frame false detection: still never confirms', () {
      final p = _Pipeline();
      p.step([_hazard('car', confidence: 0.99)]);
      final r = p.step([_hazard('car', confidence: 0.99)]);
      expect(r, isNull);
    });

    test('9. Intermittent detection: never accumulates a confirming streak', () {
      final p = _Pipeline();
      for (int i = 0; i < 12; i++) {
        final r = i.isEven ? p.step([_hazard('car')]) : p.step([]);
        expect(r, isNull);
      }
    });

    test('10. Confidence spike across confirm frames: confirmation count unaffected, still exactly 3', () {
      final p = _Pipeline();
      p.step([_hazard('car', confidence: 0.3)]);
      p.step([_hazard('car', confidence: 0.6)]);
      final r = p.step([_hazard('car', confidence: 0.95)]);
      expect(r, isNotNull, reason: 'confirmation count: still exactly 3, confidence trend does not change it');
    });

    test('11. Confidence drop across confirm frames: same — confirmation count unaffected', () {
      final p = _Pipeline();
      p.step([_hazard('car', confidence: 0.95)]);
      p.step([_hazard('car', confidence: 0.6)]);
      final r = p.step([_hazard('car', confidence: 0.3)]);
      expect(r, isNotNull);
    });

    test('12. Detection disappears: hazard state is invalidated, not persisted as a stale emergency', () {
      final p = _Pipeline();
      p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      final confirmed = p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      expect(confirmed!.decision.decision, NavigationDecision.stopImmediately);

      final gone = p.step([]);
      expect(gone, isNull, reason: 'INVARIANT 2: detection loss invalidates stale hazard state -- no decision at all, not a false "clear"');
    });

    test('13. Object reappears: must re-confirm from scratch, does not inherit the prior emergency', () {
      final p = _Pipeline();
      p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      p.step([]); // disappears
      expect(p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]), isNull, reason: 'reappearance frame 1 of 3');
      expect(p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]), isNull, reason: 'reappearance frame 2 of 3');
      final reconfirmed = p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      expect(reconfirmed, isNotNull, reason: 'reappearance frame 3 of 3 -- confirms again');
      expect(reconfirmed!.decision.decision, NavigationDecision.stopImmediately);
    });

    test('14. Two simultaneous hazards: high-risk vehicle is not suppressed by a co-present low-risk person', () {
      final p = _Pipeline();
      final frame = [
        _hazard('person', priority: HazardPriority.caution, confidence: 0.5),
        _hazard('car', distanceBand: DistanceBand.veryNear, confidence: 0.9),
      ];
      p.step(frame);
      p.step(frame);
      final r = p.step(frame);
      expect(r!.decision.decision, NavigationDecision.stopImmediately, reason: 'INVARIANT 6: a high-risk vehicle must not be suppressed by a lower-risk detection');
      expect(r.warning.mergedMessage, contains('car'));
    });

    test('15. Ordinary hazard while navigation speech would be active: decision.interrupt is FALSE (does not preempt routine speech)', () {
      // Models "normal navigation instruction is speaking, a routine
      // (non-urgent) hazard appears" -- the field this test asserts on
      // is exactly what navigation_screen.dart reads to decide whether
      // to call AudioService.stopSpeaking() before speaking.
      final p = _Pipeline();
      p.step([_hazard('person', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      p.step([_hazard('person', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      final r = p.step([_hazard('person', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      expect(r!.decision.interrupt, isFalse, reason: 'a routine hazard must not preempt/interrupt ordinary navigation speech');
      expect(r.warning.interrupt, isFalse);
    });

    test('16. Urgent warning while navigation speech would be active: decision.interrupt is TRUE (preempts)', () {
      final p = _Pipeline();
      p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      final r = p.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      expect(r!.decision.interrupt, isTrue, reason: 'INVARIANT 9: emergency warning must have higher priority than ordinary navigation speech -- signaled here for AudioService.stopSpeaking() to act on');
      expect(r.warning.interrupt, isTrue);
    });
  });

  group('PART I — Safety invariants (cross-references to scenarios above, plus dedicated checks)', () {
    test('INVARIANT 5: invalid TTC (receding object) cannot create an emergency', () {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 10.0)]);
      p.step([_hazard('car', distance: 10.0)]);
      final confirmed = p.step([_hazard('car', distance: 10.0)]);
      // Second observation moving AWAY -- must never produce a TTC.
      final r = p.step([_hazard('car', distance: 13.0)]);
      expect(confirmed, isNotNull);
      expect(r!.hazard.timeToCollisionSeconds, isNull);
      expect(r.warning.urgency, isNot(WarningUrgency.immediate));
    });

    test('INVARIANT 7: warning escalation scales with severity (continueWalking -> slowDown -> stopImmediately)', () {
      final low = _Pipeline();
      low.step([_hazard('person', priority: HazardPriority.informational, distanceBand: DistanceBand.far, confidence: 0.3)]);
      low.step([_hazard('person', priority: HazardPriority.informational, distanceBand: DistanceBand.far, confidence: 0.3)]);
      final lowR = low.step([_hazard('person', priority: HazardPriority.informational, distanceBand: DistanceBand.far, confidence: 0.3)]);
      expect(lowR!.decision.decision, NavigationDecision.continueWalking);

      final med = _Pipeline();
      med.step([_hazard('bicycle', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      med.step([_hazard('bicycle', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      final medR = med.step([_hazard('bicycle', priority: HazardPriority.caution, distanceBand: DistanceBand.near)]);
      expect(medR!.decision.decision, NavigationDecision.slowDown);

      final high = _Pipeline();
      high.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      high.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      final highR = high.step([_hazard('car', distanceBand: DistanceBand.veryNear)]);
      expect(highR!.decision.decision, NavigationDecision.stopImmediately);
    });

    test('INVARIANT 10: duplicate simultaneous-frame detections of the same label count once, not compounding urgency', () {
      final p = _Pipeline();
      final frame = [_hazard('car', distanceBand: DistanceBand.veryNear), _hazard('car', distanceBand: DistanceBand.veryNear)];
      p.step(frame);
      p.step(frame);
      final r = p.step(frame);
      expect(r!.warning.urgency, WarningUrgency.immediate);
      expect(r.warning.includedHazards.map((h) => h.label).toSet().length, 1, reason: 'two simultaneous same-label detections merge into one mention, not a duplicated/compounded warning');
    });
  });
}
