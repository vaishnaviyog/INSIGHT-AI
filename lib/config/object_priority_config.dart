import '../models/detected_hazard.dart';

/// Central, data-only configuration for the parts of hazard
/// classification that are genuinely detector-agnostic: the generic
/// distance-band geometry helper that any bounding-box-producing
/// detector can reuse.
///
/// DELIBERATE BOUNDARY: this file must never contain assumptions
/// specific to one detector's class vocabulary (e.g. COCO's 80
/// classes as YOLOv8n uses them). Each detector owns its own
/// label-to-priority mapping in a config file that lives alongside
/// it — see `hazard_detectors/yolo_label_config.dart` for the current
/// example (the earlier `coco_label_config.dart`, for the now-removed
/// SSD detector, has been deleted). This keeps the "only the detector
/// knows its own backend" boundary real rather than just conventional.
class ObjectPriorityConfig {
  ObjectPriorityConfig._();

  // --- Distance-band thresholds -------------------------------------
  // Expressed as bounding-box area / total frame area. Used today as
  // YoloTfliteHazardDetector's fallback for any label with no known
  // height configured in DistanceEstimationConfig (that detector
  // prefers the real meters-based estimate whenever one is available
  // — see its own doc comment for exactly when this fallback fires).
  // These are a coarse monocular heuristic (no depth sensor), tuned as
  // a starting point — expect to adjust after field testing.
  static const double veryNearAreaThreshold = 0.20;
  static const double nearAreaThreshold = 0.08;
  static const double farAreaThreshold = 0.02;

  static DistanceBand distanceBandFor(double areaFraction) {
    if (areaFraction >= veryNearAreaThreshold) return DistanceBand.veryNear;
    if (areaFraction >= nearAreaThreshold) return DistanceBand.near;
    if (areaFraction >= farAreaThreshold) return DistanceBand.far;
    return DistanceBand.unknown;
  }
}
