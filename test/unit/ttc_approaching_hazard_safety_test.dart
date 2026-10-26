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

/// PHASE C2 — TTC / APPROACHING-HAZARD SAFETY AUDIT AND FIX.
///
/// ROOT CAUSE (independently re-verified from current source, not
/// assumed from the Phase C audit): `WarningPrioritizer._urgencyFor()`
/// never read `DetectedHazard.timeToCollisionSeconds` at all — only
/// `priority` and `distanceBand`. A critical hazard still classified
/// "far" by raw distance could be closing fast enough to be genuinely
/// dangerous (reproduced concretely: 20m, closing 8 m/s, TTC ~2.5s)
/// and would still only ever reach `WarningUrgency.high` /
/// `NavigationDecision.slowDown` (non-interrupting, generic "car
/// ahead" message) — never `immediate` / `stopImmediately`.
///
/// FIX: `_urgencyFor` now also promotes urgency when a hazard carries
/// a short (`<= 3.0s`, matching the codebase's EXISTING "approaching"
/// definition already used by `RiskAssessmentService`'s TTC boost tier
/// and `AdaptiveGuidanceService`'s "Approaching quickly." phrase) AND
/// credible (`confidence >= 0.5`) TTC — critical-tier promotes to
/// `immediate`, caution-tier promotes to `high` (never `immediate`).
/// This is purely ADDITIVE: the existing near/veryNear-distance rule
/// is completely untouched, and a hazard with no TTC (stationary,
/// receding, stale, or not yet closing fast enough) is scored exactly
/// as before this phase.
///
/// This file drives the REAL, unmodified-except-for-this-fix
/// production pipeline end-to-end. PART 2's scenarios use REAL elapsed
/// wall-clock time (`Future.delayed`) between confirmed-frame steps,
/// so `CollisionTimeEstimator`'s dt-based closing-speed math is
/// genuine, not instantaneous — exactly what Step 2's "record
/// distance, approach velocity, TTC, risk, urgency, decision"
/// requires. PART 6's BOUNDARY/ORDERING invariants (which need an
/// EXACT TTC value, e.g. "just under 3.0s") instead use
/// [stepWithInjectedTtc] to inject a precise TTC deterministically —
/// real-time-derived TTC math is already covered by PART 2 and by
/// `collision_time_estimator_test.dart`; depending on `Future.delayed`
/// wall-clock precision for a THRESHOLD assertion was found to be
/// flaky under full-suite system load (scheduler contention inflates
/// the measured dt, which inflates the computed TTC away from the
/// intended value) and was deliberately removed from these specific
/// tests rather than tolerated.
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

    return _StepResult(hazard: topHazard, risk: risk, adaptive: adaptive, warning: warning, decision: decision);
  }
}

class _StepResult {
  final DetectedHazard hazard;
  final RiskAssessment risk;
  final AdaptiveRiskAssessment adaptive;
  final PrioritizedWarning warning;
  final NavigationDecisionResult decision;
  _StepResult({required this.hazard, required this.risk, required this.adaptive, required this.warning, required this.decision});
}

DetectedHazard _hazard(
  String label, {
  required double distance,
  required DistanceBand distanceBand,
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

/// Deterministically injects an EXACT TTC value through the real
/// `_Pipeline` (exercising the real WarningPrioritizer/RiskAssessment/
/// AdaptiveRiskEngine/NavigationDecisionEngine code, not a shortcut
/// around them) WITHOUT depending on `Future.delayed` wall-clock
/// timing at all. Used for tests whose subject is a specific TTC
/// BOUNDARY value (e.g. "just under 3.0s" vs "just over"), where
/// `CollisionTimeEstimator`'s real closing-speed math (itself already
/// covered by scenarios A-L below, and by
/// `collision_time_estimator_test.dart`) would make the exact TTC
/// depend on real elapsed time — fragile under system load in a full
/// test-suite run (observed: `Future.delayed`-derived dt can be
/// inflated by scheduler contention, silently lengthening the
/// computed TTC past a nearby threshold).
///
/// HOW: feeds the SAME constant distance on every confirmed frame
/// (closing speed = 0, below `CollisionTimeEstimator`'s own minimum
/// threshold), which makes it return the hazard UNCHANGED rather than
/// recomputing a TTC — so the explicit [ttc] passed to the final frame
/// survives exactly as given.
_StepResult stepWithInjectedTtc(_Pipeline p, {required double ttc, HazardPriority priority = HazardPriority.critical}) {
  const distance = 15.0; // arbitrary, irrelevant to the injected TTC itself
  p.step([_hazard('car', distance: distance, distanceBand: DistanceBand.far, priority: priority)]);
  p.step([_hazard('car', distance: distance, distanceBand: DistanceBand.far, priority: priority)]);
  final r = p.step([_hazard('car', distance: distance, distanceBand: DistanceBand.far, priority: priority, ttc: ttc)]);
  return r!;
}

void main() {
  group('PART 2 — Reproduction scenarios (A-L), full pipeline, real elapsed time', () {
    test('A. Stationary car, 10m away: no TTC, urgency stays high (unaffected by fix)', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 200));
      final r = p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      expect(r!.hazard.timeToCollisionSeconds, isNull, reason: 'stationary -> no closing speed -> no TTC');
      expect(r.warning.urgency, WarningUrgency.high);
      expect(r.decision.decision, NavigationDecision.slowDown);
    });

    test('B. Stationary car, 5m away (near): immediate via EXISTING distance rule, unaffected by fix', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 5.0, distanceBand: DistanceBand.near)]);
      p.step([_hazard('car', distance: 5.0, distanceBand: DistanceBand.near)]);
      final r = p.step([_hazard('car', distance: 5.0, distanceBand: DistanceBand.near)]);
      expect(r!.hazard.timeToCollisionSeconds, isNull);
      expect(r.warning.urgency, WarningUrgency.immediate, reason: 'pre-existing near-distance rule, not this phase\'s change');
      expect(r.decision.decision, NavigationDecision.stopImmediately);
    });

    test('C. Slowly approaching car (0.3 m/s, far): TTC computed but long (~49s) -> NOT promoted', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 1000));
      final r = p.step([_hazard('car', distance: 14.7, distanceBand: DistanceBand.far)]); // ~0.3 m/s
      expect(r!.hazard.timeToCollisionSeconds, isNotNull);
      expect(r.hazard.timeToCollisionSeconds!, greaterThan(30), reason: 'slow closing speed -> long TTC, not urgent');
      expect(r.warning.urgency, WarningUrgency.high, reason: 'TTC far above 3.0s threshold -> no promotion');
    });

    test('D. RAPIDLY approaching car from far (~12.5 m/s, TTC well under 1s nominal): PROMOTED to immediate — THE REPRODUCED DEFECT, NOW FIXED', () async {
      // Margins deliberately generous (nominal TTC ~0.7s, ~4x tolerance
      // to the 3.0s threshold) — a full-suite run under system load can
      // measurably inflate Future.delayed-derived dt (scheduler
      // contention), which inflates computed TTC proportionally; a
      // tight margin here was observed to be flaky for exactly this
      // reason during this phase's own test development.
      final p = _Pipeline();
      p.step([_hazard('car', distance: 30.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 27.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 24.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 1200));
      final r = p.step([_hazard('car', distance: 9.0, distanceBand: DistanceBand.far)]); // ~12.5 m/s nominal
      expect(r!.hazard.timeToCollisionSeconds, isNotNull);
      expect(r.hazard.timeToCollisionSeconds!, lessThan(3.0));
      expect(r.warning.urgency, WarningUrgency.immediate, reason: 'FIX: short credible TTC now promotes urgency even while distanceBand is still "far"');
      expect(r.decision.decision, NavigationDecision.stopImmediately);
      expect(r.decision.interrupt, isTrue, reason: 'must be able to interrupt non-critical speech for a genuine fast approach');
    });

    test('E. Rapidly approaching motorcycle (critical tier): also promoted to immediate', () async {
      final p = _Pipeline();
      p.step([_hazard('motorcycle', distance: 25.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('motorcycle', distance: 22.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('motorcycle', distance: 19.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 1200));
      final r = p.step([_hazard('motorcycle', distance: 11.0, distanceBand: DistanceBand.far)]); // ~11.7 m/s nominal
      expect(r!.hazard.timeToCollisionSeconds, lessThan(3.0));
      expect(r.warning.urgency, WarningUrgency.immediate);
    });

    test('F. Rapidly approaching bicycle (caution tier): promoted to high, NOT immediate (ceiling respected)', () async {
      final p = _Pipeline();
      p.step([_hazard('bicycle', distance: 20.0, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]);
      p.step([_hazard('bicycle', distance: 17.0, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]);
      p.step([_hazard('bicycle', distance: 14.0, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]);
      await Future.delayed(const Duration(milliseconds: 1200));
      final r = p.step([_hazard('bicycle', distance: 8.0, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]); // ~10 m/s nominal
      expect(r!.hazard.timeToCollisionSeconds, lessThan(3.0));
      expect(r.warning.urgency, WarningUrgency.high, reason: 'caution-tier ceiling is high, never immediate, even with urgent TTC');
      expect(r.warning.urgency, isNot(WarningUrgency.immediate));
    });

    test('G. Object moving laterally (distance stable): no TTC fabricated from lateral motion', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 300));
      final r = p.step([_hazard('car', distance: 15.05, distanceBand: DistanceBand.far)]);
      expect(r!.hazard.timeToCollisionSeconds, isNull);
      expect(r.warning.urgency, WarningUrgency.high);
    });

    test('H. Object moving away: no TTC, no promotion', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 12.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 14.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 300));
      final r = p.step([_hazard('car', distance: 16.0, distanceBand: DistanceBand.far)]);
      expect(r!.hazard.timeToCollisionSeconds, isNull, reason: 'receding object must never produce a TTC');
      expect(r.warning.urgency, WarningUrgency.high);
    });

    test('I. Noisy distance measurements (small oscillation): never fabricates a short/urgent TTC', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 10.3, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 9.9, distanceBand: DistanceBand.far)]);
      final results = <_StepResult>[];
      for (final d in [10.2, 9.8, 10.1, 9.95]) {
        await Future.delayed(const Duration(milliseconds: 300));
        final r = p.step([_hazard('car', distance: d, distanceBand: DistanceBand.far)]);
        if (r != null) results.add(r);
      }
      for (final r in results) {
        expect(r.warning.urgency, isNot(WarningUrgency.immediate), reason: 'small-amplitude noise must never fabricate an urgent TTC-driven promotion');
      }
    });

    test('J. Noisy bounding-box-derived distance: same non-escalation guarantee', () async {
      final p = _Pipeline();
      p.step([_hazard('person', distance: 6.0, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]);
      p.step([_hazard('person', distance: 6.2, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]);
      p.step([_hazard('person', distance: 5.9, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]);
      await Future.delayed(const Duration(milliseconds: 300));
      final r = p.step([_hazard('person', distance: 6.1, distanceBand: DistanceBand.far, priority: HazardPriority.caution)]);
      expect(r!.warning.urgency, isNot(WarningUrgency.immediate));
    });

    test('K. Intermittent detection: never confirms, TTC/risk/warning pipeline never even invoked', () {
      final p = _Pipeline();
      for (int i = 0; i < 10; i++) {
        final r = i.isEven ? p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]) : p.step([]);
        expect(r, isNull);
      }
    });

    test('L. Stale detection: gap resets TTC history, reappearance does not inherit the old short TTC', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 25.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 22.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 19.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 400));
      final closing = p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]); // ~10 m/s, urgent
      expect(closing!.warning.urgency, WarningUrgency.immediate, reason: 'sanity check: this scenario really was urgent before the gap');

      // Detection lost entirely (label absent -> CollisionTimeEstimator
      // drops its sample per its own documented reset-on-absence rule).
      p.step([]);
      p.step([]);
      p.step([]);
      // Reappears -> needs a fresh 3-frame confirmation streak AND a
      // fresh TTC history; first reading after the gap must not carry
      // forward the pre-gap closing speed.
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      final reappeared = p.step([_hazard('car', distance: 15.0, distanceBand: DistanceBand.far)]);
      expect(reappeared!.hazard.timeToCollisionSeconds, isNull, reason: 'first observation after the gap has no prior sample to compare against');
      expect(reappeared.warning.urgency, WarningUrgency.high, reason: 'must not inherit the pre-gap "immediate" state');
    });
  });

  group('PART 6 — Safety invariants', () {
    test('INVARIANT 1: a rapidly approaching vehicle cannot be classified low urgency solely because current distance is large', () {
      final r = stepWithInjectedTtc(_Pipeline(), ttc: 2.0); // short, credible TTC, distanceBand still "far"
      expect(r.warning.urgency, WarningUrgency.immediate);
      expect(r.warning.urgency, isNot(WarningUrgency.low));
      expect(r.warning.urgency, isNot(WarningUrgency.ignore));
    });

    test('INVARIANT 2: a stationary nearby object does not gain EXTRA urgency beyond the pre-existing distance rule', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 5.0, distanceBand: DistanceBand.near)]);
      p.step([_hazard('car', distance: 5.0, distanceBand: DistanceBand.near)]);
      final r = p.step([_hazard('car', distance: 5.0, distanceBand: DistanceBand.near)]);
      // Still exactly `immediate` (the pre-existing rule's own ceiling) -- this
      // phase adds no NEW tier beyond it, and TTC is null (stationary) so the
      // new branch never even fires here.
      expect(r!.warning.urgency, WarningUrgency.immediate);
      expect(r.hazard.timeToCollisionSeconds, isNull);
    });

    test('INVARIANT 3/4: invalid (negative-would-be) TTC never creates an artificial emergency', () async {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      await Future.delayed(const Duration(milliseconds: 300));
      // Receding -- would be a NEGATIVE closing speed / undefined TTC
      // if not guarded.
      final r = p.step([_hazard('car', distance: 13.0, distanceBand: DistanceBand.far)]);
      expect(r!.hazard.timeToCollisionSeconds, isNull, reason: 'CollisionTimeEstimator guarantees no negative/infinite TTC by construction');
      expect(r.warning.urgency, isNot(WarningUrgency.immediate));
    });

    test('INVARIANT 5: stale TTC cannot produce a CURRENT emergency warning', () {
      final p = _Pipeline();
      final urgent = stepWithInjectedTtc(p, ttc: 2.0);
      expect(urgent.warning.urgency, WarningUrgency.immediate);
      // Detection gap.
      p.step([]);
      p.step([]);
      p.step([]);
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      final afterGap = p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.far)]);
      expect(afterGap!.hazard.timeToCollisionSeconds, isNull);
      expect(afterGap.warning.urgency, isNot(WarningUrgency.immediate), reason: 'the OLD urgent state must not persist across a detection gap');
    });

    test('INVARIANT 6: increasing credible approach speed (shorter TTC) cannot DECREASE warning urgency', () {
      final slowResult = stepWithInjectedTtc(_Pipeline(), ttc: 45.0); // slow approach, long TTC
      final fastResult = stepWithInjectedTtc(_Pipeline(), ttc: 1.5); // fast approach, short TTC

      const order = {WarningUrgency.ignore: 0, WarningUrgency.low: 1, WarningUrgency.high: 2, WarningUrgency.immediate: 3};
      expect(order[fastResult.warning.urgency]!, greaterThanOrEqualTo(order[slowResult.warning.urgency]!),
          reason: 'faster credible closing speed must never result in LOWER urgency than a slower one');
    });

    test('INVARIANT 7: a TTC just under the threshold is at least as urgent as one just over it (no inversion at the boundary)', () {
      final overResult = stepWithInjectedTtc(_Pipeline(), ttc: 3.1); // just over the 3.0s threshold -> not promoted
      final underResult = stepWithInjectedTtc(_Pipeline(), ttc: 2.9); // just under -> promoted

      const order = {WarningUrgency.ignore: 0, WarningUrgency.low: 1, WarningUrgency.high: 2, WarningUrgency.immediate: 3};
      expect(order[underResult.warning.urgency]!, greaterThanOrEqualTo(order[overResult.warning.urgency]!));
      expect(overResult.warning.urgency, WarningUrgency.high, reason: 'sanity: 3.1s must NOT be promoted');
      expect(underResult.warning.urgency, WarningUrgency.immediate, reason: 'sanity: 2.9s MUST be promoted');
    });

    test('INVARIANT 8: a high-risk vehicle is not suppressed by a simultaneously-present lower-risk person (regression check after this fix)', () async {
      final p = _Pipeline();
      final frame = [
        _hazard('person', distance: 8.0, distanceBand: DistanceBand.far, priority: HazardPriority.caution, confidence: 0.5),
        _hazard('car', distance: 4.0, distanceBand: DistanceBand.veryNear, confidence: 0.9),
      ];
      p.step(frame);
      p.step(frame);
      final r = p.step(frame);
      expect(r!.decision.decision, NavigationDecision.stopImmediately);
      expect(r.warning.mergedMessage, contains('car'));
    });

    test('INVARIANT 9: a noisy single-frame TTC dip is reversible, not an irreversible emergency state', () async {
      final p = _Pipeline();
      final spike = stepWithInjectedTtc(p, ttc: 1.5); // urgent, one frame (deterministic -- see stepWithInjectedTtc doc comment)
      expect(spike.warning.urgency, WarningUrgency.immediate);

      // Next frame: the object is no longer closing at all (ticks
      // slightly FARTHER, not just "less close") -- deliberately using
      // a sign flip rather than a small further decrease, so the
      // outcome depends only on direction, not on being timing-
      // sensitive to the exact elapsed milliseconds under system load.
      // Since nothing in this stateless pipeline latches the
      // emergency, it must immediately reflect the new, calmer reading.
      await Future.delayed(const Duration(milliseconds: 300));
      final settled = p.step([_hazard('car', distance: 15.3, distanceBand: DistanceBand.far)]);
      expect(settled!.hazard.timeToCollisionSeconds, isNull, reason: 'no longer closing -> no TTC, regardless of exact elapsed time');
      expect(settled.warning.urgency, isNot(WarningUrgency.immediate), reason: 'urgency must self-correct the very next frame once closing speed drops -- no persistent/latched emergency flag exists anywhere in this stateless decision chain');
    });

    test('INVARIANT 10: detection loss eventually invalidates stale hazard state entirely (no decision produced)', () {
      final p = _Pipeline();
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.veryNear)]);
      p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.veryNear)]);
      final confirmed = p.step([_hazard('car', distance: 10.0, distanceBand: DistanceBand.veryNear)]);
      expect(confirmed!.warning.urgency, WarningUrgency.immediate);

      // Object leaves the frame entirely.
      final gone = p.step([]);
      expect(gone, isNull, reason: 'no confirmed hazard -> no risk/warning/decision is computed at all, matching the "absence is never proof of safety" principle -- the caller sees nothing, not a false "clear"');
    });
  });
}
