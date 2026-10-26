import '../models/detected_hazard.dart';
import '../models/risk_assessment.dart';
import '../models/user_behaviour_profile.dart';

/// Structured output of [ExplainableAIService.explain] — always all
/// three fields, never just a score.
class ExplanationResult {
  final String reason;
  final String recommendation;

  /// How much data backs this specific explanation, in [0, 1] — NOT
  /// the risk score. A confident explanation needs both a confident
  /// detection and enough behaviour history to trust the comparison;
  /// see [ExplainableAIService._computeConfidence].
  final double confidence;

  const ExplanationResult({
    required this.reason,
    required this.recommendation,
    required this.confidence,
  });
}

/// Produces a structured (Reason, Recommendation, Confidence) triple
/// for any hazard/risk situation.
///
/// INDEPENDENT BY DESIGN (per instruction): this service takes
/// exactly the four inputs listed — Hazard, Risk, Behaviour,
/// Environment — and holds no reference to any other service. It
/// does not recompute risk scoring (that's RiskAssessmentService's
/// job, M3) or guidance decisions (AdaptiveGuidanceService, M4) — it
/// REUSES their already-computed outputs (specifically
/// `RiskAssessment.explanation` and `RiskAssessment.riskFactors`) to
/// avoid duplicating logic, and adds exactly one new thing: a
/// concrete, actionable recommendation plus an explicit confidence
/// value for the explanation itself.
///
/// This is what the AI Learning Dashboard (Phase 2) displays under
/// "AI Learning Summary" and what a future ANIE Explainable AI Module
/// (see the Milestone 7 architecture document) would call once that
/// layer exists — this class is written to already match that
/// module's intended input/output shape.
class ExplainableAIService {
  ExplanationResult explain({
    DetectedHazard? hazard,
    required RiskAssessment risk,
    UserBehaviourProfile? behaviour,
    EnvironmentContext? environment,
  }) {
    // Reuse RiskAssessment's own explanation rather than re-deriving
    // one — it's already built from the same weighted factors.
    final reason = risk.explanation;
    final recommendation = _recommendationFor(risk, hazard, behaviour);
    final confidence = _computeConfidence(hazard, behaviour);

    return ExplanationResult(
      reason: reason,
      recommendation: recommendation,
      confidence: confidence,
    );
  }

  String _recommendationFor(
    RiskAssessment risk,
    DetectedHazard? hazard,
    UserBehaviourProfile? behaviour,
  ) {
    switch (risk.riskLevel) {
      case RiskLevel.critical:
        return 'Stop and reassess before proceeding.';
      case RiskLevel.high:
        return 'Proceed with caution and reduce walking speed.';
      case RiskLevel.medium:
        if (behaviour != null && behaviour.routeFamiliarityScore < 0.3) {
          return 'Proceed carefully — this route is not yet familiar.';
        }
        return 'Proceed, but stay alert to your surroundings.';
      case RiskLevel.low:
        return 'Safe to continue at normal pace.';
    }
  }

  /// Confidence in the EXPLANATION, not the risk score itself. Built
  /// from two real signals: how confident the underlying detection
  /// was (if any), and how much behaviour history exists to compare
  /// against — fewer than 3 sessions means the "familiar route" /
  /// "average reaction time" framing in the reason is on thin data,
  /// so confidence is capped lower until more data accumulates. This
  /// is itself an explainable, documented rule — not a black box.
  double _computeConfidence(DetectedHazard? hazard, UserBehaviourProfile? behaviour) {
    final detectionConfidence = hazard?.confidence ?? 0.5;
    final sessions = behaviour?.totalNavigationSessions ?? 0;
    final dataMaturity = (sessions / 10.0).clamp(0.0, 1.0);
    return ((detectionConfidence * 0.6) + (dataMaturity * 0.4)).clamp(0.0, 1.0);
  }
}
