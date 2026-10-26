import '../models/navigation_intent.dart';
import '../models/user_behaviour_profile.dart';
import 'behaviour_learning_service.dart';

/// Infers WHY the user is likely making this trip — not just WHERE
/// they're going — from the destination text, time of day, and the
/// existing [UserBehaviourProfile] (visit frequency, route
/// familiarity). This is a pure, stateless extension: it reads
/// [UserBehaviourProfile] and [BehaviourLearningService.locationGridPrecision]
/// but never writes to BehaviourLearningService's Hive box and never
/// duplicates its persistence logic — the same "stateless decision
/// layer over shared data" pattern already used by
/// RiskAssessmentService and AdaptiveGuidanceService.
///
/// EXPLAINABILITY: every [NavigationIntent] carries a `reason` string,
/// consistent with RiskAssessment.explanation and
/// ExplainableAIService's output — an inferred intent should always
/// be traceable to the destination keyword, time window, or
/// behavioural signal that produced it, never a silent black box.
class IntentInferenceService {
  /// Destination keyword → category. Matched as a case-insensitive
  /// substring of the destination text, so "City General Hospital"
  /// still matches "hospital". Hand-curated, not learned — consistent
  /// with this project's existing "explainable heuristics over ML"
  /// approach (see AdaptiveGuidanceService's own doc comment).
  static const Map<String, NavigationIntentCategory> _destinationKeywords = {
    'hospital': NavigationIntentCategory.urgent,
    'clinic': NavigationIntentCategory.urgent,
    'emergency room': NavigationIntentCategory.urgent,
    'er': NavigationIntentCategory.urgent,
    'pharmacy': NavigationIntentCategory.urgent,
    'bus stop': NavigationIntentCategory.timeSensitive,
    'bus station': NavigationIntentCategory.timeSensitive,
    'train station': NavigationIntentCategory.timeSensitive,
    'railway': NavigationIntentCategory.timeSensitive,
    'airport': NavigationIntentCategory.timeSensitive,
    'metro': NavigationIntentCategory.timeSensitive,
    'home': NavigationIntentCategory.familiar,
    'park': NavigationIntentCategory.leisure,
    'garden': NavigationIntentCategory.leisure,
    'beach': NavigationIntentCategory.leisure,
    'college': NavigationIntentCategory.routine,
    'university': NavigationIntentCategory.routine,
    'school': NavigationIntentCategory.routine,
    'office': NavigationIntentCategory.routine,
    'workplace': NavigationIntentCategory.routine,
    'work': NavigationIntentCategory.routine,
    'market': NavigationIntentCategory.frequentStops,
    'grocery': NavigationIntentCategory.frequentStops,
    'supermarket': NavigationIntentCategory.frequentStops,
    'mall': NavigationIntentCategory.frequentStops,
    'store': NavigationIntentCategory.frequentStops,
  };

  /// Initial inference, made once a destination is known (typically
  /// right after `_fetchRoute()` resolves it) — before any live
  /// navigation signal exists yet.
  NavigationIntent inferInitial({
    required String destination,
    required DateTime time,
    UserBehaviourProfile? profile,
    double? destinationLatitude,
    double? destinationLongitude,
  }) {
    final lowerDestination = destination.toLowerCase();

    NavigationIntentCategory? matchedCategory;
    String? matchedKeyword;
    for (final entry in _destinationKeywords.entries) {
      if (lowerDestination.contains(entry.key)) {
        matchedCategory = entry.value;
        matchedKeyword = entry.key;
        break;
      }
    }

    if (matchedCategory == null) {
      return NavigationIntent.unknown;
    }

    double confidence = 0.6; // base confidence from a keyword match alone
    final reasonParts = <String>['destination matched keyword "$matchedKeyword"'];

    // Familiarity/frequency boost: if the destination coordinates
    // land in an already-frequented grid cell (see
    // BehaviourLearningService's own grid), that's a real, existing
    // signal reinforcing "familiar"/"routine"/"frequentStops" reads,
    // and mildly undercuts an "urgent" read (a place visited often is
    // less likely to be a one-off emergency, though not ruled out).
    if (profile != null && destinationLatitude != null && destinationLongitude != null) {
      final key = '${destinationLatitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)},'
          '${destinationLongitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)}';
      final match = profile.frequentlyVisitedLocations.where((l) =>
          '${l.latitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)},'
              '${l.longitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)}' ==
          key);
      if (match.isNotEmpty) {
        final visitCount = match.first.visitCount;
        if (matchedCategory == NavigationIntentCategory.familiar ||
            matchedCategory == NavigationIntentCategory.routine ||
            matchedCategory == NavigationIntentCategory.frequentStops) {
          confidence += 0.2;
          reasonParts.add('destination is a frequently-visited location (visited $visitCount times)');
        } else if (matchedCategory == NavigationIntentCategory.urgent) {
          confidence -= 0.1;
          reasonParts.add(
              'destination has been visited $visitCount times before, slightly reducing confidence this is a one-off urgent visit');
        }
      }
    }

    // Time-of-day adjustment: a hand-picked, documented heuristic —
    // not learned. Commute-hour travel to a routine destination
    // reinforces "routine"; very-late-night travel to anywhere
    // slightly reinforces a time-sensitive/urgent read, since leisure
    // walks are less common at that hour.
    final hour = time.hour;
    final isCommuteHour = (hour >= 7 && hour <= 10) || (hour >= 16 && hour <= 19);
    final isLateNight = hour >= 22 || hour < 5;

    if (isCommuteHour && matchedCategory == NavigationIntentCategory.routine) {
      confidence += 0.1;
      reasonParts.add('time of day (${time.hour}:00) matches a typical commute window');
    }
    if (isLateNight &&
        (matchedCategory == NavigationIntentCategory.leisure ||
            matchedCategory == NavigationIntentCategory.frequentStops)) {
      confidence -= 0.1;
      reasonParts.add('late-night travel is less typical for this destination type, reducing confidence');
    }

    return NavigationIntent(
      category: matchedCategory,
      confidence: confidence.clamp(0.0, 1.0),
      reason: reasonParts.join('; '),
    );
  }

  /// Continuously refines confidence in an already-inferred intent
  /// using LIVE signals collected during the session — reusing
  /// [UserBehaviourProfile] fields and the route-deviation count
  /// NavigationMetricsTracker already collects, rather than adding new
  /// tracking of its own. Called periodically during navigation (e.g.
  /// alongside the existing position-stream listener).
  ///
  /// Deliberately only ADJUSTS the existing category's confidence, up
  /// or down — it does not re-run keyword matching or switch
  /// categories mid-trip, since flip-flopping the inferred intent
  /// would make any guidance/verbosity change built on it feel
  /// erratic to the user.
  NavigationIntent refineDuringNavigation({
    required NavigationIntent current,
    required double? currentSpeedMetersPerSecond,
    required int routeDeviationCount,
  }) {
    if (current.category == NavigationIntentCategory.unknown) return current;

    double confidenceDelta = 0.0;
    final notes = <String>[];

    // Sustained fast walking reinforces an urgent/time-sensitive read;
    // a slow, unhurried pace reinforces leisure/familiar.
    if (currentSpeedMetersPerSecond != null) {
      final isBrisk = currentSpeedMetersPerSecond > 1.6;
      final isSlow = currentSpeedMetersPerSecond < 0.9;
      if (isBrisk &&
          (current.category == NavigationIntentCategory.urgent ||
              current.category == NavigationIntentCategory.timeSensitive)) {
        confidenceDelta += 0.05;
        notes.add('sustained brisk walking pace observed');
      } else if (isSlow &&
          (current.category == NavigationIntentCategory.leisure ||
              current.category == NavigationIntentCategory.familiar)) {
        confidenceDelta += 0.05;
        notes.add('relaxed walking pace observed');
      }
    }

    // Frequent route deviations undercut confidence in ANY inferred
    // intent — they suggest the trip isn't unfolding as a familiar/
    // routine/urgent-direct trip would, regardless of which category
    // was guessed.
    if (routeDeviationCount > 3) {
      confidenceDelta -= 0.05;
      notes.add('multiple route deviations reduce confidence in the initial read');
    }

    if (confidenceDelta == 0.0) return current;

    return current.copyWith(
      confidence: current.confidence + confidenceDelta,
      reason: '${current.reason}; updated: ${notes.join('; ')}',
    );
  }
}
