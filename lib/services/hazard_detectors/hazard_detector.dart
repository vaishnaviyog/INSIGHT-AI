import 'package:camera/camera.dart';
import '../../models/detected_hazard.dart';

/// Contract that any hazard-detection backend must implement.
///
/// This is the seam that makes [HazardDetectionService] detector-
/// agnostic. Swapping ML Kit for COCO SSD MobileNet, or later
/// migrating to a custom-trained YOLO model — or even adding a future
/// external/IoT sensor as a detector — only requires a new class that
/// implements this interface. [HazardDetectionService] and everything
/// above it (navigation_screen.dart, and later the Risk Prediction
/// Engine) never need to change.
abstract class IHazardDetector {
  /// Human-readable identifier, used for logging/telemetry and
  /// attached to results via [DetectedHazard.sourceDetector].
  String get name;

  /// True once this backend is genuinely ready to produce results
  /// (e.g. a model asset loaded successfully). Exposed so
  /// [HazardDetectionService] can report per-backend status to the
  /// debug dashboard — useful for confirming, without waiting for an
  /// actual obstacle in frame, whether a detector like
  /// [YoloTfliteHazardDetector] found its model files or is silently
  /// falling back. An implementation with no failure mode could
  /// simply return `true`.
  bool get isAvailable;

  /// One-time setup (e.g., loading a model file, initializing an ML
  /// Kit detector). Must be awaited before [detect] is called.
  ///
  /// Implementations should fail SOFTLY here: if setup fails (for
  /// example, a model asset is missing), catch the error internally
  /// and leave the detector in a state where [detect] simply returns
  /// an empty list rather than throwing. This lets
  /// [HazardDetectionService] safely run multiple detectors without
  /// one failed backend crashing the whole detection pipeline.
  Future<void> initialize();

  /// Run detection on a single camera frame.
  ///
  /// Implementations should return an empty list rather than throwing
  /// when a frame can't be processed — this matches the fail-soft
  /// behavior of the app's original detection code.
  Future<List<DetectedHazard>> detect(CameraImage image, int sensorOrientation);

  /// Release native resources (model interpreters, ML Kit detectors,
  /// camera buffers, etc.). Must be safe to call even if [initialize]
  /// never completed successfully.
  void dispose();
}
