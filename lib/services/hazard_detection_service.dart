import 'package:camera/camera.dart';

import '../config/research_tools_config.dart';
import '../models/detected_hazard.dart';
import 'hazard_detectors/collision_time_estimator.dart';
import 'hazard_detectors/hazard_detector.dart';
import 'hazard_detectors/yolo_tflite_hazard_detector.dart';
import 'hazard_temporal_filter.dart';

/// Orchestrates hazard detection and returns a single, prioritized,
/// temporally-confirmed list of hazards for the current camera frame.
///
/// THIS IS THE ONLY HAZARD-DETECTION CLASS THE REST OF THE APP SHOULD
/// EVER IMPORT. `navigation_screen.dart` (and, in a later research
/// milestone, the Risk Prediction Engine) talks only to this class,
/// through plain [DetectedHazard] objects — it never references the
/// active detection backend directly. That knowledge is fully
/// contained in the `hazard_detectors/` folder.
///
/// AUDIT UPDATE (YOLOv8n migration): the default backend is now
/// [YoloTfliteHazardDetector], replacing the earlier COCO SSD
/// MobileNet detector. That detector class (`CocoTfliteHazardDetector`)
/// and its exclusive `coco_label_config.dart` have been DELETED
/// entirely — confirmed unreferenced by any functional import
/// anywhere else in the app before removal (the benchmark harness's
/// still-valid "SSD MobileNet V1" baseline candidate in
/// `BenchmarkModelSpec`/`ModelBenchmarkService` has its own
/// self-contained decode logic and never imported this class).
/// Recover it from version control if ever needed. This swap is a
/// one-line change BY DESIGN — see [IHazardDetector]'s doc comment on
/// why swapping backends should never require touching anything above
/// this class.
///
/// *** CRITICAL OPERATIONAL NOTE ***
/// `YoloTfliteHazardDetector` requires a bundled model file
/// (`assets/ml_models/yolov8n.tflite` + `yolov8n_labels.txt`) that is
/// NOT present in this repository — see `assets/ml_models/README.md`.
/// THERE IS NO FALLBACK: until that file is added, this service will
/// detect nothing at all. See `YoloTfliteHazardDetector.health` for
/// exactly which self-test step is failing.
///
/// TO SWAP OR ADD A DETECTOR AGAIN LATER: implement [IHazardDetector]
/// in a new file under `hazard_detectors/`, then add/replace it in the
/// list passed to this class's constructor. No other file in the app
/// needs to change.
class HazardDetectionService {
  /// TEMPORARY DIAGNOSTIC FLAG (GTFS-vs-YOLO CPU-contention
  /// investigation) — NOT a permanent feature. When `true`,
  /// [initialize] and [detectHazards] both short-circuit immediately
  /// (no model load attempt, no per-frame conversion/inference work at
  /// all) so a real-device run can isolate whether the continuously-
  /// retrying TFLite "Node number 0 (PAD) failed to prepare" loop is
  /// competing for CPU/isolate time with GTFS initialization. Does not
  /// touch [YoloTfliteHazardDetector] itself — the detector
  /// implementation is completely unchanged. REVERTED to `false` after
  /// the isolation run (RAPTOR alone measured ~57s on-device even with
  /// this `true` — see the metro-data-restoration investigation's
  /// diagnostic report) — YOLO is back on for normal use.
  static const bool kDiagnosticDisableDetection = false;

  final List<IHazardDetector> _detectors;
  bool _isBusy = false;

  /// Minimum time between two consecutive detection runs, regardless
  /// of which detector(s) are active. This throttle intentionally
  /// lives here — not inside individual detectors — so it applies
  /// uniformly no matter which backend is swapped in later.
  static const Duration _minInterval = Duration(milliseconds: 300);
  DateTime _lastRun = DateTime.now().subtract(_minInterval);

  /// Milestone requirement: an object must appear in at least 3
  /// consecutive detection runs before it's confirmed/announced — see
  /// [HazardTemporalFilter]'s own doc comment for exactly what
  /// "consecutive" means here (detection RUNS, spaced by at least
  /// [_minInterval], not raw camera frames).
  final HazardTemporalFilter _temporalFilter;

  /// AUDIT ADD (Phase 3/4 — Time-to-Collision): same lifecycle as
  /// [_temporalFilter] — a long-lived, by-label tracker owned here,
  /// fed only CONFIRMED hazards (see [CollisionTimeEstimator]'s doc
  /// comment for why raw per-frame detections would be noisier).
  final CollisionTimeEstimator _collisionTimeEstimator;

  /// The most recent RAW (confidence + allowlist filtered, but NOT
  /// yet temporally confirmed) detections — exposed read-only,
  /// separately from [detectHazards]'s temporally-confirmed return
  /// value, purely so the bounding-box overlay
  /// (`ui/hazard_box_painter.dart`) can show every real-time detection
  /// visually as immediate feedback, while voice/risk/evaluation logic
  /// downstream still only ever acts on confirmed hazards. Painting
  /// unconfirmed boxes is harmless (it's a sighted-developer/demo
  /// visual aid, not a safety-relevant decision) and much more useful
  /// for verifying the detector is actually working than waiting for
  /// 3-frame confirmation to show anything on screen.
  List<DetectedHazard> _lastRawDetections = [];
  List<DetectedHazard> get lastRawDetections => _lastRawDetections;

  /// [detectors] defaults to YOLOv8n-only (see class doc comment for
  /// why). A custom list can still be supplied (e.g. in tests).
  HazardDetectionService({List<IHazardDetector>? detectors, HazardTemporalFilter? temporalFilter, CollisionTimeEstimator? collisionTimeEstimator})
      : _detectors = detectors ?? [YoloTfliteHazardDetector()],
        _temporalFilter = temporalFilter ?? HazardTemporalFilter(),
        _collisionTimeEstimator = collisionTimeEstimator ?? CollisionTimeEstimator();

  /// Initializes every configured detector. Must be awaited once,
  /// during app/screen startup, before [detectHazards] is called.
  Future<void> initialize() async {
    if (kDiagnosticDisableDetection) {
      // ignore: avoid_print
      print('[GTFS-DIAG] HazardDetectionService.initialize() SKIPPED (kDiagnosticDisableDetection=true)');
      return;
    }
    for (final detector in _detectors) {
      await detector.initialize();
    }
  }

  /// Runs detection on a single camera frame, trying each configured
  /// detector in order until one returns results (or all return
  /// none), then applies the temporal confirmation filter. Returns an
  /// empty list if nothing relevant was found/confirmed, if called
  /// again too soon after the previous run, or if a previous call is
  /// still in progress.
  Future<List<DetectedHazard>> detectHazards(
    CameraImage image,
    int sensorOrientation,
  ) async {
    if (kDiagnosticDisableDetection) return [];
    if (_isBusy) {
      // PHASE C4 TEMPORARY DIAGNOSTIC (fresh device latency/dropped-
      // frame measurement — additive only): a frame dropped because the
      // previous detection run hasn't finished yet.
      logLatency('DROPPED_BUSY=${DateTime.now().toIso8601String()}');
      return [];
    }

    final now = DateTime.now();
    if (now.difference(_lastRun) < _minInterval) {
      logLatency('DROPPED_THROTTLE=${DateTime.now().toIso8601String()}');
      return [];
    }

    _isBusy = true;
    _lastRun = now;

    try {
      for (final detector in _detectors) {
        final results = await detector.detect(image, sensorOrientation);
        if (results.isNotEmpty) {
          _lastRawDetections = results;
          final confirmed = _temporalFilter.confirm(results);
          if (confirmed.isNotEmpty) {
            // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T5 =
            // temporal filter accepts detection. Safe to remove after
            // this phase.
            logLatency('T5_temporalFilterAccept=${DateTime.now().toIso8601String()} labels=${confirmed.map((h) => h.label).toList()}');
          }
          final annotated = _collisionTimeEstimator.annotate(confirmed);
          // PHASE C4 TEMPORARY DIAGNOSTIC: T6 = full per-frame pipeline
          // (detector + temporal filter + TTC) complete — printed for
          // EVERY processed frame, confirmed or not, so camera-frame ->
          // hazard-decision total latency can be measured regardless of
          // whether this particular frame produced a confirmed hazard.
          logLatency('T6_pipelineComplete=${DateTime.now().toIso8601String()} confirmedCount=${annotated.length}');
          return annotated;
        }
      }
      // Nothing detected this frame at all — still feed an empty list
      // through the temporal filter so every tracked label's streak
      // resets (see HazardTemporalFilter.confirm), not just the ones
      // that got explicitly overwritten above.
      _lastRawDetections = [];
      final annotated = _collisionTimeEstimator.annotate(_temporalFilter.confirm(const []));
      logLatency('T6_pipelineComplete=${DateTime.now().toIso8601String()} confirmedCount=${annotated.length}');
      return annotated;
    } catch (e) {
      // AUDIT ADD (Phase E10 — failure-handling audit): each
      // configured `IHazardDetector.detect()` already catches its own
      // exceptions internally and returns `[]` (verified in
      // YoloTfliteHazardDetector — this loop's `detect()` call was
      // never actually the uncaught path). The real, narrower gap this
      // closes: `_temporalFilter.confirm()`/
      // `_collisionTimeEstimator.annotate()` run OUTSIDE any detector's
      // own try/catch — an exception from either of those (or from a
      // future detector implementation that doesn't catch as carefully
      // as YOLO's does) previously propagated straight out of this
      // method, uncaught, into `NavigationScreen._processCameraImage`
      // (which also has no `catch` around this call — see that file's
      // Phase E10 notes) and was silently swallowed by Dart's default
      // zone error handler: the frame's hazard state was lost with no
      // diagnostic and no recovery. Recovering here means treating a
      // failed frame the same as "nothing detected this frame" —
      // exactly what a naturally quiet frame already looks like to
      // every caller — rather than crashing or hanging frame
      // processing. Not logged via a warning/speech path: a single
      // transient failure recovering silently (from the RIDER's
      // perspective — this print is still visible in logs) is correct
      // here; see HazardDetectorHealth/detectorAvailability for the
      // separate, existing mechanism that surfaces a SUSTAINED
      // detector outage rather than one bad frame.
      // ignore: avoid_print
      print('HazardDetectionService.detectHazards: unexpected error, treating frame as no-detection: $e');
      return const [];
    } finally {
      _isBusy = false;
    }
  }

  /// Snapshot of which configured backends are actually ready right
  /// now (see [IHazardDetector.isAvailable]). Read-only, no side
  /// effects — safe for the debug dashboard to poll. Does not affect
  /// [detectHazards]'s try-in-order behavior at all.
  Map<String, bool> get detectorAvailability => {
        for (final detector in _detectors) detector.name: detector.isAvailable,
      };

  /// AUDIT ADD (transit camera handoff — production integration):
  /// resets ONLY the temporal-filter/TTC state, WITHOUT disposing the
  /// loaded detector/model — for exactly the "camera paused during a
  /// transit leg, then resumed for final walking" case, where the
  /// TFLite interpreter should stay loaded (reloading a model is slow
  /// and unnecessary) but any hazard streak/distance history from
  /// before the pause must not silently carry into fresh detection
  /// after it. See `TransitEvent.resetDetectionState`'s doc comment —
  /// this is the production method that event maps to.
  void resetTemporalState() {
    _temporalFilter.reset();
    _collisionTimeEstimator.reset();
  }

  /// Releases resources for every configured detector. Must be called
  /// from the owning widget's `dispose()`.
  void dispose() {
    for (final detector in _detectors) {
      detector.dispose();
    }
    _temporalFilter.reset();
    _collisionTimeEstimator.reset();
  }
}
