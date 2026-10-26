enum NavigationDecision {
  continueWalking,
  slowDown,
  stopImmediately,
  moveLeft,
  moveRight,
  wait,
  boardBus,
  prepareForTransfer,
  confirmDestination,
  repeatInstruction,
  requestUserConfirmation,
}

/// Output of `NavigationDecisionEngine.decide` — every navigation
/// decision in INSIGHT is meant to be expressible as one of these,
/// with an explainable [reason] (same explainability contract as
/// [RiskAssessment]/[AdaptiveRiskAssessment]).
class NavigationDecisionResult {
  final NavigationDecision decision;
  final String message;
  final bool interrupt;
  final String reason;

  const NavigationDecisionResult({
    required this.decision,
    required this.message,
    required this.interrupt,
    required this.reason,
  });
}
