import 'dart:ui';

/// Priority tier assigned to a detected hazard.
///
/// This controls how urgently (and whether, in a future milestone) a
/// hazard is announced. Lower index = more urgent, which is relied on
/// by the sort order in [HazardDetectionService]-consuming code.
enum HazardPriority {
  critical, // fast-moving / high-risk (cars, motorcycles, buses, trucks)
  caution, // present a real risk but lower urgency (bicycles)
  informational, // detected but not spoken as a warning by default
}

/// Coarse proximity estimate derived from bounding-box size relative
/// to the camera frame.
///
/// This is a monocular heuristic (no depth sensor is used anywhere in
/// this app) and should be treated as an approximation for prioritizing
/// warnings, not a real distance measurement.
enum DistanceBand {
  veryNear,
  near,
  far,
  unknown,
}

/// Coarse left/center/right position derived from a bounding box's
/// horizontal center relative to the frame width. Vision-only (there
/// is no "behind you" — the camera only sees forward), unlike the
/// GPS-bearing-derived relative directions used elsewhere in the app
/// (see `navigation_screen.dart`'s `relativeDirection`, which is a
/// separate, unrelated concept).
enum HorizontalPosition { left, center, right }

/// A single detected hazard, in a detector-agnostic shape.
///
/// This is the shared contract between any [IHazardDetector]
/// implementation (a bundled COCO SSD MobileNet model today, or a
/// future custom-trained YOLO model / external IoT sensor) and the
/// rest of the app. As long as a detector produces this object,
/// nothing downstream (HazardDetectionService, navigation_screen.dart)
/// needs to know which backend actually ran.
class DetectedHazard {
  final String label;
  final HazardPriority priority;
  final double confidence;
  final Rect? boundingBox;
  final DistanceBand distanceBand;
  final DateTime timestamp;

  /// Which detector produced this result (e.g. "coco_tflite").
  /// Useful for debugging and for the research evaluation export.
  final String sourceDetector;

  /// Estimated real-world distance in meters, from the focal-length /
  /// known-object-height heuristic in `DistanceEstimationConfig`. Null
  /// when the label has no configured known height, or no bounding
  /// box is available — callers must handle this gracefully (fall
  /// back to a distance-free message) rather than assume it's always
  /// present.
  final double? estimatedDistanceMeters;

  /// Left/center/right, from the bounding box's horizontal center.
  /// Null under the same conditions as [estimatedDistanceMeters]
  /// (no bounding box to derive it from).
  final HorizontalPosition? horizontalPosition;

  /// AUDIT ADD (Phase 3/4 — Time-to-Collision): estimated seconds
  /// until this hazard and the user close to zero distance, from
  /// [CollisionTimeEstimator]. Null whenever a safe estimate isn't
  /// possible — see that class's doc comment for the exact cases
  /// (stationary, receding, first observation, no distance data) —
  /// NEVER a fabricated/meaningless number. Set by
  /// [HazardDetectionService] after temporal confirmation, so it is
  /// always null on [HazardDetectionService.lastRawDetections].
  final double? timeToCollisionSeconds;

  DetectedHazard({
    required this.label,
    required this.priority,
    required this.confidence,
    required this.distanceBand,
    required this.sourceDetector,
    this.boundingBox,
    this.estimatedDistanceMeters,
    this.horizontalPosition,
    this.timeToCollisionSeconds,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  /// Returns a copy with [timeToCollisionSeconds] replaced — added
  /// specifically so [CollisionTimeEstimator] can annotate an
  /// already-constructed hazard (produced by a detector that knows
  /// nothing about motion tracking) without every detector needing to
  /// know about TTC at all.
  DetectedHazard copyWithTimeToCollision(double? timeToCollisionSeconds) => DetectedHazard(
        label: label,
        priority: priority,
        confidence: confidence,
        distanceBand: distanceBand,
        sourceDetector: sourceDetector,
        boundingBox: boundingBox,
        estimatedDistanceMeters: estimatedDistanceMeters,
        horizontalPosition: horizontalPosition,
        timeToCollisionSeconds: timeToCollisionSeconds,
        timestamp: timestamp,
      );

  /// JSON-serializable representation. Kept intentionally simple and
  /// transport-agnostic so this same object could later be logged,
  /// sent to a companion device, or consumed by a future IoT bridge
  /// without modification.
  Map<String, dynamic> toJson() => {
        'label': label,
        'priority': priority.name,
        'confidence': confidence,
        'distanceBand': distanceBand.name,
        'sourceDetector': sourceDetector,
        'timestamp': timestamp.toIso8601String(),
        if (estimatedDistanceMeters != null) 'estimatedDistanceMeters': estimatedDistanceMeters,
        if (horizontalPosition != null) 'horizontalPosition': horizontalPosition!.name,
        if (timeToCollisionSeconds != null) 'timeToCollisionSeconds': timeToCollisionSeconds,
        if (boundingBox != null)
          'boundingBox': {
            'left': boundingBox!.left,
            'top': boundingBox!.top,
            'width': boundingBox!.width,
            'height': boundingBox!.height,
          },
      };

  @override
  String toString() =>
      'DetectedHazard(label: $label, priority: ${priority.name}, '
      'confidence: ${confidence.toStringAsFixed(2)}, '
      'distance: ${distanceBand.name}'
      '${estimatedDistanceMeters != null ? ' (~${estimatedDistanceMeters!.toStringAsFixed(1)}m)' : ''}'
      '${horizontalPosition != null ? ', position: ${horizontalPosition!.name}' : ''}'
      '${timeToCollisionSeconds != null ? ', TTC: ${timeToCollisionSeconds!.toStringAsFixed(1)}s' : ''}, '
      'source: $sourceDetector)';
}
