import '../../models/user_behaviour_profile.dart';
import '../../models/voice_understanding/destination_resolution.dart';
import '../gtfs/gtfs_geo_utils.dart';
import 'destination_resolver.dart';

/// The layer described in this phase's architecture diagram:
/// STT -> Language Detection -> Voice Understanding Layer ->
/// Destination Resolver -> Journey Planner. This class IS that layer
/// — it wraps [DestinationResolver] (which itself calls
/// `LanguageDetector` internally) and adds the one thing a resolver
/// operating on text alone can't do: boosting confidence using where
/// the user actually goes often, via the EXISTING
/// `BehaviourLearningService`'s recorded `VisitedLocation`s — reused,
/// not duplicated.
///
/// Deliberately does NOT wrap `AudioService`/STT itself — "should
/// improve recognition reliability without replacing the existing
/// Speech-to-Text engine" — callers pass this class already-recognized
/// text; it never touches the microphone.
class VoiceUnderstandingLayer {
  final DestinationResolver _resolver = DestinationResolver();

  /// Step 1: resolve raw recognized text into a destination + text-
  /// based confidence. Does not require geocoding to have happened
  /// yet.
  DestinationResolution resolve(String recognizedText) => _resolver.resolve(recognizedText);

  /// Step 2 (optional, call after geocoding): if the resolved
  /// coordinates land near somewhere the user visits often (per
  /// [frequentlyVisitedLocations], from
  /// `BehaviourLearningService.profile.frequentlyVisitedLocations`),
  /// boost confidence — Phase 1's "frequently visited places should
  /// receive higher confidence" requirement. The boost saturates
  /// (capped at +0.2) and scales with recorded visit count, so a
  /// place visited twice barely moves the needle while a place
  /// visited often can meaningfully raise confidence above the
  /// confirmation threshold.
  DestinationResolution boostConfidenceWithFrequentPlaces({
    required DestinationResolution resolution,
    required double resolvedLat,
    required double resolvedLon,
    required List<VisitedLocation> frequentlyVisitedLocations,
    double proximityRadiusMeters = 300,
  }) {
    for (final visited in frequentlyVisitedLocations) {
      final distance = haversineDistanceMeters(resolvedLat, resolvedLon, visited.latitude, visited.longitude);
      if (distance <= proximityRadiusMeters && visited.visitCount >= 2) {
        final boost = (visited.visitCount / 10.0).clamp(0.0, 0.2);
        final boostedConfidence = (resolution.confidence + boost).clamp(0.0, 1.0);
        return DestinationResolution(
          originalText: resolution.originalText,
          searchQuery: resolution.searchQuery,
          displayName: resolution.displayName,
          matchType: resolution.matchType,
          confidence: boostedConfidence,
          detectedLanguage: resolution.detectedLanguage,
          languageDetectionConfidence: resolution.languageDetectionConfidence,
        );
      }
    }
    return resolution;
  }
}
