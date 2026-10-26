/// The kind of trip the system infers the user is currently making,
/// used to adapt guidance style, warning frequency, and (optionally)
/// route selection. This is inferred, not asked of the user — see
/// [IntentInferenceService] for exactly how.
enum NavigationIntentCategory {
  /// e.g. hospital, clinic, emergency room — likely an urgent visit.
  urgent,

  /// e.g. bus stop, train station, airport — a time-sensitive trip.
  timeSensitive,

  /// e.g. home — a well-known, low-novelty route.
  familiar,

  /// e.g. park, garden — a leisure walk, no urgency.
  leisure,

  /// e.g. college, office, school — routine, repeated travel.
  routine,

  /// e.g. market, grocery store — a trip likely to involve stops.
  frequentStops,

  /// No destination keyword matched and no behavioural signal was
  /// strong enough to infer anything more specific.
  unknown,
}

/// One inferred-intent snapshot: a category, a confidence in [0, 1],
/// and a human-readable justification — mirrors the explainability
/// pattern already used by RiskAssessment/ExplainableAIService
/// elsewhere in this codebase, so a decision downstream (guidance
/// verbosity, route choice) can always be traced back to why.
class NavigationIntent {
  final NavigationIntentCategory category;
  final double confidence;
  final String reason;

  const NavigationIntent({
    required this.category,
    required this.confidence,
    required this.reason,
  });

  static const NavigationIntent unknown = NavigationIntent(
    category: NavigationIntentCategory.unknown,
    confidence: 0.0,
    reason: 'No destination keyword or behavioural signal was strong enough to infer intent.',
  );

  NavigationIntent copyWith({
    NavigationIntentCategory? category,
    double? confidence,
    String? reason,
  }) =>
      NavigationIntent(
        category: category ?? this.category,
        confidence: (confidence ?? this.confidence).clamp(0.0, 1.0),
        reason: reason ?? this.reason,
      );
}
