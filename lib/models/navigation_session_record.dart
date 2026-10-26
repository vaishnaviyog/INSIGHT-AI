/// One completed (or ended-early) navigation session, used only to
/// compute the NAVIGATION metrics (Success Rate, Average Route
/// Completion Time, Route Deviations, Route Completion Percentage).
///
/// Recorded by NavigationMetricsTracker at the same start/end points
/// navigation_screen.dart already calls
/// EvaluationService.startSession()/endSession() and
/// BehaviourLearningService.startSession()/endSession() — this is an
/// additional, independent, read/write-only observer of the same
/// session lifecycle, not a change to it.
class NavigationSessionRecord {
  final String sessionId;
  final String destination;
  final DateTime startTime;
  final DateTime? endTime;

  /// True only if the exact OSRM "arrive" instruction was spoken
  /// during this session (see LocationService.arrivalInstruction) —
  /// i.e. the user actually reached the final destination step, not
  /// just that the session ended.
  final bool reachedDestination;

  final int totalSteps;
  final int stepsCompleted;

  /// Count of route-deviation signals observed during this session —
  /// see NavigationMetricsTracker.recordDeviation() call sites in
  /// navigation_screen.dart for the exact two conditions that
  /// increment this (an off-road relative-direction correction, or a
  /// "moving away from the road" trend message).
  final int deviationCount;

  const NavigationSessionRecord({
    required this.sessionId,
    required this.destination,
    required this.startTime,
    required this.totalSteps,
    required this.deviationCount,
    this.endTime,
    this.reachedDestination = false,
    this.stepsCompleted = 0,
  });

  NavigationSessionRecord copyWith({
    DateTime? endTime,
    bool? reachedDestination,
    int? totalSteps,
    int? stepsCompleted,
    int? deviationCount,
  }) =>
      NavigationSessionRecord(
        sessionId: sessionId,
        destination: destination,
        startTime: startTime,
        totalSteps: totalSteps ?? this.totalSteps,
        deviationCount: deviationCount ?? this.deviationCount,
        endTime: endTime ?? this.endTime,
        reachedDestination: reachedDestination ?? this.reachedDestination,
        stepsCompleted: stepsCompleted ?? this.stepsCompleted,
      );

  /// Session duration in seconds — null until the session has ended.
  double? get durationSeconds {
    if (endTime == null) return null;
    return endTime!.difference(startTime).inMilliseconds / 1000.0;
  }

  /// Percentage of route steps reached before the session ended,
  /// clamped to [0, 100]. 0 total steps (route never resolved) yields
  /// 0, not a division-by-zero error.
  double get completionPercentage {
    if (totalSteps <= 0) return 0.0;
    return ((stepsCompleted / totalSteps) * 100).clamp(0.0, 100.0);
  }

  Map<String, dynamic> toMap() => {
        'sessionId': sessionId,
        'destination': destination,
        'startTime': startTime.toIso8601String(),
        'endTime': endTime?.toIso8601String(),
        'reachedDestination': reachedDestination,
        'totalSteps': totalSteps,
        'stepsCompleted': stepsCompleted,
        'deviationCount': deviationCount,
      };

  factory NavigationSessionRecord.fromMap(Map<dynamic, dynamic> map) => NavigationSessionRecord(
        sessionId: map['sessionId'] as String,
        destination: map['destination'] as String? ?? '',
        startTime: DateTime.parse(map['startTime'] as String),
        endTime: map['endTime'] != null ? DateTime.parse(map['endTime'] as String) : null,
        reachedDestination: map['reachedDestination'] as bool? ?? false,
        totalSteps: map['totalSteps'] as int? ?? 0,
        stepsCompleted: map['stepsCompleted'] as int? ?? 0,
        deviationCount: map['deviationCount'] as int? ?? 0,
      );
}
