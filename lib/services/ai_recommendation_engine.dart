import '../models/user_behaviour_profile.dart';

/// Generates plain-language recommendations from collected behaviour
/// data only. No fabricated statistics: if there isn't enough data to
/// support a recommendation, this returns exactly that message rather
/// than a generic-sounding but unsupported suggestion.
class AIRecommendationEngine {
  /// Minimum sessions before any recommendation beyond "not enough
  /// data" is offered — an explicit, documented threshold, not a
  /// hidden magic number.
  static const int _minimumSessionsForRecommendations = 3;

  List<String> generateRecommendations(UserBehaviourProfile? profile) {
    if (profile == null || profile.totalNavigationSessions < _minimumSessionsForRecommendations) {
      return const ['Not enough data collected.'];
    }

    final recommendations = <String>[];

    if (profile.reactionSampleCount > 0 && profile.averageReactionTime > 3.0) {
      recommendations.add(
        'Earlier warnings recommended — average reaction time '
        '(${profile.averageReactionTime.toStringAsFixed(1)}s) is above the 3.0s comfort threshold.',
      );
    }

    final nearMissRate = profile.totalNavigationSessions > 0
        ? profile.nearMisses / profile.totalNavigationSessions
        : 0.0;
    if (nearMissRate > 0.5) {
      recommendations.add(
        'Safer routes recommended — near misses are occurring in more than half of recent sessions.',
      );
    }

    if (profile.speedSampleCount > 0 && profile.averageWalkingSpeed > 1.8) {
      recommendations.add(
        'More cautious walking speed recommended — average pace '
        '(${profile.averageWalkingSpeed.toStringAsFixed(2)} m/s) is brisk relative to typical hazard-response margins.',
      );
    }

    if (profile.confidenceScore < 0.4) {
      recommendations.add(
        'Preferred guidance mode: detailed — current confidence score '
        '(${profile.confidenceScore.toStringAsFixed(2)}) suggests more verbose guidance may help.',
      );
    } else if (profile.confidenceScore > 0.75 && profile.routeFamiliarityScore > 0.6) {
      recommendations.add(
        'Preferred guidance mode: minimal — high confidence and route familiarity suggest shorter guidance would suffice.',
      );
    }

    if (recommendations.isEmpty) {
      recommendations.add('No specific recommendations — current behaviour patterns look stable.');
    }

    return recommendations;
  }
}
