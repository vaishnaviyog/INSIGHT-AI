/// A single "place" the user has passed through often enough to be
/// worth remembering, bucketed onto a coarse grid (see
/// [BehaviourLearningService.locationGridPrecision]) so nearby GPS
/// samples collapse into one entry instead of creating thousands of
/// near-duplicate points.
class VisitedLocation {
  final double latitude;
  final double longitude;
  int visitCount;
  DateTime lastVisited;

  VisitedLocation({
    required this.latitude,
    required this.longitude,
    required this.visitCount,
    required this.lastVisited,
  });

  Map<String, dynamic> toMap() => {
        'latitude': latitude,
        'longitude': longitude,
        'visitCount': visitCount,
        'lastVisited': lastVisited.toIso8601String(),
      };

  factory VisitedLocation.fromMap(Map<dynamic, dynamic> map) => VisitedLocation(
        latitude: (map['latitude'] as num).toDouble(),
        longitude: (map['longitude'] as num).toDouble(),
        visitCount: map['visitCount'] as int,
        lastVisited: DateTime.parse(map['lastVisited'] as String),
      );
}

/// The user's accumulating mobility profile.
///
/// IMPORTANT — Milestone 2 scope: this is a plain data container plus
/// simple running-average/heuristic bookkeeping. There is deliberately
/// NO machine learning here (per the Milestone 2 requirement) — every
/// field below is updated by straightforward arithmetic in
/// [BehaviourLearningService]. Turning this into a learned model is
/// explicitly out of scope until a later milestone.
///
/// Persistence: stored as a single Hive entry via [toMap]/[fromMap]
/// (see [BehaviourLearningService]). Using plain Map<String, dynamic>
/// (rather than a generated Hive TypeAdapter) avoids adding a
/// build_runner code-generation step to the project for this
/// milestone — Hive natively supports Maps/Lists of primitives, so
/// this is still genuinely "persisted locally using Hive", just
/// without extra tooling.
class UserBehaviourProfile {
  // --- Core fields required by the Milestone 2 specification ---------

  /// Running average walking speed, in meters/second.
  double averageWalkingSpeed;

  /// Running average time between an obstacle warning being spoken
  /// and the obstacle clearing from view, in seconds. See
  /// [BehaviourLearningService] for exactly how this is measured.
  ///
  /// AUDIT NOTE (P0-5 — research-integrity semantics): despite the
  /// field name (kept as-is for Hive persistence compatibility — a
  /// rename here would silently break reading already-persisted
  /// profiles), this is a BEHAVIORAL CLEARANCE-LATENCY PROXY, NOT a
  /// measured human reaction time. There is no sensor confirming the
  /// user actually reacted to anything; this only measures how long
  /// the hazard-detection pipeline kept reporting the same hazard
  /// present. Every user/research-facing label derived from this
  /// value (RiskAssessmentService's RiskFactor name,
  /// MetricsReportService's report entries) says "clearance latency,"
  /// not "reaction time" — only this underlying field/Hive key did
  /// not change.
  double averageReactionTime;

  /// 'left', 'right', or null if no clear preference has emerged yet.
  String? preferredTurningDirection;

  /// Simple heuristic confidence score in [0.0, 1.0]. Not a
  /// statistically calibrated value — see
  /// [BehaviourLearningService.recordObstacleReaction] for the exact
  /// (intentionally simple) update rule.
  double confidenceScore;

  int successfulObstacleAvoidances;
  int nearMisses;

  List<VisitedLocation> frequentlyVisitedLocations;

  /// Heuristic in [0.0, 1.0] describing how much of the most recent
  /// navigation session retraced already-known locations.
  double routeFamiliarityScore;

  int totalNavigationSessions;
  double totalWalkingDistanceMeters;
  DateTime lastUpdated;

  // --- Internal accumulators ------------------------------------------
  // Not part of the Milestone 2 field list itself, but required to
  // correctly maintain the running-average fields above across app
  // restarts (a running average can't be recomputed from nothing —
  // it needs to remember how many samples contributed to it so far).
  int speedSampleCount;
  int reactionSampleCount;
  int leftTurnCount;
  int rightTurnCount;

  UserBehaviourProfile({
    required this.averageWalkingSpeed,
    required this.averageReactionTime,
    required this.preferredTurningDirection,
    required this.confidenceScore,
    required this.successfulObstacleAvoidances,
    required this.nearMisses,
    required this.frequentlyVisitedLocations,
    required this.routeFamiliarityScore,
    required this.totalNavigationSessions,
    required this.totalWalkingDistanceMeters,
    required this.lastUpdated,
    required this.speedSampleCount,
    required this.reactionSampleCount,
    required this.leftTurnCount,
    required this.rightTurnCount,
  });

  /// A fresh, empty profile for first-time use (no Hive data yet).
  factory UserBehaviourProfile.initial() => UserBehaviourProfile(
        averageWalkingSpeed: 0.0,
        averageReactionTime: 0.0,
        preferredTurningDirection: null,
        confidenceScore: 0.5, // neutral starting point
        successfulObstacleAvoidances: 0,
        nearMisses: 0,
        frequentlyVisitedLocations: [],
        routeFamiliarityScore: 0.0,
        totalNavigationSessions: 0,
        totalWalkingDistanceMeters: 0.0,
        lastUpdated: DateTime.now(),
        speedSampleCount: 0,
        reactionSampleCount: 0,
        leftTurnCount: 0,
        rightTurnCount: 0,
      );

  Map<String, dynamic> toMap() => {
        'averageWalkingSpeed': averageWalkingSpeed,
        'averageReactionTime': averageReactionTime,
        'preferredTurningDirection': preferredTurningDirection,
        'confidenceScore': confidenceScore,
        'successfulObstacleAvoidances': successfulObstacleAvoidances,
        'nearMisses': nearMisses,
        'frequentlyVisitedLocations':
            frequentlyVisitedLocations.map((l) => l.toMap()).toList(),
        'routeFamiliarityScore': routeFamiliarityScore,
        'totalNavigationSessions': totalNavigationSessions,
        'totalWalkingDistanceMeters': totalWalkingDistanceMeters,
        'lastUpdated': lastUpdated.toIso8601String(),
        'speedSampleCount': speedSampleCount,
        'reactionSampleCount': reactionSampleCount,
        'leftTurnCount': leftTurnCount,
        'rightTurnCount': rightTurnCount,
      };

  factory UserBehaviourProfile.fromMap(Map<dynamic, dynamic> map) => UserBehaviourProfile(
        averageWalkingSpeed: (map['averageWalkingSpeed'] as num?)?.toDouble() ?? 0.0,
        averageReactionTime: (map['averageReactionTime'] as num?)?.toDouble() ?? 0.0,
        preferredTurningDirection: map['preferredTurningDirection'] as String?,
        confidenceScore: (map['confidenceScore'] as num?)?.toDouble() ?? 0.5,
        successfulObstacleAvoidances: map['successfulObstacleAvoidances'] as int? ?? 0,
        nearMisses: map['nearMisses'] as int? ?? 0,
        frequentlyVisitedLocations: ((map['frequentlyVisitedLocations'] as List?) ?? [])
            .map((e) => VisitedLocation.fromMap(e as Map))
            .toList(),
        routeFamiliarityScore: (map['routeFamiliarityScore'] as num?)?.toDouble() ?? 0.0,
        totalNavigationSessions: map['totalNavigationSessions'] as int? ?? 0,
        totalWalkingDistanceMeters:
            (map['totalWalkingDistanceMeters'] as num?)?.toDouble() ?? 0.0,
        lastUpdated: map['lastUpdated'] != null
            ? DateTime.parse(map['lastUpdated'] as String)
            : DateTime.now(),
        speedSampleCount: map['speedSampleCount'] as int? ?? 0,
        reactionSampleCount: map['reactionSampleCount'] as int? ?? 0,
        leftTurnCount: map['leftTurnCount'] as int? ?? 0,
        rightTurnCount: map['rightTurnCount'] as int? ?? 0,
      );
}
