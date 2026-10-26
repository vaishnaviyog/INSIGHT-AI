import '../models/detected_hazard.dart';
import '../models/navigation_intent.dart';
import '../models/risk_assessment.dart';
import '../models/user_behaviour_profile.dart';
import '../models/user_profile.dart';

/// Coarse experience tiers derived from navigation history.
/// Deliberately simple (session-count thresholds), not learned —
/// consistent with the project's "explainable heuristics over ML"
/// approach used throughout Milestones 2 and 3.
enum UserExperienceLevel { beginner, intermediate, experienced }

/// The result of a guidance decision: WHETHER to speak, WHAT to say,
/// and whether it's urgent enough to interrupt ongoing speech.
/// [reason] exists for the same explainability reason
/// [RiskAssessment.explanation] does — so a decision can be logged
/// and justified, not just acted on silently.
class GuidanceDecision {
  final bool shouldSpeak;
  final String message;
  final bool interrupt;
  final Duration effectiveRepeatInterval;
  final String reason;

  const GuidanceDecision({
    required this.shouldSpeak,
    required this.message,
    required this.interrupt,
    required this.effectiveRepeatInterval,
    required this.reason,
  });
}

/// Decides WHEN, WHETHER, and HOW VERBOSELY to speak a message.
///
/// THIS IS A DECISION LAYER ONLY. Per the Milestone 4 requirement,
/// the existing speech architecture is untouched: this class calls no
/// TTS/STT API and does not modify [AudioService] in any way — it has
/// no dependency on it at all. `navigation_screen.dart` asks this
/// service for a [GuidanceDecision] and then uses the SAME, unchanged
/// `AudioService.speak()` / `AudioService.stopSpeaking()` it always
/// has. If this service were deleted entirely, the app would simply
/// revert to its original fixed-interval, fixed-phrasing behavior —
/// which is also exactly what happens by default for a brand-new user
/// with no behaviour/risk data yet (see [_buildMessage]).
///
/// STATELESS, mirroring [RiskAssessmentService]: every input is
/// passed explicitly into [decideObstacleWarning], so this class is
/// directly unit-testable and holds no service references.
class AdaptiveGuidanceService {
  /// Matches the ORIGINAL app's fixed 5-second obstacle-warning
  /// repeat interval. This is the baseline every multiplier below
  /// scales from — a user with no risk/behaviour data (multipliers
  /// ≈1.0) gets behavior very close to the pre-Milestone-4 app.
  static const Duration _baseRepeatInterval = Duration(seconds: 5);

  /// Session-count thresholds for experience tiers. Hand-picked, not
  /// learned — documented here as the single place to retune.
  UserExperienceLevel experienceLevelFor(UserBehaviourProfile? profile) {
    final sessions = profile?.totalNavigationSessions ?? 0;
    if (sessions < 3) return UserExperienceLevel.beginner;
    if (sessions < 15) return UserExperienceLevel.intermediate;
    return UserExperienceLevel.experienced;
  }

  /// Decides how to handle the next obstacle-warning opportunity for
  /// [hazard]. Called on every frame a hazard is present;
  /// `shouldSpeak` being false is the normal "not time yet" case, not
  /// an error.
  ///
  /// [intent] is OPTIONAL (Feature 3: Contextual Intent Inference).
  /// When omitted (the default, and every pre-existing call site's
  /// behavior), this method's output is byte-for-byte identical to
  /// before this parameter existed. When supplied, it applies a THIRD
  /// interval multiplier on top of the existing risk/experience axes,
  /// and can shift message verbosity — e.g. an "urgent" intent
  /// (hospital, pharmacy) tightens warnings further; a "leisure"
  /// intent (park) relaxes them. Low-confidence inferences
  /// (confidence < 0.4) are treated the same as no intent at all, so
  /// a shaky guess never meaningfully changes guidance behavior.
  ///
  /// [warningDistancePreference] is OPTIONAL (onboarding Step 4). When
  /// omitted or `normal` (the default), it applies a 1.0x multiplier —
  /// i.e. no behavior change from before this parameter existed. It
  /// applies a FOURTH interval multiplier: `veryEarly`/`early` warn
  /// sooner and more often (shorter interval), `late` warns less often
  /// — the same axis-multiplication pattern as risk/experience/intent,
  /// not a separate code path.
  GuidanceDecision decideObstacleWarning({
    required DetectedHazard hazard,
    required RiskAssessment? risk,
    required UserBehaviourProfile? profile,
    required Duration timeSinceLastWarning,
    NavigationIntent? intent,
    WarningDistancePreference warningDistancePreference = WarningDistancePreference.normal,
  }) {
    final experience = experienceLevelFor(profile);
    final riskLevel = risk?.riskLevel ?? RiskLevel.low;

    // Risk axis: higher risk → shorter interval (more frequent,
    // "repeated guidance") and, at Critical, permission to interrupt
    // ("priority speech"). Low risk → longer interval ("minimal
    // interruption").
    double intervalMultiplier = switch (riskLevel) {
      RiskLevel.critical => 0.5,
      RiskLevel.high => 0.75,
      RiskLevel.medium => 1.0,
      RiskLevel.low => 1.5,
    };

    // Experience axis: beginners get earlier/more frequent warnings;
    // experienced users get later warnings with less repetition.
    intervalMultiplier *= switch (experience) {
      UserExperienceLevel.beginner => 0.8,
      UserExperienceLevel.intermediate => 1.0,
      UserExperienceLevel.experienced => 1.3,
    };

    // Intent axis (optional, additive — see doc comment above).
    final bool useIntent = intent != null && intent.confidence >= 0.4;
    if (useIntent) {
      intervalMultiplier *= switch (intent.category) {
        NavigationIntentCategory.urgent => 0.6,
        NavigationIntentCategory.timeSensitive => 0.85,
        NavigationIntentCategory.familiar => 1.2,
        NavigationIntentCategory.leisure => 1.4,
        NavigationIntentCategory.routine => 1.0,
        NavigationIntentCategory.frequentStops => 1.1,
        NavigationIntentCategory.unknown => 1.0,
      };
    }

    // Warning-distance-preference axis (optional, additive — see doc
    // comment above). `normal` is 1.0x, so an unspecified/default
    // preference changes nothing.
    intervalMultiplier *= switch (warningDistancePreference) {
      WarningDistancePreference.veryEarly => 0.55,
      WarningDistancePreference.early => 0.8,
      WarningDistancePreference.normal => 1.0,
      WarningDistancePreference.late => 1.3,
    };

    final effectiveInterval = Duration(
      milliseconds: (_baseRepeatInterval.inMilliseconds * intervalMultiplier).round(),
    );

    final shouldSpeak = timeSinceLastWarning >= effectiveInterval;
    final interrupt = riskLevel == RiskLevel.critical;
    final message = _buildMessage(
      hazard,
      riskLevel,
      experience,
      intent: useIntent ? intent : null,
    );

    return GuidanceDecision(
      shouldSpeak: shouldSpeak,
      message: message,
      interrupt: interrupt,
      effectiveRepeatInterval: effectiveInterval,
      reason: 'risk=${riskLevel.name} experience=${experience.name} '
          '${useIntent ? 'intent=${intent.category.name}(${intent.confidence.toStringAsFixed(2)}) ' : ''}'
          '${warningDistancePreference != WarningDistancePreference.normal ? 'warningDistance=${warningDistancePreference.name} ' : ''}'
          'interval=${effectiveInterval.inMilliseconds}ms interrupt=$interrupt',
    );
  }

  /// Builds the spoken message.
  ///
  /// REWRITTEN (explicit project requirement, "VOICE OUTPUT" section):
  /// previously spoke only the bare label ("Caution, there is a car
  /// right in front of you." / "car ahead."). Now always includes
  /// left/center/right position (from [DetectedHazard.horizontalPosition])
  /// and an approximate distance in meters (from
  /// [DetectedHazard.estimatedDistanceMeters]) when available — e.g.
  /// "Person ahead. Approximately 1.8 meters." / "Car on your left.
  /// Approximately 3 meters." Only the FRAMING (urgency wording,
  /// whether an explicit "Caution"/"Urgent!" preamble is spoken) still
  /// varies by risk/experience/intent, exactly as before — the
  /// cadence/interval decision in [decideObstacleWarning] above is
  /// completely unchanged.
  ///
  /// Gracefully degrades when position/distance aren't available (no
  /// bounding box, or the label has no configured known height in
  /// `DistanceEstimationConfig`) — falls back to the label alone
  /// rather than ever speaking a broken "Approximately null meters."
  String _buildMessage(
    DetectedHazard hazard,
    RiskLevel riskLevel,
    UserExperienceLevel experience, {
    NavigationIntent? intent,
  }) {
    final objectName = hazard.label;
    final capitalized = objectName.isEmpty
        ? objectName
        : objectName[0].toUpperCase() + objectName.substring(1);

    final positionPhrase = switch (hazard.horizontalPosition) {
      HorizontalPosition.left => 'on your left',
      HorizontalPosition.right => 'on your right',
      HorizontalPosition.center => 'ahead',
      null => 'ahead', // no bounding box to derive a side from — same default as "center"
    };

    final distance = hazard.estimatedDistanceMeters;
    final distanceText = distance == null
        ? null
        : 'Approximately ${_formatDistance(distance)} meters.';

    // AUDIT ADD (Phase 3/4 — Time-to-Collision): only spoken when a
    // safe TTC estimate exists and is short (see
    // CollisionTimeEstimator's doc comment for exactly when that's
    // true) — never fabricated, and never spoken for a stationary or
    // receding object.
    final ttc = hazard.timeToCollisionSeconds;
    final approachingPhrase = (ttc != null && ttc <= 3.0) ? ' Approaching quickly.' : '';

    final subjectSentence = '$capitalized $positionPhrase.';

    final wantsShortForm = (experience == UserExperienceLevel.experienced) ||
        (intent?.category == NavigationIntentCategory.urgent);

    if (riskLevel == RiskLevel.critical) {
      return distanceText != null
          ? 'Urgent! $subjectSentence $distanceText$approachingPhrase Be careful.'
          : 'Urgent! $capitalized very close, be careful.';
    }

    // Experienced users / urgent intent still get position+distance
    // (that's the actually useful safety information) — they just
    // skip the "Caution," framing, matching the original app's
    // "shorter instructions for experienced users" intent.
    if (wantsShortForm && riskLevel != RiskLevel.high) {
      return distanceText != null ? '$subjectSentence $distanceText$approachingPhrase' : subjectSentence;
    }

    return distanceText != null
        ? 'Caution, $capitalized $positionPhrase. $distanceText$approachingPhrase'
        : 'Caution, $subjectSentence';
  }

  /// "3" instead of "3.0", "1.8" as-is — matches the mixed-precision
  /// style in the project's own examples ("Approximately 1.8 meters."
  /// / "Approximately 3 meters.").
  String _formatDistance(double meters) {
    final rounded = (meters * 10).round() / 10;
    return rounded == rounded.roundToDouble()
        ? rounded.toInt().toString()
        : rounded.toStringAsFixed(1);
  }
}
