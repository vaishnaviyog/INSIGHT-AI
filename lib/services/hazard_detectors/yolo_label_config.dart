import '../../models/detected_hazard.dart';

/// YOLOv8n-specific configuration, used exclusively by
/// [YoloTfliteHazardDetector] — the parallel file
/// `coco_label_config.dart`'s own doc comment anticipated ("when the
/// custom YOLO-based detector is built... it should get its own
/// parallel file — e.g. `yolo_label_config.dart` — with its own class
/// vocabulary and priority mapping").
///
/// KEPT SEPARATE FROM `CocoLabelConfig` (deleted) RATHER THAN SHARED, even
/// though both list the same underlying COCO class NAMES: the two
/// detectors' exported label FILES are not guaranteed to use the same
/// class ORDER or the same "index 0 = background placeholder" quirk
/// (see `CocoTfliteHazardDetector._labelIndexOffset`'s doc comment for
/// that legacy-SSD-specific gotcha, which does not apply to a
/// standard Ultralytics YOLO export at all — class index 0 there is a
/// real class, not a placeholder). Sharing one map keyed by label
/// STRING (not index) is safe and correct; sharing one label INDEX
/// convention across two differently-exported models is not, so this
/// stays a separate file/class per that existing architectural note.
class YoloLabelConfig {
  YoloLabelConfig._();

  /// Same navigation-hazard allowlist and priority tiers as
  /// `CocoLabelConfig.hazardPriorities` (deleted) — deliberately IDENTICAL in
  /// content (same class names, same tiers, same reasoning), because
  /// nothing about which classes matter for pedestrian safety changed
  /// by swapping the detection backend. Kept as its own copy (not a
  /// shared import) per this file's class doc comment on why the two
  /// detectors' configs stay separate files.
  static const Map<String, HazardPriority> hazardPriorities = {
    'car': HazardPriority.critical,
    'bus': HazardPriority.critical,
    'truck': HazardPriority.critical,
    'motorcycle': HazardPriority.critical,
    'bicycle': HazardPriority.caution,
    'person': HazardPriority.caution,
    'traffic light': HazardPriority.informational,
    'stop sign': HazardPriority.informational,
    'bench': HazardPriority.informational,
  };

  /// Minimum PER-CLASS confidence (post-argmax, pre-NMS) for a YOLO
  /// detection to be considered at all. Set independently from
  /// `CocoLabelConfig.confidenceThreshold` (deleted) (0.60) — deliberately NOT
  /// assumed equal, since YOLOv8's raw per-class sigmoid output and
  /// SSD's postprocessed "detection score" are different quantities
  /// calibrated differently by their respective training/export
  /// pipelines. 0.5 is the same starting default the project's own
  /// benchmark harness already uses for this exact candidate
  /// (`BenchmarkModelSpec.confidenceThreshold`'s default) — a
  /// reasonable starting point, explicitly NOT claimed to be tuned
  /// against this app's real-world footage. Retune after on-device
  /// testing with the actual model file.
  static const double confidenceThreshold = 0.5;

  /// IoU threshold for greedy per-class Non-Max Suppression — same
  /// value already proven in `ModelBenchmarkService._runYoloStyle`'s
  /// NMS pass for this exact model family/output shape. A LOWER value
  /// suppresses more aggressively (fewer, more separated boxes kept);
  /// a HIGHER value allows more overlapping boxes through.
  static const double nmsIouThreshold = 0.45;
}
