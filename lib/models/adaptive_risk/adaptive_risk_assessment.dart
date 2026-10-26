import '../risk_assessment.dart';

/// The full output of `AdaptiveRiskEngine.assess` — a superset of the
/// existing [RiskAssessment], not a replacement for it: [coreAssessment]
/// holds the ORIGINAL, unmodified [RiskAssessment] (vision + behaviour
/// + environment, exactly as `RiskAssessmentService` already computes
/// it), and [riskFactors] adds the new cross-subsystem factors this
/// phase introduces (navigation phase, road crossing, destination
/// confidence, GPS accuracy, approach trend) alongside it. Same
/// explainability contract as the base class: every factor's own
/// score/weight is preserved, not just the final blended number.
class AdaptiveRiskAssessment {
  final double overallRiskScore;
  final RiskLevel riskLevel;
  final List<RiskFactor> riskFactors;
  final RiskAssessment coreAssessment;
  final String explanation;
  final DateTime timestamp;

  AdaptiveRiskAssessment({
    required this.overallRiskScore,
    required this.riskLevel,
    required this.riskFactors,
    required this.coreAssessment,
    required this.explanation,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'overallRiskScore': overallRiskScore,
        'riskLevel': riskLevel.name,
        'riskFactors': riskFactors.map((f) => f.toJson()).toList(),
        'coreAssessment': coreAssessment.toJson(),
        'explanation': explanation,
        'timestamp': timestamp.toIso8601String(),
      };
}
