import '../detected_hazard.dart';

/// Coarse phase of the current journey — used directly by
/// `NavigationDecisionEngine.decide()` (its own `transitPhase`
/// parameter, unaffected by anything in this file), NOT by
/// `AdaptiveRiskEngine` any more — see that class's doc comment for
/// why its own transit-phase/road-crossing factors were removed
/// rather than left connected to nothing.
enum TransitPhase { walking, approachingStop, boarding, onVehicle, transferring, arrived, unknown }

/// Everything `AdaptiveRiskEngine.assess()` actually reads.
///
/// AUDIT FIX (execution-trace audit + follow-up correctness pass):
/// this used to also carry `allCurrentHazards`, `currentSpeedMetersPerSecond`,
/// `behaviourProfile`, `environment`, `transitPhase`, and `isRoadCrossing` —
/// all either passed straight through to an internal
/// `RiskAssessmentService.assess()` call that has since been removed
/// (the caller now computes that once and passes the RESULT into
/// `AdaptiveRiskEngine.assess()` directly instead — see that method's
/// doc comment on the duplicate-computation fix), or scored by factors
/// that were removed as unsupportable (see `AdaptiveRiskEngine`'s doc
/// comment). Keeping those fields here after both of those changes
/// would have made this class the dead-data equivalent of what the
/// audit flagged elsewhere — constructed and populated by the caller,
/// never read. Trimmed to exactly what's used.
class AdaptiveRiskInput {
  /// Used for the Approach Trend factor (is this hazard's estimated
  /// distance closing across frames?) — not passed to any other
  /// service from here.
  final DetectedHazard? topHazard;

  /// From `DestinationResolution.confidence` (Voice Understanding
  /// Layer) — low confidence here means the user might currently be
  /// heading somewhere they didn't actually mean to.
  final double? destinationConfidence;
  final bool awaitingVoiceConfirmation;

  /// From `Position.accuracy` (meters) — poor GPS accuracy means
  /// every other location-derived signal is less trustworthy right now.
  final double? gpsAccuracyMeters;

  const AdaptiveRiskInput({
    this.topHazard,
    this.destinationConfidence,
    this.awaitingVoiceConfirmation = false,
    this.gpsAccuracyMeters,
  });
}
