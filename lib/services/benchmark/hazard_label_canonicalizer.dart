/// The fixed set of hazard classes detection quality is measured
/// against — deliberately the SAME 9 classes already used in
/// production (`CocoLabelConfig.hazardPriorities`), so a
/// precision/recall comparison across candidate models is measuring
/// "how well does each one detect the classes this app actually
/// cares about," not each model's full, differently-sized native
/// vocabulary (COCO-80 for SSD/EfficientDet exports, potentially a
/// different or reordered set for a custom YOLO export).
class HazardLabelCanonicalizer {
  HazardLabelCanonicalizer._();

  static const List<String> canonicalClasses = [
    'car',
    'bus',
    'truck',
    'motorcycle',
    'bicycle',
    'person',
    'traffic light',
    'stop sign',
    'bench',
  ];

  /// Maps known naming variants seen across different model exports'
  /// label files to the canonical name above. NOT exhaustive — if a
  /// candidate's label file uses a variant not listed here, its
  /// detections for that class will not match ground truth and will
  /// show up as reduced recall for that class. That failure mode is
  /// visible in the exported per-class breakdown (an unexpectedly low
  /// recall for exactly one class, with every other class normal, is
  /// the signal to check this map rather than the model itself).
  static const Map<String, String> _aliases = {
    'motorbike': 'motorcycle',
    'motor cycle': 'motorcycle',
    'traffic_light': 'traffic light',
    'trafficlight': 'traffic light',
    'stop_sign': 'stop sign',
    'stopsign': 'stop sign',
  };

  /// Returns the canonical class name for [rawLabel], or null if it
  /// doesn't correspond to any of the 9 evaluated classes (e.g. COCO's
  /// "laptop," "fork," etc. — real classes the model may detect, just
  /// not ones this app evaluates or cares about).
  static String? canonicalize(String rawLabel) {
    final normalized = rawLabel.trim().toLowerCase();
    if (canonicalClasses.contains(normalized)) return normalized;
    return _aliases[normalized];
  }
}
