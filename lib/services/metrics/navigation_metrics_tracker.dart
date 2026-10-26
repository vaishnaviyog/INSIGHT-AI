import 'package:hive_flutter/hive_flutter.dart';

import '../../models/navigation_session_record.dart';

/// Persists one [NavigationSessionRecord] per navigation session,
/// following the same plain-Hive-box pattern already used by
/// EvaluationService/BehaviourLearningService/EmergencyService.
///
/// SCOPE BOUNDARY: purely observational, like EvaluationService — it
/// never influences routing, speech, or any other navigation
/// decision. `navigation_screen.dart` calls [startSession],
/// [recordDeviation], [recordArrival], and [endSession] at the same
/// points it already calls the other services' session lifecycle
/// methods.
class NavigationMetricsTracker {
  static const String _boxName = 'navigation_sessions_box';

  late Box _box;
  bool _initialized = false;

  NavigationSessionRecord? _pendingSession;

  bool get isInitialized => _initialized;
  NavigationSessionRecord? get pendingSession => _pendingSession;

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    _initialized = true;
  }

  void startSession({
    required String sessionId,
    required String destination,
    required int totalSteps,
  }) {
    if (!_initialized) return;
    _pendingSession = NavigationSessionRecord(
      sessionId: sessionId,
      destination: destination,
      startTime: DateTime.now(),
      totalSteps: totalSteps,
      deviationCount: 0,
    );
  }

  /// Called whenever the on-screen guidance already flags the user as
  /// off the computed route or moving away from it (see the two call
  /// sites in navigation_screen.dart's compass-heading listener and
  /// position-stream listener) — this only counts the event that's
  /// already happening, it doesn't change what's spoken.
  void recordDeviation() {
    if (_pendingSession == null) return;
    _pendingSession =
        _pendingSession!.copyWith(deviationCount: _pendingSession!.deviationCount + 1);
  }

  /// Called when the exact OSRM "arrive" instruction is spoken —
  /// see LocationService.arrivalInstruction.
  void recordArrival() {
    if (_pendingSession == null) return;
    _pendingSession = _pendingSession!.copyWith(reachedDestination: true);
  }

  Future<void> endSession({
    required int stepsCompleted,
  }) async {
    if (!_initialized || _pendingSession == null) return;
    final finished = _pendingSession!.copyWith(
      endTime: DateTime.now(),
      stepsCompleted: stepsCompleted,
    );
    await _box.put(finished.sessionId, finished.toMap());
    _pendingSession = null;
  }

  /// All persisted sessions, oldest first.
  List<NavigationSessionRecord> get allSessions {
    if (!_initialized) return [];
    final sessions = _box.values
        .map((v) => NavigationSessionRecord.fromMap(Map<dynamic, dynamic>.from(v as Map)))
        .toList();
    sessions.sort((a, b) => a.startTime.compareTo(b.startTime));
    return sessions;
  }

  Future<void> dispose() async {
    if (_pendingSession != null) {
      final finished = _pendingSession!.copyWith(endTime: DateTime.now());
      await _box.put(finished.sessionId, finished.toMap());
      _pendingSession = null;
    }
    if (_initialized) {
      await _box.close();
    }
  }
}
