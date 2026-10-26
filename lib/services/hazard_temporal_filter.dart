import '../models/detected_hazard.dart';


/// Confirms a hazard label only after it has appeared in at least
/// [requiredConsecutiveFrames] consecutive detection runs, per
/// explicit project requirement — "do not announce an object
/// immediately... if it disappears immediately, ignore it."
///
/// TRACKING IS BY LABEL, NOT BY OBJECT IDENTITY: this app has no
/// object-tracking/re-identification system (no per-instance ID
/// persists frame-to-frame), so "the same object" is approximated as
/// "the same class label present in consecutive frames" — e.g. three
/// frames in a row reporting *a* car is treated as confirmation,
/// whether or not it's literally the same physical car. This is the
/// simplest correct interpretation available without a much larger
/// tracking subsystem, and still delivers the intended effect: a
/// single-frame flicker (a misclassification, a passing shadow) never
/// reaches the confirmed list, while a hazard that's genuinely present
/// for multiple frames does.
///
/// STATEFUL, UNLIKE [RiskAssessmentService]/[AdaptiveGuidanceService]:
/// this class must remember frame-to-frame counts, so — unlike those
/// stateless services — it is NOT safe to construct fresh per call.
/// [HazardDetectionService] owns a single long-lived instance.
class HazardTemporalFilter {
  final int requiredConsecutiveFrames;

  HazardTemporalFilter({this.requiredConsecutiveFrames = 3});

  final Map<String, int> _consecutiveCounts = {};

  /// Feeds one frame's raw (already confidence/allowlist-filtered)
  /// detections in and returns only the subset whose label has now
  /// been seen [requiredConsecutiveFrames] times in a row, preserving
  /// [rawHazards]' existing order (already priority/confidence-sorted
  /// by the caller).
  ///
  /// A label absent from this frame has its streak reset to zero
  /// immediately — "if it disappears immediately, ignore it" is
  /// intentionally strict, not a grace-period/leaky-bucket design.
  List<DetectedHazard> confirm(List<DetectedHazard> rawHazards) {
    final presentLabels = rawHazards.map((h) => h.label).toSet();

    // Reset any tracked label that didn't appear this frame at all.
    _consecutiveCounts.removeWhere((label, _) => !presentLabels.contains(label));

    final confirmed = <DetectedHazard>[];
    // A frame can contain more than one detection of the SAME label
    // (e.g. two cars) — only increment each label's streak once per
    // frame, using the first (highest-priority/confidence, since
    // rawHazards is already sorted) occurrence for the confirmed list.
    final incrementedThisFrame = <String>{};
    for (final hazard in rawHazards) {
      if (incrementedThisFrame.add(hazard.label)) {
        _consecutiveCounts[hazard.label] = (_consecutiveCounts[hazard.label] ?? 0) + 1;
      }
      if ((_consecutiveCounts[hazard.label] ?? 0) >= requiredConsecutiveFrames) {
        confirmed.add(hazard);
      }
    }
    return confirmed;
  }

  /// Call when detection is paused/stopped for a reason unrelated to
  /// the camera feed itself (e.g. navigation ending) so stale streaks
  /// don't carry into a later, unrelated session.
  void reset() => _consecutiveCounts.clear();
}
