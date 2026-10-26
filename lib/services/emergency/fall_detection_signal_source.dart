import 'dart:async';
import 'dart:math' as math;

import 'package:sensors_plus/sensors_plus.dart';

import '../../models/emergency_event.dart';
import 'emergency_signal_source.dart';

/// REAL (not architecture-only) implementation of
/// [IEmergencySignalSource] using the device accelerometer.
///
/// ALGORITHM — a standard three-phase threshold-based fall detector,
/// the same general approach described in published fall-detection
/// literature (e.g. Kangas et al., "Comparison of low-complexity fall
/// detection algorithms for body attached accelerometers", 2008):
/// this class does not claim to invent the underlying signal-
/// processing technique, only to wire a working instance of it into
/// this app's existing pluggable [IEmergencySignalSource] contract —
/// the same swappable-backend pattern already used for hazard
/// detection, translation, and behavioural signals.
///
///  1. IMPACT — [userAccelerometerEvents] (gravity already excluded
///     by the platform) magnitude exceeds [impactThreshold], meters
///     per second squared. A normal footstep or phone jostle rarely
///     exceeds this; a fall's sudden deceleration against the ground
///     typically does.
///  2. POST-IMPACT STILLNESS — for [stillnessWindow] AFTER an impact,
///     magnitude must stay within [stillnessThreshold] of zero. This
///     is what distinguishes a fall from vigorous walking/running/
///     jumping: those also produce impact-level spikes, but are
///     followed by CONTINUED motion, not stillness. A fall is
///     followed by the phone (and presumably its user) not moving.
///  3. If both phases complete, a single
///     [EmergencyTriggerSignal] is emitted with
///     [EmergencyTriggerType.fallDetected].
///
/// KNOWN LIMITATIONS (documented honestly, matching this project's
/// existing style for every other heuristic):
///  - Thresholds are reasonable published starting points, not
///    calibrated against this app's own labeled fall/non-fall dataset
///    — that calibration is exactly the kind of field-validation work
///    described as still-needed elsewhere in this project's own
///    evaluation methodology.
///  - Phone placement/orientation (pocket vs. hand vs. bag) strongly
///    affects real-world accuracy; this implementation does not
///    attempt placement detection.
///  - This is a heuristic aid, not a certified medical fall-detection
///    device — it must never be presented to a user or reviewer as
///    clinically validated without an actual validation study.
class FallDetectionSignalSource implements IEmergencySignalSource {
  /// Magnitude (m/s²) of user-frame acceleration above which a sample
  /// is treated as a candidate impact. Published fall-detection
  /// studies commonly use thresholds in the 20-30 m/s² range for
  /// phone/waist-worn accelerometers; 24.0 is a mid-range starting
  /// point pending this project's own field calibration.
  final double impactThreshold;

  /// How long after a candidate impact to watch for stillness.
  final Duration stillnessWindow;

  /// Magnitude (m/s²) below which the device is considered "still"
  /// during the post-impact window.
  final double stillnessThreshold;

  /// Minimum time between two separate fall triggers, to avoid a
  /// single real fall (which can produce several impact-magnitude
  /// samples as the body settles) emitting multiple SOS countdowns
  /// back to back.
  final Duration cooldown;

  StreamSubscription<UserAccelerometerEvent>? _subscription;
  final _triggerController = StreamController<EmergencyTriggerSignal>.broadcast();

  DateTime? _impactCandidateAt;
  Timer? _stillnessCheckTimer;
  bool _stillnessViolatedDuringWindow = false;
  DateTime? _lastTriggerAt;

  FallDetectionSignalSource({
    this.impactThreshold = 24.0,
    this.stillnessWindow = const Duration(seconds: 2),
    this.stillnessThreshold = 3.0,
    this.cooldown = const Duration(seconds: 30),
  });

  @override
  String get name => 'accelerometer_fall_detector';

  @override
  Stream<EmergencyTriggerSignal> get triggers => _triggerController.stream;

  /// Starts listening. Safe to call multiple times (a second call is
  /// a no-op while already listening) — mirrors the defensive
  /// re-entrancy guards used elsewhere in this codebase (e.g.
  /// `_isProcessingFrame` in navigation_screen.dart).
  void startListening() {
    if (_subscription != null) return;
    _subscription = userAccelerometerEvents.listen(_onAccelerometerEvent, onError: (e) {
      // ignore: avoid_print
      print('FallDetectionSignalSource: sensor stream error (non-fatal): $e');
    });
  }

  void _onAccelerometerEvent(UserAccelerometerEvent event) {
    final magnitude = math.sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    final now = DateTime.now();

    if (_impactCandidateAt == null) {
      // Phase 1: watching for an impact.
      if (magnitude >= impactThreshold) {
        if (_lastTriggerAt != null && now.difference(_lastTriggerAt!) < cooldown) {
          return; // still in cooldown from a previous trigger
        }
        _impactCandidateAt = now;
        _stillnessViolatedDuringWindow = false;
        _stillnessCheckTimer?.cancel();
        _stillnessCheckTimer = Timer(stillnessWindow, _evaluateStillnessWindow);
      }
      return;
    }

    // Phase 2: within the post-impact stillness window — any sample
    // exceeding the stillness threshold means this was NOT a fall
    // (continued vigorous motion), so the window is marked violated.
    if (magnitude > stillnessThreshold) {
      _stillnessViolatedDuringWindow = true;
    }
  }

  void _evaluateStillnessWindow() {
    final wasStill = !_stillnessViolatedDuringWindow;
    _impactCandidateAt = null;
    _stillnessCheckTimer = null;

    if (wasStill) {
      _lastTriggerAt = DateTime.now();
      _triggerController.add(EmergencyTriggerSignal(
        type: EmergencyTriggerType.fallDetected,
        sourceDevice: name,
        metadata: const {
          'detectionMethod': 'accelerometer_impact_then_stillness',
        },
      ));
    }
  }

  @override
  void dispose() {
    _stillnessCheckTimer?.cancel();
    _subscription?.cancel();
    _triggerController.close();
  }
}
