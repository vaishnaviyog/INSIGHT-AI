/// Coarse age bracket, collected once at onboarding purely as profile
/// metadata — no existing service currently branches on this. Stored
/// so it's available if a future feature needs it, per the same
/// "store real data, don't fabricate integration that isn't there yet"
/// principle used throughout this codebase (see RoadAttributesProvider,
/// IEmergencySignalSource).
enum AgeGroup { below18, age18to40, age41to60, above60, unspecified }

/// Self-reported vision condition. [visionCondition] IS consumed by
/// navigation_screen.dart today: users who select [completelyBlind]
/// don't have the on-screen "Detected: X" text overlay updated, since
/// it serves no purpose for them and the extra setState/build work is
/// pure overhead; [lowVision] and [progressiveVisionLoss] keep seeing
/// it, since residual/partial vision can genuinely use a visual cue
/// alongside the spoken one.
enum VisionCondition { completelyBlind, lowVision, progressiveVisionLoss, other, unspecified }

/// Mobility aid in use. Stored as profile metadata; no existing
/// service currently branches on this (documented here, not silently
/// implied) — a future feature (e.g. lower-height obstacle relevance
/// for a guide-dog user) could consume it without any change to this
/// model.
enum MobilityAid { whiteCane, guideDog, none, other, unspecified }

/// Maps to a seed value for
/// [BehaviourLearningService.seedFromOnboarding] — a starting point
/// for the running-average walking speed, used only until enough real
/// GPS samples exist to outweigh it (see that method's doc comment).
enum WalkingSpeedPreference { slow, normal, fast }

extension WalkingSpeedPreferenceMeters on WalkingSpeedPreference {
  /// Hand-picked reference values for an average adult pedestrian
  /// pace, not measured from this app's own users — the same kind of
  /// documented, reasonable-starting-point constant already used for
  /// RiskAssessmentService's speed-factor reference band (1.0-1.4 m/s
  /// = normal pace).
  double get metersPerSecond => switch (this) {
        WalkingSpeedPreference.slow => 0.8,
        WalkingSpeedPreference.normal => 1.2,
        WalkingSpeedPreference.fast => 1.6,
      };
}

/// Consumed by [AdaptiveGuidanceService.decideObstacleWarning] as a
/// fourth, optional interval multiplier axis (alongside risk,
/// experience, and intent) — see that method's doc comment.
enum WarningDistancePreference { veryEarly, early, normal, late }

/// Consumed by [SafeRouteService.selectSafestRoute] to change how a
/// route is chosen among scored candidates — see that method's doc
/// comment for exactly how each value changes the selection rule.
enum RoutePreference { safest, balanced, fastest }

/// Suggested categories for Step 6 (Frequently Visited Places). [other]
/// covers anything not in the suggested list; every category is
/// skippable at onboarding time (an empty [FrequentPlace] list is a
/// normal, valid state, not an error).
enum FrequentPlaceCategory { home, workOrCollege, hospital, busStop, groceryStore, pharmacy, other }

/// One saved destination — resolved to real coordinates via
/// [LocationService.getCoordinatesFromAddress] at the time it's saved
/// (never fabricated), then fed into
/// [BehaviourLearningService.seedFromOnboarding] so the exact same
/// `frequentlyVisitedLocations` field [IntentInferenceService] and
/// [SafeRouteService] already read from is what onboarding populates —
/// no second, parallel "places" data source for those services to
/// miss.
class FrequentPlace {
  final FrequentPlaceCategory category;
  final String label;
  final double latitude;
  final double longitude;

  const FrequentPlace({
    required this.category,
    required this.label,
    required this.latitude,
    required this.longitude,
  });

  Map<String, dynamic> toMap() => {
        'category': category.name,
        'label': label,
        'latitude': latitude,
        'longitude': longitude,
      };

  factory FrequentPlace.fromMap(Map<dynamic, dynamic> map) => FrequentPlace(
        category: FrequentPlaceCategory.values.byName(map['category'] as String),
        label: map['label'] as String,
        latitude: (map['latitude'] as num).toDouble(),
        longitude: (map['longitude'] as num).toDouble(),
      );
}

/// Everything collected during onboarding (or later edited from
/// Settings), persisted as a single Hive entry by [UserProfileService]
/// — same plain Map<String, dynamic> pattern as
/// [UserBehaviourProfile]/[EmergencyEvent], no code generation.
///
/// This is explicitly NOT an authentication/account object — there is
/// no password, no server account, no login. It exists purely to
/// personalize local behavior and seed the services that already do
/// the actual work (BehaviourLearningService, AdaptiveGuidanceService,
/// SafeRouteService, LanguageService, EmergencyService).
class UserProfile {
  final String name;
  final AgeGroup ageGroup;
  final VisionCondition visionCondition;
  final MobilityAid mobilityAid;
  final WalkingSpeedPreference walkingSpeedPreference;
  final WarningDistancePreference warningDistancePreference;
  final RoutePreference routePreference;
  final List<FrequentPlace> frequentPlaces;

  const UserProfile({
    this.name = '',
    this.ageGroup = AgeGroup.unspecified,
    this.visionCondition = VisionCondition.unspecified,
    this.mobilityAid = MobilityAid.unspecified,
    this.walkingSpeedPreference = WalkingSpeedPreference.normal,
    this.warningDistancePreference = WarningDistancePreference.normal,
    this.routePreference = RoutePreference.balanced,
    this.frequentPlaces = const [],
  });

  UserProfile copyWith({
    String? name,
    AgeGroup? ageGroup,
    VisionCondition? visionCondition,
    MobilityAid? mobilityAid,
    WalkingSpeedPreference? walkingSpeedPreference,
    WarningDistancePreference? warningDistancePreference,
    RoutePreference? routePreference,
    List<FrequentPlace>? frequentPlaces,
  }) =>
      UserProfile(
        name: name ?? this.name,
        ageGroup: ageGroup ?? this.ageGroup,
        visionCondition: visionCondition ?? this.visionCondition,
        mobilityAid: mobilityAid ?? this.mobilityAid,
        walkingSpeedPreference: walkingSpeedPreference ?? this.walkingSpeedPreference,
        warningDistancePreference: warningDistancePreference ?? this.warningDistancePreference,
        routePreference: routePreference ?? this.routePreference,
        frequentPlaces: frequentPlaces ?? this.frequentPlaces,
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'ageGroup': ageGroup.name,
        'visionCondition': visionCondition.name,
        'mobilityAid': mobilityAid.name,
        'walkingSpeedPreference': walkingSpeedPreference.name,
        'warningDistancePreference': warningDistancePreference.name,
        'routePreference': routePreference.name,
        'frequentPlaces': frequentPlaces.map((p) => p.toMap()).toList(),
      };

  factory UserProfile.fromMap(Map<dynamic, dynamic> map) => UserProfile(
        name: map['name'] as String? ?? '',
        ageGroup: AgeGroup.values.byName(map['ageGroup'] as String? ?? 'unspecified'),
        visionCondition:
            VisionCondition.values.byName(map['visionCondition'] as String? ?? 'unspecified'),
        mobilityAid: MobilityAid.values.byName(map['mobilityAid'] as String? ?? 'unspecified'),
        walkingSpeedPreference: WalkingSpeedPreference.values
            .byName(map['walkingSpeedPreference'] as String? ?? 'normal'),
        warningDistancePreference: WarningDistancePreference.values
            .byName(map['warningDistancePreference'] as String? ?? 'normal'),
        routePreference:
            RoutePreference.values.byName(map['routePreference'] as String? ?? 'balanced'),
        frequentPlaces: ((map['frequentPlaces'] as List?) ?? [])
            .map((e) => FrequentPlace.fromMap(e as Map))
            .toList(),
      );
}
