import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/user_behaviour_profile.dart';
import 'behaviour/behaviour_event.dart';
import 'behaviour/behaviour_signal_source.dart';

/// Continuously records and updates the user's [UserBehaviourProfile]
/// during navigation.
///
/// MILESTONE 2 SCOPE: this service COLLECTS DATA ONLY. It never makes
/// a navigation decision, never changes what's spoken or displayed,
/// and contains no machine learning — every update below is a simple,
/// documented arithmetic rule (running averages, counters, a small
/// heuristic score). Turning this data into predictions or guidance
/// changes is explicitly deferred to later milestones (Risk
/// Prediction Engine, Adaptive Voice Guidance).
///
/// MODULARITY: `navigation_screen.dart` feeds this service through
/// the plain `recordX()` methods below, since GPS/compass/hazard
/// events already originate inside that screen today. Anything
/// external — a future IMU, Time-of-Flight, or ultrasonic sensor
/// module — can contribute the exact same kinds of data WITHOUT this
/// class changing, by implementing [IBehaviourSignalSource] and
/// calling [addSignalSource]. Both paths converge on the same
/// private [_applyEvent] pipeline, so there is exactly one place
/// where profile fields are actually updated.
class BehaviourLearningService {
  static const String _boxName = 'behaviour_profile_box';
  static const String _profileKey = 'profile';

  /// Decimal places used to bucket GPS coordinates into "places" for
  /// [UserBehaviourProfile.frequentlyVisitedLocations] and the route
  /// familiarity heuristic. 4 decimal places is roughly 11 meters at
  /// the equator — coarse enough to group nearby samples together,
  /// fine enough to keep separate junctions/buildings distinct.
  static const int locationGridPrecision = 4;

  /// Minimum time between two persisted writes to Hive during
  /// continuous GPS updates, to avoid excessive disk I/O. Obstacle,
  /// turn, and session events always persist immediately regardless
  /// of this throttle, since they're comparatively rare.
  static const Duration _minPersistInterval = Duration(seconds: 10);

  /// GPS samples further apart than this (meters) in a single update
  /// are treated as a location glitch and excluded from distance/
  /// speed accumulation, rather than corrupting the running totals.
  static const double _maxPlausibleJumpMeters = 100.0;

  /// Reaction-time samples longer than this (seconds) are treated as
  /// "the user did something else entirely", not a genuine reaction,
  /// and excluded from the running average.
  static const double _maxPlausibleReactionSeconds = 30.0;

  late final Box _box;
  late UserBehaviourProfile _profile;
  bool _initialized = false;

  /// Count of every [_applyEvent] invocation (session start/end,
  /// position sample, obstacle warning/cleared, turn) since this
  /// service was constructed. Added purely for the evaluation
  /// metrics export's "Behaviour Profile Updates" figure — read-only,
  /// does not affect any existing collection logic.
  int _profileUpdateCount = 0;
  int get profileUpdateCount => _profileUpdateCount;

  double? _lastLatitude;
  double? _lastLongitude;
  DateTime? _lastPositionTimestamp;

  DateTime? _pendingWarningTime;
  DateTime _lastPersist = DateTime.now().subtract(_minPersistInterval);

  // Session-scoped bookkeeping for the route-familiarity heuristic.
  Set<String> _knownLocationKeysAtSessionStart = {};
  int _sessionSampleCount = 0;
  int _sessionKnownLocationHits = 0;

  final List<StreamSubscription<BehaviourEvent>> _sourceSubscriptions = [];

  /// Read-only snapshot of the current profile. Intended for a future
  /// consumer (e.g. the Risk Prediction Engine, or a debug screen) —
  /// nothing in this milestone reads it yet.
  /// Read-only status, added for the developer debug dashboard's
  /// "current Hive status" display. Not used by any business logic.
  bool get isPersistenceReady => _initialized;
  String get hiveBoxName => _boxName;

  /// Read-only snapshot of the current profile. Nullable specifically
  /// so consumers that might read it before [initialize] has
  /// completed (e.g. the developer debug dashboard, which polls on a
  /// timer independent of this service's own lifecycle) get `null`
  /// instead of a LateInitializationError.
  UserBehaviourProfile? get profile => _initialized ? _profile : null;

  /// Whether the Hive box backing this profile is currently open.
  /// Added for the developer debug dashboard's "Hive status" display
  /// — not used anywhere in the collection logic itself.
  bool get isHiveOpen => _initialized && _box.isOpen;

  /// Loads the persisted profile (or creates a fresh one). Must be
  /// awaited once, before any `recordX()` call.
  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    final stored = _box.get(_profileKey);
    _profile = stored != null
        ? UserBehaviourProfile.fromMap(Map<dynamic, dynamic>.from(stored as Map))
        : UserBehaviourProfile.initial();
    _initialized = true;
  }

  /// Registers a future external signal source. Its events are routed
  /// through the exact same [_applyEvent] pipeline as the direct
  /// `recordX()` calls, so a future sensor module needs no special
  /// handling here.
  void addSignalSource(IBehaviourSignalSource source) {
    _sourceSubscriptions.add(source.events.listen(_applyEvent));
  }

  // ---------------------------------------------------------------
  // Direct recording API — called today from navigation_screen.dart.
  // ---------------------------------------------------------------

  void startSession() => _applyEvent(NavigationSessionStartedEvent());

  void endSession() => _applyEvent(NavigationSessionEndedEvent());

  void recordPositionSample({
    required double latitude,
    required double longitude,
    double? speedMetersPerSecond,
    DateTime? timestamp,
  }) =>
      _applyEvent(PositionSampleEvent(
        latitude: latitude,
        longitude: longitude,
        speedMetersPerSecond: speedMetersPerSecond,
        timestamp: timestamp,
      ));

  /// AUDIT ADD (patent-strengthening pass — Core B test-coverage gap):
  /// [timestamp] mirrors the same optional-override parameter
  /// [recordPositionSample] already had — without it, the
  /// reaction-time arithmetic in [_onObstacleWarningIssued]/
  /// [_onObstacleCleared] (the actual novel, patent-relevant behavior
  /// this service exists for) could only be tested by waiting out REAL
  /// wall-clock delays, which is both slow and imprecise for verifying
  /// an exact running-average formula. Defaults to `null` (falls back
  /// to `DateTime.now()`, unchanged runtime behavior) — this is purely
  /// additive for testability and future signal sources that may
  /// report a historical/buffered event with its own accurate
  /// timestamp (see [IBehaviourSignalSource]).
  void recordObstacleWarningIssued(String hazardLabel, String distanceBand, {DateTime? timestamp}) =>
      _applyEvent(ObstacleWarningIssuedEvent(
        hazardLabel: hazardLabel,
        distanceBand: distanceBand,
        timestamp: timestamp,
      ));

  void recordObstacleCleared({DateTime? timestamp}) => _applyEvent(ObstacleClearedEvent(timestamp: timestamp));

  void recordTurn(String direction) =>
      _applyEvent(TurnTakenEvent(direction: direction));

  /// Seeds the profile with onboarding-provided starting values.
  /// Called AT MOST ONCE per onboarding/edit-profile completion —
  /// this is a stated PREFERENCE used as a reasonable prior, not a
  /// behavioural OBSERVATION, so it deliberately bypasses
  /// [_applyEvent] rather than fabricating a fake position/warning
  /// event just to get data into the profile.
  ///
  /// SAFE TO CALL REPEATEDLY (e.g. if the user revisits Settings):
  /// [preferredWalkingSpeedMetersPerSecond] only overwrites
  /// [UserBehaviourProfile.averageWalkingSpeed] while
  /// `speedSampleCount == 0` — i.e. before any real GPS-derived sample
  /// has ever contributed to it — so a returning user's genuine
  /// accumulated history can never be clobbered by a re-run of
  /// onboarding. [initialFrequentPlaces] is always additive/merged by
  /// grid cell (matching visit counts are summed), never a wholesale
  /// replacement of [UserBehaviourProfile.frequentlyVisitedLocations].
  void seedFromOnboarding({
    double? preferredWalkingSpeedMetersPerSecond,
    List<VisitedLocation> initialFrequentPlaces = const [],
  }) {
    if (!_initialized) return;

    if (preferredWalkingSpeedMetersPerSecond != null && _profile.speedSampleCount == 0) {
      _profile.averageWalkingSpeed = preferredWalkingSpeedMetersPerSecond;
      // Counted as a single low-weight sample so the very next real
      // GPS-derived sample already blends with it through the
      // existing _runningAverage formula, rather than needing a
      // special case elsewhere.
      _profile.speedSampleCount = 1;
    }

    for (final place in initialFrequentPlaces) {
      final key = _gridKeyFor(place);
      final existingIndex =
          _profile.frequentlyVisitedLocations.indexWhere((l) => _gridKeyFor(l) == key);
      if (existingIndex >= 0) {
        _profile.frequentlyVisitedLocations[existingIndex].visitCount += place.visitCount;
        _profile.frequentlyVisitedLocations[existingIndex].lastVisited = place.lastVisited;
      } else {
        _profile.frequentlyVisitedLocations.add(place);
      }
    }

    _profile.lastUpdated = DateTime.now();
    _persist(force: true);
  }

  // ---------------------------------------------------------------
  // Central update pipeline — the ONLY place profile fields change
  // from OBSERVED (as opposed to stated-preference) events.
  // ---------------------------------------------------------------

  void _applyEvent(BehaviourEvent event) {
    if (!_initialized) return; // fail-soft: telemetry must never crash navigation
    _profileUpdateCount++;

    if (event is NavigationSessionStartedEvent) {
      _onSessionStarted();
    } else if (event is NavigationSessionEndedEvent) {
      _onSessionEnded();
    } else if (event is PositionSampleEvent) {
      _onPositionSample(event);
    } else if (event is ObstacleWarningIssuedEvent) {
      _onObstacleWarningIssued(event);
    } else if (event is ObstacleClearedEvent) {
      _onObstacleCleared(event);
    } else if (event is TurnTakenEvent) {
      _onTurnTaken(event);
    }

    _profile.lastUpdated = DateTime.now();
  }

  void _onSessionStarted() {
    _profile.totalNavigationSessions++;
    _knownLocationKeysAtSessionStart =
        _profile.frequentlyVisitedLocations.map(_gridKeyFor).toSet();
    _sessionSampleCount = 0;
    _sessionKnownLocationHits = 0;
    _lastLatitude = null;
    _lastLongitude = null;
    _lastPositionTimestamp = null;
    _persist();
  }

  void _onSessionEnded() {
    if (_sessionSampleCount > 0) {
      final sessionFamiliarity = _sessionKnownLocationHits / _sessionSampleCount;
      // Simple weighted blend with the existing score. This is a
      // smoothing heuristic, not a learned model — it exists so one
      // short/unusual session doesn't wildly swing the value.
      _profile.routeFamiliarityScore =
          (_profile.routeFamiliarityScore * 0.7) + (sessionFamiliarity * 0.3);
    }
    _persist(force: true);
  }

  void _onPositionSample(PositionSampleEvent event) {
    _updateWalkingSpeed(event);
    _updateDistanceAndVisitedLocations(event);

    _lastLatitude = event.latitude;
    _lastLongitude = event.longitude;
    _lastPositionTimestamp = event.timestamp;

    _persist();
  }

  void _updateWalkingSpeed(PositionSampleEvent event) {
    double? speed = event.speedMetersPerSecond;

    if (speed == null &&
        _lastLatitude != null &&
        _lastLongitude != null &&
        _lastPositionTimestamp != null) {
      final distance = Geolocator.distanceBetween(
        _lastLatitude!,
        _lastLongitude!,
        event.latitude,
        event.longitude,
      );
      final seconds =
          event.timestamp.difference(_lastPositionTimestamp!).inMilliseconds / 1000.0;
      if (seconds > 0) speed = distance / seconds;
    }

    // Sanity bound (~36 km/h) filters GPS jumps rather than letting
    // them pollute the running average.
    if (speed != null && speed >= 0 && speed < 10.0) {
      _profile.averageWalkingSpeed =
          _runningAverage(_profile.averageWalkingSpeed, _profile.speedSampleCount, speed);
      _profile.speedSampleCount++;
    }
  }

  void _updateDistanceAndVisitedLocations(PositionSampleEvent event) {
    if (_lastLatitude != null && _lastLongitude != null) {
      final distance = Geolocator.distanceBetween(
        _lastLatitude!,
        _lastLongitude!,
        event.latitude,
        event.longitude,
      );
      if (distance < _maxPlausibleJumpMeters) {
        _profile.totalWalkingDistanceMeters += distance;
      }
    }

    final key = _gridKeyForCoords(event.latitude, event.longitude);
    _sessionSampleCount++;
    if (_knownLocationKeysAtSessionStart.contains(key)) {
      _sessionKnownLocationHits++;
    }

    final existingIndex =
        _profile.frequentlyVisitedLocations.indexWhere((l) => _gridKeyFor(l) == key);
    if (existingIndex >= 0) {
      _profile.frequentlyVisitedLocations[existingIndex].visitCount++;
      _profile.frequentlyVisitedLocations[existingIndex].lastVisited = event.timestamp;
    } else {
      _profile.frequentlyVisitedLocations.add(VisitedLocation(
        latitude: event.latitude,
        longitude: event.longitude,
        visitCount: 1,
        lastVisited: event.timestamp,
      ));
    }
  }

  void _onObstacleWarningIssued(ObstacleWarningIssuedEvent event) {
    _pendingWarningTime = event.timestamp;

    // A warning issued while the hazard was already very close is
    // logged as a near miss immediately, regardless of what happens
    // next. This is a documented heuristic proxy (see
    // ObstacleClearedEvent's doc comment) — not a verified collision
    // outcome, since the app has no sensor that can confirm one. A
    // real proximity sensor could replace this in a future milestone.
    if (event.distanceBand == 'veryNear') {
      _profile.nearMisses++;
    }
    _persist();
  }

  void _onObstacleCleared(ObstacleClearedEvent event) {
    if (_pendingWarningTime == null) return; // nothing to correlate with

    // P0-5: local variable named for what it actually measures
    // (warning-to-clearance latency), even though the persisted field
    // it feeds (UserBehaviourProfile.averageReactionTime) keeps its
    // name for Hive compatibility — see that field's doc comment.
    final clearanceLatencySeconds =
        event.timestamp.difference(_pendingWarningTime!).inMilliseconds / 1000.0;

    if (clearanceLatencySeconds > 0 && clearanceLatencySeconds < _maxPlausibleReactionSeconds) {
      _profile.averageReactionTime = _runningAverage(
        _profile.averageReactionTime,
        _profile.reactionSampleCount,
        clearanceLatencySeconds,
      );
      _profile.reactionSampleCount++;
      _profile.successfulObstacleAvoidances++;

      // Simple, explicitly non-ML confidence heuristic: small reward
      // per successful avoidance, clamped to [0, 1]. Near misses are
      // not separately penalized here (they already lower confidence
      // implicitly by not contributing a reward) — a real scoring
      // model is future work, not this milestone.
      _profile.confidenceScore = (_profile.confidenceScore + 0.02).clamp(0.0, 1.0);
    }

    _pendingWarningTime = null;
    _persist();
  }

  void _onTurnTaken(TurnTakenEvent event) {
    if (event.direction == 'left') {
      _profile.leftTurnCount++;
    } else if (event.direction == 'right') {
      _profile.rightTurnCount++;
    }

    if (_profile.leftTurnCount != _profile.rightTurnCount) {
      _profile.preferredTurningDirection =
          _profile.leftTurnCount > _profile.rightTurnCount ? 'left' : 'right';
    }
    _persist();
  }

  double _runningAverage(double currentAverage, int sampleCount, double newValue) {
    return ((currentAverage * sampleCount) + newValue) / (sampleCount + 1);
  }

  String _gridKeyFor(VisitedLocation l) => _gridKeyForCoords(l.latitude, l.longitude);

  String _gridKeyForCoords(double lat, double lng) {
    return '${lat.toStringAsFixed(locationGridPrecision)},'
        '${lng.toStringAsFixed(locationGridPrecision)}';
  }

  /// AUDIT FIX (P0-7): now returns the `Future` from `_box.put(...)`
  /// instead of discarding it. Existing call sites throughout this
  /// file that call `_persist();` without awaiting it are UNCHANGED —
  /// that's still the correct fire-and-forget runtime behavior this
  /// method is meant to have during normal operation (frequent,
  /// debounced, must never block the caller). The only call site that
  /// now actually needs the returned Future is [dispose] below.
  Future<void> _persist({bool force = false}) async {
    // AUDIT FIX (live on-device bug, Oct 2026): the existing [_disposed]
    // guard only stopped a SECOND dispose() call from re-touching a
    // closed box — it did nothing for a DIFFERENT caller still holding
    // this same service instance (e.g. ProfileSettingsScreen receiving
    // it via constructor) invoking a public method like
    // [seedFromOnboarding] AFTER whichever screen owns this instance's
    // lifecycle has already disposed it. That path reached `_box.put`
    // against an already-closed box and threw `HiveError: Box has
    // already been closed.` on every keystroke of a place-name field,
    // confirmed via a real device log. `_initialized` alone never
    // catches this because it's set once in [initialize] and never
    // reset — [_disposed] is the actual signal that must gate every
    // write, not just re-entrant dispose() calls.
    if (!_initialized || _disposed) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastPersist) < _minPersistInterval) return;
    _lastPersist = now;
    await _box.put(_profileKey, _profile.toMap());
  }

  /// Releases the Hive box and any registered signal-source
  /// subscriptions. Must be called from the owning widget's
  /// `dispose()`.
  ///
  /// AUDIT FIX (P0-7): the final `_persist(force: true)` call is now
  /// awaited BEFORE `_box.close()` runs. Previously it was fire-and-
  /// forget (matching every other runtime call site's usual pattern —
  /// see `_persist`'s doc comment for why that's correct everywhere
  /// ELSE), which meant `_box.close()` could run while that last write
  /// was still in flight, risking the final profile state never
  /// actually reaching disk.
  /// AUDIT FIX (patent-strengthening pass — Core B test-coverage gap):
  /// [_disposed] guard added after a NEW test in
  /// `behaviour_learning_service_test.dart` caught a real bug: calling
  /// [dispose] a second time (e.g. a genuine double-dispose from a
  /// widget's own lifecycle, or — as the test that found this
  /// exercised — a fresh instance reopening the same underlying box)
  /// re-ran `_persist(force: true)` against an ALREADY-closed
  /// `_box.close()` from the first call, throwing `HiveError: Box has
  /// already been closed.` This is the same class of bug already found
  /// and fixed in `NavigationSessionPersistenceService.dispose()`
  /// earlier this project — the fix is the same shape: make the second
  /// call a genuine no-op instead of re-touching a closed box.
  bool _disposed = false;

  Future<void> dispose() async {
    if (_disposed) return;
    // AUDIT FIX (regression from the `_persist` guard fix above, caught
    // by this project's own test suite): `_disposed` must NOT be set
    // true until AFTER the final `_persist(force: true)` call below —
    // `_persist` now correctly refuses to write once `_disposed` is
    // true (that's the whole point of the fix above), so setting the
    // flag first made dispose()'s own final flush silently no-op,
    // discarding whatever hadn't hit the 400ms debounce yet. The
    // re-entrancy guard (`if (_disposed) return;` above) still makes a
    // SECOND dispose() call a no-op exactly as before — only the
    // ORDER within this first call changes.
    for (final sub in _sourceSubscriptions) {
      await sub.cancel();
    }
    if (_initialized) {
      await _persist(force: true);
      await _box.close();
    }
    _disposed = true;
  }
}
