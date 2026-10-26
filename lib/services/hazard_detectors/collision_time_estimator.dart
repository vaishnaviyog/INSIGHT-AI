import '../../models/detected_hazard.dart';

/// Estimates Time-To-Collision (TTC) — approximately how many seconds
/// until a hazard and the user close to zero distance — from
/// consecutive [DetectedHazard.estimatedDistanceMeters] samples for
/// the same label.
///
/// AUDIT NOTE: this class did not exist anywhere in the project before
/// this fix, despite Phase 3/4 of the conference-readiness pass
/// treating TTC as an existing feature to "review." There was nothing
/// to review — no velocity/motion estimate of any kind was computed
/// anywhere. This adds a genuine, honestly-scoped one rather than a
/// fabricated value.
///
/// TRACKING IS BY LABEL, NOT BY OBJECT IDENTITY — the exact same
/// approximation [HazardTemporalFilter] already documents and uses
/// ("the same class label present in consecutive [confirmed] frames"),
/// because this app has no per-instance object tracking/re-
/// identification. This is not pretending to be a Kalman-filtered
/// multi-object tracker; it is a simple, explainable closing-speed
/// estimate from two samples, consistent with this project's
/// documented "explainable heuristics over ML" approach used
/// throughout the risk-assessment/behaviour-learning modules.
///
/// AUDIT NOTE (P1-13): the concrete risk this creates is TWO cars (or
/// any two same-labeled objects) present at once contaminating each
/// other's distance history — e.g. car A leaves the frame the same
/// moment car B enters, and this class would (without the guard
/// below) compare B's distance against A's last sample as if they
/// were one continuous object. Building real per-instance tracking to
/// eliminate this is explicitly out of scope for this pass — the
/// mitigation here is [_maxPlausibleClosingSpeedMetersPerSecond]:
/// a closing speed too large to be a real single object's motion is
/// treated as more likely a same-label identity switch than a
/// genuine fast approach, and produces no TTC rather than a
/// confident-looking wrong one. This does not "fabricate object
/// identity" (no attempt is made to guess which physical object a
/// sample belongs to) — it only refuses to output a number when the
/// two samples are too inconsistent to plausibly be the same object.
///
/// SAFE FALLBACK, PER EXPLICIT REQUIREMENT: [estimate] returns null —
/// meaning "TTC unavailable," never a meaningless number — whenever:
/// - this is the first observation of a label (no prior sample to
///   compare against),
/// - the previous sample is older than [_maxSampleAgeSeconds] (stale;
///   the object may have left and a new one entered, or detection was
///   paused) — the two samples are not treated as continuous motion,
/// - either sample has no [DetectedHazard.estimatedDistanceMeters]
///   (the label has no configured known height, or no bounding box),
/// - the object is stationary or moving AWAY (distance not
///   decreasing) — dividing a non-positive closing speed into a
///   distance would produce a negative or infinite "TTC," which is
///   not a real quantity and must not be spoken or scored as one.
///
/// STATEFUL, LIKE [HazardTemporalFilter]: must remember the previous
/// sample per label, so [HazardDetectionService] owns one long-lived
/// instance — not safe to construct fresh per call.
class CollisionTimeEstimator {
  /// Samples further apart than this are treated as unrelated
  /// (detection paused, or the tracked "same label" is very likely a
  /// genuinely different object that happened to enter as the first
  /// one left) rather than averaged into a closing-speed estimate.
  static const double _maxSampleAgeSeconds = 3.0;

  /// A closing speed below this (m/s) is treated as "not really
  /// approaching" — avoids reporting a wildly large, technically-
  /// positive-but-meaningless TTC (e.g. 400 seconds) from sensor/
  /// distance-estimate noise around a near-zero relative speed.
  static const double _minClosingSpeedMetersPerSecond = 0.05;

  /// AUDIT ADD (P1-13 — object-identity limitation): a closing speed
  /// ABOVE this is treated as physically implausible for this app's
  /// pedestrian-hazard scenarios and rejected — not because such
  /// speeds are impossible in the real world, but because tracking is
  /// BY LABEL, NOT BY OBJECT IDENTITY (see this class's own doc
  /// comment). The single most likely explanation for an extreme
  /// jump between two consecutive same-label samples is that they are
  /// two DIFFERENT physical objects (e.g. one car left the frame the
  /// same moment a different car entered it), not one object
  /// suddenly closing distance at high speed. 15 m/s (~54 km/h
  /// relative closing speed) is a deliberately generous upper bound
  /// for this app's use case — genuinely valid fast-approach TTCs
  /// this rejects would still be caught by the temporal filter's own
  /// distance-band/priority signal, so this errs toward NOT fabricating
  /// a confident number over never flagging a real fast approach.
  static const double _maxPlausibleClosingSpeedMetersPerSecond = 15.0;

  final Map<String, ({double distanceMeters, DateTime timestamp})> _lastSampleByLabel = {};

  /// Returns [hazards] with [DetectedHazard.timeToCollisionSeconds]
  /// populated where a safe estimate is possible, unchanged otherwise.
  /// Call once per CONFIRMED (temporally-filtered) detection list —
  /// same cadence as [HazardTemporalFilter.confirm] — not on raw
  /// per-frame detections, so a single-frame distance-estimate flicker
  /// can't masquerade as a closing-speed spike.
  List<DetectedHazard> annotate(List<DetectedHazard> hazards) {
    final now = DateTime.now();
    final presentLabels = hazards.map((h) => h.label).toSet();
    // Same reasoning as HazardTemporalFilter: a label no longer
    // present has nothing meaningful to compare its NEXT appearance
    // against, so its sample is dropped rather than kept indefinitely.
    _lastSampleByLabel.removeWhere((label, _) => !presentLabels.contains(label));

    return hazards.map((hazard) {
      final distance = hazard.estimatedDistanceMeters;
      if (distance == null) return hazard;

      final previous = _lastSampleByLabel[hazard.label];
      _lastSampleByLabel[hazard.label] = (distanceMeters: distance, timestamp: now);
      if (previous == null) return hazard; // first observation — no TTC yet

      final dtSeconds = now.difference(previous.timestamp).inMilliseconds / 1000.0;
      if (dtSeconds <= 0 || dtSeconds > _maxSampleAgeSeconds) return hazard;

      final closingSpeed = (previous.distanceMeters - distance) / dtSeconds;
      if (closingSpeed < _minClosingSpeedMetersPerSecond) {
        // Stationary or moving away — explicitly no TTC, not a
        // negative/infinite one.
        return hazard;
      }
      if (closingSpeed > _maxPlausibleClosingSpeedMetersPerSecond) {
        // See _maxPlausibleClosingSpeedMetersPerSecond's doc comment:
        // almost certainly a same-label identity switch between two
        // different physical objects, not one real fast approach.
        return hazard;
      }

      final ttc = distance / closingSpeed;
      return hazard.copyWithTimeToCollision(ttc);
    }).toList();
  }

  /// Call when detection is paused/stopped for a reason unrelated to
  /// the camera feed itself, so stale samples don't carry into a
  /// later, unrelated session — mirrors
  /// [HazardTemporalFilter.reset]'s exact purpose.
  void reset() => _lastSampleByLabel.clear();
}
