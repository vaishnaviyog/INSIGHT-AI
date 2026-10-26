/// Risk severity bands. Thresholds are defined in
/// [RiskAssessmentService] alongside the scoring logic they classify.
enum RiskLevel { low, medium, high, critical }

/// A single named contributor to an overall risk score.
///
/// Keeping each factor's own [score] and [weight] on the result
/// (rather than only exposing the final blended number) is what makes
/// [RiskAssessment] explainable: any consumer — the human-readable
/// explanation string, a future dissertation evaluation, or a debug
/// view — can point to exactly which factors drove a given score and
/// by how much.
class RiskFactor {
  /// Stable identifier used for grouping (see
  /// [RiskAssessmentService]'s behaviour/environment contribution
  /// calculation) — not just a display label.
  final String name;

  /// This factor's share of the overall score, in [0, 1]. All factor
  /// weights sum to 1.0.
  final double weight;

  /// This factor's own normalized severity, in [0, 1], independent of
  /// its weight.
  final double score;

  /// Short human-readable fragment describing this factor's current
  /// reading (e.g. "high walking speed"), used to build
  /// [RiskAssessment.explanation].
  final String description;

  const RiskFactor({
    required this.name,
    required this.weight,
    required this.score,
    required this.description,
  });

  /// This factor's actual contribution to the overall score.
  double get weightedScore => weight * score;

  Map<String, dynamic> toJson() => {
        'name': name,
        'weight': weight,
        'score': score,
        'description': description,
      };
}

/// The environmental signal available to the risk engine today.
///
/// Deliberately minimal — a single daylight/night flag derived from
/// device time. This is intentionally extensible: a future milestone
/// could add fields like road type (from OSRM tags), weather, or
/// crowd density without changing [RiskAssessmentService]'s scoring
/// pipeline shape, since environment is already handled as its own
/// isolated factor.
class EnvironmentContext {
  final bool? isDaylight;

  const EnvironmentContext({this.isDaylight});

  /// Crude placeholder heuristic (6am–6pm = daylight) rather than a
  /// real sunrise/sunset calculation. Documented as a known
  /// simplification — see RiskAssessmentService's known limitations.
  factory EnvironmentContext.fromCurrentTime([DateTime? now]) {
    final time = now ?? DateTime.now();
    return EnvironmentContext(isDaylight: time.hour >= 6 && time.hour < 18);
  }
}

/// The full output of [RiskAssessmentService.assess] — a score AND an
/// explanation, never just the former.
class RiskAssessment {
  final double overallRiskScore;
  final RiskLevel riskLevel;
  final List<RiskFactor> riskFactors;

  /// Which hazard detector (e.g. "coco_tflite", "mlkit_fallback")
  /// contributed the hazard this assessment is based on, if any.
  final String? detectorSource;

  /// Sum of weighted scores from behaviour-profile-derived factors
  /// (speed, reaction time, familiarity, confidence, history).
  final double behaviourContribution;

  /// Weighted score from the environmental factor alone.
  final double environmentContribution;

  /// Human-readable reason, built from the most significant factors
  /// — e.g. "high walking speed + car detected (near) + slower-than-
  /// average reaction time".
  final String explanation;

  final DateTime timestamp;

  RiskAssessment({
    required this.overallRiskScore,
    required this.riskLevel,
    required this.riskFactors,
    required this.detectorSource,
    required this.behaviourContribution,
    required this.environmentContribution,
    required this.explanation,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'overallRiskScore': overallRiskScore,
        'riskLevel': riskLevel.name,
        'riskFactors': riskFactors.map((f) => f.toJson()).toList(),
        'detectorSource': detectorSource,
        'behaviourContribution': behaviourContribution,
        'environmentContribution': environmentContribution,
        'explanation': explanation,
        'timestamp': timestamp.toIso8601String(),
      };

  @override
  String toString() =>
      'RiskAssessment(score=${overallRiskScore.toStringAsFixed(2)}, '
      'level=${riskLevel.name}, reason="$explanation")';
}
