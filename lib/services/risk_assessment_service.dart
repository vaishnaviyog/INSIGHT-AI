import '../models/detected_hazard.dart';
import '../models/risk_assessment.dart';
import '../models/user_behaviour_profile.dart';

/// Combines hazard detection output, user behaviour, and (minimal)
/// environmental context into a single, EXPLAINABLE [RiskAssessment].
///
/// STATELESS BY DESIGN: this service holds no references to
/// [HazardDetectionService], [BehaviourLearningService], or anything
/// else — every input is passed explicitly into [assess]. This keeps
/// the engine "completely independent of the UI" as a literal
/// property, not just a convention, and makes it directly unit-
/// testable with synthetic inputs. Callers (today,
/// `navigation_screen.dart`; in Milestone 4,
/// `AdaptiveGuidanceService`) are responsible for gathering current
/// values and passing them in.
///
/// EXPLAINABLE BY DESIGN, NOT JUST SCORED: this is a transparent,
/// hand-weighted factor model — not a black-box classifier. Every
/// factor's own score and weight survive into the result
/// ([RiskAssessment.riskFactors]) specifically so
/// [RiskAssessment.explanation] — and any future dissertation
/// evaluation of the engine's behaviour — can point to WHY a score
/// was produced, not only what it was. If this project later moves to
/// a learned model, this class's output shape is designed to stay
/// compatible so downstream consumers don't need to change.
///
/// MILESTONE 3 SCOPE: this service only produces assessments. It does
/// not alter navigation, speech, or UI behaviour — see
/// `navigation_screen.dart`'s integration, which only logs and
/// displays results (debug dashboard). Consuming risk level to change
/// what's spoken is Milestone 4's job.
class RiskAssessmentService {
  // Factor weights (sum to 1.0). Hand-tuned starting points, not
  // learned — this is the single place to retune them, and a natural
  // candidate for a small sensitivity-analysis section in the
  // dissertation.
  static const double _hazardWeight = 0.35;
  static const double _speedWeight = 0.15;
  static const double _reactionTimeWeight = 0.15;
  static const double _familiarityWeight = 0.10;
  static const double _confidenceWeight = 0.10;
  static const double _historyWeight = 0.10;
  static const double _environmentWeight = 0.05;

  static const double _lowThreshold = 0.30;
  static const double _mediumThreshold = 0.55;
  static const double _highThreshold = 0.80;

  /// Names of factors that count toward
  /// [RiskAssessment.behaviourContribution] — everything derived from
  /// the user's own behaviour profile rather than the immediate
  /// hazard or the environment.
  static const _behaviourFactorNames = {
    'Walking Speed',
    'Reaction Time',
    'Route Familiarity',
    'Behaviour Confidence',
    'Navigation History',
  };

  /// Produces a full [RiskAssessment] for the current situation.
  /// Every parameter is optional — a call with everything null still
  /// returns a valid (low) assessment, since "no known hazard, no
  /// behaviour data yet" is a legitimate early-session state.
  RiskAssessment assess({
    DetectedHazard? hazard,
    double? currentSpeedMetersPerSecond,
    UserBehaviourProfile? profile,
    EnvironmentContext? environment,
  }) {
    final factors = <RiskFactor>[
      _hazardFactor(hazard),
      _speedFactor(currentSpeedMetersPerSecond),
      _reactionTimeFactor(profile),
      _familiarityFactor(profile),
      _confidenceFactor(profile),
      _historyFactor(profile),
      _environmentFactor(environment),
    ];

    final overallScore =
        factors.fold<double>(0.0, (sum, f) => sum + f.weightedScore).clamp(0.0, 1.0);

    final behaviourContribution = factors
        .where((f) => _behaviourFactorNames.contains(f.name))
        .fold<double>(0.0, (sum, f) => sum + f.weightedScore);

    final environmentContribution =
        factors.firstWhere((f) => f.name == 'Environment').weightedScore;

    return RiskAssessment(
      overallRiskScore: overallScore,
      riskLevel: _levelFor(overallScore),
      riskFactors: factors,
      detectorSource: hazard?.sourceDetector,
      behaviourContribution: behaviourContribution,
      environmentContribution: environmentContribution,
      explanation: _buildExplanation(factors),
    );
  }

  RiskFactor _hazardFactor(DetectedHazard? hazard) {
    if (hazard == null) {
      return const RiskFactor(
        name: 'Hazard',
        weight: _hazardWeight,
        score: 0.0,
        description: 'no active hazard',
      );
    }
    final baseSeverity = switch (hazard.priority) {
      HazardPriority.critical => 1.0,
      HazardPriority.caution => 0.6,
      HazardPriority.informational => 0.2,
    };
    final distanceMultiplier = switch (hazard.distanceBand) {
      DistanceBand.veryNear => 1.0,
      DistanceBand.near => 0.7,
      DistanceBand.far => 0.4,
      DistanceBand.unknown => 0.5,
    };
    // AUDIT ADD (Phase 3/4 — Time-to-Collision): when a safe TTC
    // estimate is available (see CollisionTimeEstimator — null unless
    // the object is genuinely closing distance across two real
    // samples), a short one boosts severity ON TOP OF the existing
    // distance-band signal, since two hazards at the same CURRENT
    // distance are not equally urgent if one is closing fast and the
    // other is barely moving. Deliberately folded into this existing
    // factor's score (not a new top-level weighted factor) so the
    // documented, sum-to-1.0 weight structure above is untouched by
    // this fix — a genuinely new weighted axis would need its own
    // sensitivity analysis, which is out of scope for this pass.
    final ttc = hazard.timeToCollisionSeconds;
    final ttcUrgencyMultiplier = ttc == null
        ? 1.0
        : ttc <= 1.5
            ? 1.3
            : ttc <= 3.0
                ? 1.15
                : 1.0;
    final score =
        (baseSeverity * distanceMultiplier * hazard.confidence * ttcUrgencyMultiplier).clamp(0.0, 1.0);
    final ttcSuffix = ttc != null && ttc <= 3.0 ? ', approaching (TTC ${ttc.toStringAsFixed(1)}s)' : '';
    return RiskFactor(
      name: 'Hazard',
      weight: _hazardWeight,
      score: score,
      description: '${hazard.label} detected (${hazard.distanceBand.name})$ttcSuffix',
    );
  }

  RiskFactor _speedFactor(double? speed) {
    if (speed == null) {
      return const RiskFactor(
        name: 'Walking Speed',
        weight: _speedWeight,
        score: 0.2,
        description: 'speed unknown',
      );
    }
    // Reference: ~1.0-1.4 m/s is a typical adult walking pace; risk
    // rises toward a brisk/jogging pace (~2.5 m/s+).
    final score = ((speed - 1.0) / 1.5).clamp(0.0, 1.0);
    return RiskFactor(
      name: 'Walking Speed',
      weight: _speedWeight,
      score: score,
      description: score > 0.5 ? 'high walking speed' : 'normal walking speed',
    );
  }

  RiskFactor _reactionTimeFactor(UserBehaviourProfile? profile) {
    if (profile == null || profile.reactionSampleCount == 0) {
      return const RiskFactor(
        name: 'Hazard Clearance Latency',
        weight: _reactionTimeWeight,
        score: 0.3,
        description: 'clearance-latency history not yet known',
      );
    }
    // Reference: ~1.5s treated as a good (fast) clearance latency;
    // risk rises toward ~4.5s+. NOTE (P0-5): this is a behavioral
    // proxy — warning-spoken to hazard-cleared latency — not a
    // measured human reaction time. UserBehaviourProfile's field
    // names (averageReactionTime/reactionSampleCount) are kept as-is
    // for Hive persistence compatibility; see that model's doc
    // comment. Only the user/research-facing label here changed.
    final score = ((profile.averageReactionTime - 1.5) / 3.0).clamp(0.0, 1.0);
    return RiskFactor(
      name: 'Hazard Clearance Latency',
      weight: _reactionTimeWeight,
      score: score,
      description: score > 0.5 ? 'slower-than-average clearance latency' : 'typical clearance latency',
    );
  }

  RiskFactor _familiarityFactor(UserBehaviourProfile? profile) {
    final familiarity = profile?.routeFamiliarityScore ?? 0.0;
    final score = (1.0 - familiarity).clamp(0.0, 1.0);
    return RiskFactor(
      name: 'Route Familiarity',
      weight: _familiarityWeight,
      score: score,
      description: score > 0.5 ? 'unfamiliar route' : 'familiar route',
    );
  }

  RiskFactor _confidenceFactor(UserBehaviourProfile? profile) {
    final confidence = profile?.confidenceScore ?? 0.5;
    final score = (1.0 - confidence).clamp(0.0, 1.0);
    return RiskFactor(
      name: 'Behaviour Confidence',
      weight: _confidenceWeight,
      score: score,
      description:
          score > 0.5 ? 'below-average user confidence score' : 'stable user confidence score',
    );
  }

  RiskFactor _historyFactor(UserBehaviourProfile? profile) {
    if (profile == null || profile.totalNavigationSessions == 0) {
      return const RiskFactor(
        name: 'Navigation History',
        weight: _historyWeight,
        score: 0.2,
        description: 'no navigation history yet',
      );
    }
    final nearMissRate = profile.nearMisses / profile.totalNavigationSessions;
    final score = (nearMissRate / 3.0).clamp(0.0, 1.0);
    return RiskFactor(
      name: 'Navigation History',
      weight: _historyWeight,
      score: score,
      description: score > 0.5 ? 'history of frequent near misses' : 'unremarkable navigation history',
    );
  }

  RiskFactor _environmentFactor(EnvironmentContext? environment) {
    final isDaylight = environment?.isDaylight;
    if (isDaylight == null) {
      return const RiskFactor(
        name: 'Environment',
        weight: _environmentWeight,
        score: 0.3,
        description: 'environment unknown',
      );
    }
    return RiskFactor(
      name: 'Environment',
      weight: _environmentWeight,
      score: isDaylight ? 0.2 : 0.7,
      description: isDaylight ? 'daylight conditions' : 'low-light / night conditions',
    );
  }

  RiskLevel _levelFor(double score) {
    if (score >= _highThreshold) return RiskLevel.critical;
    if (score >= _mediumThreshold) return RiskLevel.high;
    if (score >= _lowThreshold) return RiskLevel.medium;
    return RiskLevel.low;
  }

  /// Builds the human-readable explanation from the most significant
  /// factors (highest weighted contribution, above a "not
  /// negligible" threshold), e.g.:
  /// "high walking speed + car detected (near) + slower-than-average reaction time"
  String _buildExplanation(List<RiskFactor> factors) {
    final sorted = [...factors]..sort((a, b) => b.weightedScore.compareTo(a.weightedScore));
    final significant = sorted.where((f) => f.score > 0.4).take(3).toList();
    if (significant.isEmpty) {
      return 'No significant risk factors detected.';
    }
    return significant.map((f) => f.description).join(' + ');
  }
}
