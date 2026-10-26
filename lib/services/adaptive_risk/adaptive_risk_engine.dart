import '../../models/adaptive_risk/adaptive_risk_assessment.dart';
import '../../models/adaptive_risk/adaptive_risk_input.dart';
import '../../models/detected_hazard.dart';
import '../../models/risk_assessment.dart';

/// THE central intelligence layer of INSIGHT — combines Computer
/// Vision, User Behaviour, Voice Understanding, and Context into one
/// adaptive risk score, per this project's stated research objective.
///
/// DOES NOT REPLACE `RiskAssessmentService` — that engine's vision/
/// behaviour/environment scoring is mature, already tuned, and
/// explicitly explainable; rewriting it would violate "do not
/// redesign completed modules" for no benefit. Instead, this class
/// treats an ALREADY-COMPUTED `RiskAssessment` (passed in by the
/// caller — see [assess]) as ONE weighted meta-factor ("Core
/// Perception & Behaviour") and adds new cross-subsystem factors
/// alongside it — extension, not replacement, and no longer a second
/// computation of the same thing (see the audit-fix note on [assess]).
///
/// FACTOR WEIGHTS (sum to 1.0, configurable via constructor):
///   Core Perception & Behaviour ......... 0.60  (caller-supplied RiskAssessment)
///   Approach Trend ....................... 0.22  (is the top hazard closing?)
///   Destination Confidence ............... 0.10  (Voice Understanding Layer)
///   GPS Accuracy .......................... 0.08  (poor fix -> less trustworthy signals)
///
/// REMOVED, DELIBERATELY, NOT JUST UNUSED — "Transit Phase" (was 0.10)
/// and "Road Crossing" (was 0.08) factors: an execution-trace audit
/// found both were, in the current architecture, incapable of ever
/// receiving a real signal — the vision pipeline only runs during
/// `NavigationScreen`'s walking loop, never during
/// `TransitJourneyGuideScreen`'s transit legs (a deliberate, separate
/// design choice made earlier to keep vision code out of that
/// screen), and no road-crossing classifier exists anywhere in this
/// app. Scoring a factor that can only ever receive its neutral
/// default is worse than not having it — it silently inflates every
/// assessment's factor count without ever actually varying, which
/// would misrepresent the engine's real sensitivity in any research
/// evaluation of it. Removed cleanly rather than left connected to
/// nothing: the corresponding `AdaptiveRiskInput` fields and
/// `TransitPhase`/road-crossing scoring methods are gone too, not
/// just unreferenced. Re-adding them is legitimate future work IF the
/// two screens' vision loops are ever unified — a genuine redesign,
/// not something to fake around in the meantime.
///
/// STATEFUL, LIKE HazardTemporalFilter, UNLIKE RiskAssessmentService:
/// the Approach Trend factor needs the previous frame's distance
/// reading for the same hazard label, so — like HazardTemporalFilter —
/// one instance must be owned and reused across frames, not
/// constructed fresh per call.
///
/// APPROACH TREND IS BY-LABEL, NOT BY-OBJECT-IDENTITY — same
/// documented convention and same honest limitation as
/// HazardTemporalFilter: this app has no per-instance object tracker
/// (no ID persists frame-to-frame), so "is the car getting closer" is
/// approximated as "is the estimated distance for the label 'car'
/// trending down across consecutive frames," which could be a
/// different physical car if one leaves and another enters frame
/// under the same label. This is the same accepted trade-off already
/// documented and shipped for hazard confirmation; the alternative
/// (a full multi-object tracker with re-identification) is real
/// future work, not something faked here as already solved.
class AdaptiveRiskEngine {
  final double coreWeight;
  final double approachTrendWeight;
  final double destinationConfidenceWeight;
  final double gpsAccuracyWeight;

  AdaptiveRiskEngine({
    this.coreWeight = 0.60,
    this.approachTrendWeight = 0.22,
    this.destinationConfidenceWeight = 0.10,
    this.gpsAccuracyWeight = 0.08,
  }) {
    final total = coreWeight + approachTrendWeight + destinationConfidenceWeight + gpsAccuracyWeight;
    assert((total - 1.0).abs() < 0.001, 'AdaptiveRiskEngine factor weights must sum to 1.0 (got $total)');
  }

  // Matches RiskAssessmentService's own thresholds for consistency —
  // duplicated here because that service's are private; kept in sync
  // by using literally the same values (0.30/0.55/0.80).
  static const double _lowThreshold = 0.30;
  static const double _mediumThreshold = 0.55;
  static const double _highThreshold = 0.80;

  final Map<String, double> _lastKnownDistanceByLabel = {};

  /// Combines the ALREADY-COMPUTED [coreAssessment] (the same
  /// `RiskAssessment` a caller like `NavigationScreen` already
  /// produced via `RiskAssessmentService.assess()` for its own use)
  /// with the new cross-subsystem factors below.
  ///
  /// AUDIT FIX (execution-trace audit, "duplicate RiskAssessmentService
  /// computation"): this method used to call
  /// `RiskAssessmentService.assess()` a SECOND time internally, with
  /// the same inputs the caller had already computed one call
  /// earlier — a real, wasteful duplicate computation every frame,
  /// even though harmless (the call is pure/stateless, so the result
  /// was identical either way). Callers now pass their own
  /// already-computed [RiskAssessment] in directly; this class no
  /// longer holds or calls `RiskAssessmentService` at all.
  AdaptiveRiskAssessment assess(AdaptiveRiskInput input, RiskAssessment coreAssessment) {
    final factors = <RiskFactor>[
      RiskFactor(
        name: 'Core Perception & Behaviour',
        weight: coreWeight,
        score: coreAssessment.overallRiskScore,
        description: coreAssessment.explanation,
      ),
      _approachTrendFactor(input.topHazard),
      _destinationConfidenceFactor(input.destinationConfidence, input.awaitingVoiceConfirmation),
      _gpsAccuracyFactor(input.gpsAccuracyMeters),
    ];

    final overallScore = factors.fold<double>(0.0, (sum, f) => sum + f.weightedScore).clamp(0.0, 1.0);

    return AdaptiveRiskAssessment(
      overallRiskScore: overallScore,
      riskLevel: _levelFor(overallScore),
      riskFactors: factors,
      coreAssessment: coreAssessment,
      explanation: _buildExplanation(factors),
    );
  }

  RiskFactor _approachTrendFactor(DetectedHazard? hazard) {
    if (hazard == null || hazard.estimatedDistanceMeters == null) {
      return RiskFactor(
        name: 'Approach Trend',
        weight: approachTrendWeight,
        score: 0.3,
        description: 'no distance trend available',
      );
    }
    final currentDistance = hazard.estimatedDistanceMeters!;
    final previousDistance = _lastKnownDistanceByLabel[hazard.label];
    _lastKnownDistanceByLabel[hazard.label] = currentDistance;

    if (previousDistance == null) {
      return RiskFactor(
        name: 'Approach Trend',
        weight: approachTrendWeight,
        score: 0.4,
        description: 'first observation of this hazard, trend unknown',
      );
    }
    final delta = previousDistance - currentDistance; // positive = closing
    if (delta > 0.3) {
      final score = (delta / 2.0).clamp(0.5, 1.0);
      return RiskFactor(
        name: 'Approach Trend',
        weight: approachTrendWeight,
        score: score,
        description: 'closing distance (~${delta.toStringAsFixed(1)}m since last check)',
      );
    } else if (delta < -0.3) {
      return RiskFactor(
        name: 'Approach Trend',
        weight: approachTrendWeight,
        score: 0.1,
        description: 'moving away',
      );
    }
    return RiskFactor(
      name: 'Approach Trend',
      weight: approachTrendWeight,
      score: 0.3,
      description: 'steady distance',
    );
  }

  RiskFactor _destinationConfidenceFactor(double? destinationConfidence, bool awaitingConfirmation) {
    if (awaitingConfirmation) {
      return RiskFactor(
        name: 'Destination Confidence',
        weight: destinationConfidenceWeight,
        score: 0.6,
        description: 'awaiting voice confirmation of destination',
      );
    }
    if (destinationConfidence == null) {
      return RiskFactor(
        name: 'Destination Confidence',
        weight: destinationConfidenceWeight,
        score: 0.3,
        description: 'no destination-confidence signal available',
      );
    }
    final score = (1.0 - destinationConfidence).clamp(0.0, 1.0);
    return RiskFactor(
      name: 'Destination Confidence',
      weight: destinationConfidenceWeight,
      score: score,
      description: score > 0.4 ? 'low destination-resolution confidence' : 'destination well-resolved',
    );
  }

  RiskFactor _gpsAccuracyFactor(double? accuracyMeters) {
    if (accuracyMeters == null) {
      return RiskFactor(
        name: 'GPS Accuracy',
        weight: gpsAccuracyWeight,
        score: 0.3,
        description: 'GPS accuracy unknown',
      );
    }
    final score = (accuracyMeters / 30.0).clamp(0.0, 1.0);
    return RiskFactor(
      name: 'GPS Accuracy',
      weight: gpsAccuracyWeight,
      score: score,
      description: score > 0.5 ? 'poor GPS accuracy (${accuracyMeters.toStringAsFixed(0)}m)' : 'good GPS accuracy',
    );
  }

  RiskLevel _levelFor(double score) {
    if (score >= _highThreshold) return RiskLevel.critical;
    if (score >= _mediumThreshold) return RiskLevel.high;
    if (score >= _lowThreshold) return RiskLevel.medium;
    return RiskLevel.low;
  }

  String _buildExplanation(List<RiskFactor> factors) {
    final sorted = [...factors]..sort((a, b) => b.weightedScore.compareTo(a.weightedScore));
    final significant = sorted.where((f) => f.score > 0.4).take(3).toList();
    if (significant.isEmpty) return 'No significant risk factors detected.';
    return significant.map((f) => f.description).join(' + ');
  }
}
