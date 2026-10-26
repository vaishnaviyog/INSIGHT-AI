import '../../models/detected_hazard.dart';

/// Monocular distance estimation, shared by every hazard detector
/// (currently [YoloTfliteHazardDetector] — see that class for how it
/// converts ITS OWN model input resolution into this file's 300px
/// calibration reference space before calling this), replacing the
/// previous area-fraction-only heuristic.
///
/// FORMULA: `distance = (knownObjectHeightMeters * focalLengthPixels)
/// / boundingBoxHeightPixels` — the standard pinhole-camera monocular
/// distance estimate. It assumes the object is roughly upright and
/// fully visible in the box, and is only as good as
/// [focalLengthPixels] and [knownObjectHeightsMeters] below.
///
/// HONEST LIMITATION, STATED PLAINLY (not just in a code comment —
/// see [isCalibrated] and every caller's obligation to treat this
/// accordingly): a single monocular camera cannot measure true depth.
/// This is the strongest PRACTICAL approximation available without
/// stereo/LiDAR hardware, not a substitute for one. Output should
/// always be presented to the user as approximate (see
/// `AdaptiveGuidanceService`'s "Approximately X meters" phrasing,
/// which already does this correctly) and used internally only for
/// coarse prioritization (`distanceBandForMeters`), never for a
/// precision-dependent decision.
///
/// CALIBRATING [focalLengthPixels]: this project has no calibration
/// measurement on file — [focalLengthPixels]'s current value is an
/// UNCALIBRATED order-of-magnitude default (see [isCalibrated]), not
/// a measured constant. [calibrateFocalLengthPixels] below is a real,
/// runnable implementation of the calibration procedure — not just
/// prose instructions — so that running it on the actual target
/// device only requires ONE measurement, not deriving the formula by
/// hand:
///   1. Place an object of known height at a known distance from the
///      device's camera.
///   2. Run it through the SAME detection pipeline
///      (currently [YoloTfliteHazardDetector]) and note the reported
///      bounding box height CONVERTED to this file's 300px
///      calibration reference space (NOT raw camera resolution, and
///      NOT necessarily the detector's own native model input size —
///      see [focalLengthPixels]'s doc comment below for why 300 stays
///      the reference regardless of which detector is active).
///   3. Call `calibrateFocalLengthPixels(knownObjectHeightMeters: ...,
///      distanceMeters: ..., boundingBoxHeightPixels: ...)` and use
///      the returned value to replace [focalLengthPixels] below.
///   4. Repeat at 2-3 different distances with the same object and
///      average the results for a more stable constant — a single
///      measurement is a starting point, not a robust calibration.
class DistanceEstimationConfig {
  DistanceEstimationConfig._();

  /// UNCALIBRATED DEFAULT — order-of-magnitude reasonable for a phone
  /// camera. Expressed against a fixed 300px reference space (see
  /// [YoloTfliteHazardDetector]'s doc comment on why every detector
  /// converts into this SAME reference regardless of its own native
  /// model input size — swapping detectors must never silently change
  /// what this constant means), not measured against any specific
  /// device. See [isCalibrated] and the class doc comment's
  /// calibration procedure.
  ///
  /// A real calibration EXPERIMENT was run on-device (OPPO CPH2421,
  /// MediaTek mt6762/6765, person class, assumed height 1.7m, rear
  /// camera) via [DistanceCalibrationScreen]. Result was NOT validated
  /// enough to promote to production — kept here for the record, not
  /// as a value to reuse without redoing the measurement properly:
  ///
  ///   Calibration samples (300px reference space):
  ///     1.0m -> bbox=256.3px -> implied focal=150.8px
  ///     1.0m -> bbox=213.9px -> implied focal=125.8px
  ///     2.0m -> bbox=146.4px -> implied focal=172.2px
  ///     3.0m -> bbox=135.0px -> implied focal=238.2px
  ///     mean of the above 4 = 171.75px (the candidate value trialed)
  ///   Excluded: a 0.5m sample (implied focal 87.5px) — physically
  ///   implausible, very likely partial-body framing at close range.
  ///
  ///   Held-out validation (NOT used to compute the 171.75 candidate),
  ///   distances paced/estimated rather than tape-measured:
  ///     true 2.0m -> bbox=117.6px -> candidate gives 2.48m (+24.1% err)
  ///     true 4.0m -> bbox=114.2px -> candidate gives 2.56m (-36.1% err)
  ///     true 5.0m -> bbox=132.5px (mean of 3 auto-polled reads,
  ///       ~1% spread within the burst) -> candidate gives 2.20m
  ///       (-55.9% err)
  ///
  ///   VERDICT: the 171.75px candidate was a large improvement over
  ///   700.0 in absolute terms (which erred +160% to +406% on the same
  ///   held-out points), but still carried 24-56% error that GREW and
  ///   FLIPPED SIGN with distance — implied focal length rose
  ///   monotonically with true distance across every sample (~138px
  ///   avg at 1m -> 172px at 2m -> 238px at 3m -> ~390px at 5m),
  ///   meaning a single constant cannot fit this relationship. The
  ///   5.0m held-out bbox was also larger than the 4.0m one, which is
  ///   physically inconsistent (farther should never mean bigger) and
  ///   points to real position uncertainty in the un-taped long-range
  ///   readings. NOT promoted to production for these reasons — see
  ///   [isCalibrated]. A real fix would need tape-measured data across
  ///   more distances and likely a non-single-constant model, not a
  ///   restatement of this same experiment.
  static const double focalLengthPixels = 700.0;

  /// False — see [focalLengthPixels]'s doc comment for the real
  /// calibration experiment that was run and why its result (171.75px)
  /// was NOT promoted to this production constant: held-out error grew
  /// with distance (24% at 2m to 56% at 5m) rather than staying flat,
  /// meaning the single-constant model itself is not yet validated,
  /// not just under-measured. Flip this to true only after a properly
  /// tape-measured, distance-consistent re-calibration. Exists so any
  /// caller — a research evaluation, a debug screen, a future
  /// contributor — can check this programmatically instead of having
  /// to know to go read this file's doc comment.
  static const bool isCalibrated = false;

  /// Computes the focal length (in the model's 300x300 input pixel
  /// space) implied by one real measurement — the actual calibration
  /// arithmetic from this class's doc comment, as runnable code
  /// instead of a formula a human has to transcribe correctly by hand.
  /// Returns null for a non-positive/invalid measurement rather than
  /// a nonsensical negative or infinite "focal length."
  static double? calibrateFocalLengthPixels({
    required double knownObjectHeightMeters,
    required double distanceMeters,
    required double boundingBoxHeightPixels,
  }) {
    if (knownObjectHeightMeters <= 0 || distanceMeters <= 0 || boundingBoxHeightPixels <= 0) return null;
    return (boundingBoxHeightPixels * distanceMeters) / knownObjectHeightMeters;
  }

  /// Typical real-world height (meters) for each allowed COCO class —
  /// used as the "known object height" in the distance formula above.
  /// These are representative averages, not per-instance measurements
  /// (a child is shorter than 1.7m, a hatchback is shorter than a
  /// van) — the same kind of approximation [DistanceBand] already
  /// makes elsewhere in this app. Keys must exactly match
  /// [CocoLabelConfig.hazardPriorities]' keys (lowercase COCO labels).
  static const Map<String, double> knownObjectHeightsMeters = {
    'person': 1.7,
    'bicycle': 1.1,
    'motorcycle': 1.3,
    'car': 1.5,
    'bus': 3.2,
    'truck': 3.0,
    'traffic light': 3.0, // pole-mounted housing, typical installed height
    'stop sign': 2.1, // sign face + post, typical installed height
    'bench': 0.45, // seat height (the most relevant dimension for a collision)
  };

  /// Returns `null` (not 0.0 or a guess) when [label] has no
  /// configured known height, or [boundingBoxHeightPixels] is
  /// non-positive — callers must treat "no estimate" as a real,
  /// distinct case (see [DetectedHazard.estimatedDistanceMeters]'s
  /// doc comment), not silently substitute a default distance.
  static double? estimateDistanceMeters(String label, double boundingBoxHeightPixels) {
    if (boundingBoxHeightPixels <= 0) return null;
    final knownHeight = knownObjectHeightsMeters[label];
    if (knownHeight == null) return null;
    return (knownHeight * focalLengthPixels) / boundingBoxHeightPixels;
  }

  /// Distance-band thresholds re-expressed in meters (replacing the
  /// old area-fraction-only [ObjectPriorityConfig.distanceBandFor]
  /// for any hazard where a real distance estimate is available).
  /// Hand-picked, not measured — retune after field testing.
  ///
  /// Widened slightly from the original hand-picked values (1.5/3.0/6.0
  /// -> 2.0/4.0/8.0) as a deliberate, documented hedge against
  /// [focalLengthPixels] being an uncalibrated estimate: with an
  /// unverified focal length, an object could plausibly be reported at
  /// a distance up to roughly +/-30% off; wider band boundaries make
  /// it less likely that estimation error alone flips a hazard from
  /// "near" to "far" (a prioritization-relevant band change) purely
  /// due to constant-calibration error rather than the object actually
  /// being farther away. This is a mitigation for the limitation, not
  /// a fix for it — recalibrating [focalLengthPixels] properly is
  /// still the real fix (see the class doc comment).
  static const double veryNearMeters = 2.0;
  static const double nearMeters = 4.0;
  static const double farMeters = 8.0;

  static DistanceBand distanceBandForMeters(double meters) {
    if (meters <= veryNearMeters) return DistanceBand.veryNear;
    if (meters <= nearMeters) return DistanceBand.near;
    if (meters <= farMeters) return DistanceBand.far;
    return DistanceBand.unknown;
  }
}
