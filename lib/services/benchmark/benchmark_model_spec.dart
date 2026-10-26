/// Output-tensor layout a candidate model uses. The harness needs
/// this because different model families decode their raw output
/// completely differently — timing "just the interpreter call" would
/// under-count real per-frame cost for whichever family needs more
/// post-processing. Each spec's [outputFormat] tells
/// `ModelBenchmarkService` which decode path to time alongside
/// inference, so all candidates are measured on the same "camera
/// frame in, hazards out" basis your actual pipeline runs, not just a
/// bare tensor multiply.
enum ModelOutputFormat {
  /// Standard 4-tensor SSD/MobileDet postprocessing op layout — the
  /// same one `CocoTfliteHazardDetector` already parses (boxes,
  /// classes, scores, count).
  ssdFourTensor,

  /// EfficientDet-Lite's TFLite Model Maker / AutoML export uses the
  /// same 4-tensor layout as SSD (boxes/classes/scores/count) when
  /// exported with the standard postprocessing op, which is the
  /// export path this harness expects — see the candidate's own
  /// bundling note in `assets/ml_models/README.md`.
  efficientDetFourTensor,

  /// YOLOv8's TFLite export has a single output tensor
  /// `[1, 4+numClasses, numBoxes]` (no built-in NMS) — decoding it
  /// requires manual confidence filtering + non-max suppression here
  /// in Dart, unlike the SSD family. See
  /// `ModelBenchmarkService._decodeYoloOutput` for exactly what's
  /// timed.
  yoloSingleTensorNoNms,
}

/// One candidate the benchmark harness can run. NOT wired into
/// `HazardDetectionService`/`IHazardDetector` — this is measurement-
/// only scaffolding, kept deliberately separate so nothing about the
/// production detection pipeline changes until a winner is chosen
/// from real, on-device numbers (per explicit project instruction:
/// do not assume any one candidate first).
class BenchmarkModelSpec {
  final String displayName;
  final String modelAssetPath;
  final String labelsAssetPath;
  final int inputSize;
  final ModelOutputFormat outputFormat;

  /// Minimum confidence for a detection to count at all, for THIS
  /// candidate. Deliberately per-model rather than one global
  /// constant — different architectures/exports are calibrated
  /// differently, and using one fixed threshold across all of them
  /// would silently bias the precision/recall comparison toward
  /// whichever model happens to suit that one number.
  final double confidenceThreshold;

  /// SSD/EfficientDet-family gotcha (see the existing, shipped
  /// `CocoTfliteHazardDetector._labelIndexOffset` for the same issue
  /// in production): some exported label files include a leading
  /// placeholder line, shifting every real class index by one. Not
  /// used for [ModelOutputFormat.yoloSingleTensorNoNms].
  final int labelIndexOffset;

  /// Published, NOT measured — shown in the harness UI purely so a
  /// human picking which candidates to run has the literature context
  /// alongside the real numbers the harness is about to produce next
  /// to it. Never substituted for a measured value in any exported
  /// result row.
  final String publishedSizeNote;
  final String publishedMapNote;

  const BenchmarkModelSpec({
    required this.displayName,
    required this.modelAssetPath,
    required this.labelsAssetPath,
    required this.inputSize,
    required this.outputFormat,
    required this.publishedSizeNote,
    required this.publishedMapNote,
    this.confidenceThreshold = 0.5,
    this.labelIndexOffset = 1,
  });

  /// The four candidates from the vision-module analysis: the
  /// existing bundled model (as a control/baseline) plus the three
  /// shortlisted replacements. None of these four files are bundled
  /// with the app — see `assets/ml_models/README.md` for exactly what
  /// to download and where to place each one. A candidate whose file
  /// is missing simply won't run (reported as a failed row with a
  /// clear reason), the same fail-soft convention
  /// `CocoTfliteHazardDetector` already uses for its own model file.
  static const List<BenchmarkModelSpec> candidates = [
    // AUDIT ADD (Phase C4 — YOLO accuracy + latency investigation): the
    // ACTUAL production model/labels/threshold (see
    // YoloTfliteHazardDetector/YoloLabelConfig) — none of the other
    // entries in this list point at it. "SSD MobileNet V1 (current
    // baseline)" below is stale: it names the RETIRED detector YOLOv8n
    // already replaced in production (see HazardDetectionService's own
    // doc comment), and the separate "YOLOv8n" entry further down points
    // at assets/ml_models/benchmark_candidates/yolov8n.tflite — a
    // different, currently-unbundled file, NOT the production asset at
    // assets/ml_models/yolov8n.tflite. Added so this harness's existing
    // live-capture + ground-truth-tagging UI (model_benchmark_screen.dart)
    // can measure precision/recall/FP/FN for what the app actually runs
    // today, not only for un-bundled replacement candidates.
    BenchmarkModelSpec(
      displayName: 'YOLOv8n (production, current)',
      modelAssetPath: 'assets/ml_models/yolov8n.tflite',
      labelsAssetPath: 'assets/ml_models/yolov8n_labels.txt',
      inputSize: 640,
      outputFormat: ModelOutputFormat.yoloSingleTensorNoNms,
      confidenceThreshold: 0.5, // matches YoloLabelConfig.confidenceThreshold exactly
      publishedSizeNote: '~12.2 MB (float32, the actual bundled file)',
      publishedMapNote: '~30-31 COCO mAP (edge-device literature, not this app — see Phase C4 measured numbers instead)',
    ),
    BenchmarkModelSpec(
      displayName: 'SSD MobileNet V1 (RETIRED — not current production, kept for historical comparison only)',
      modelAssetPath: 'assets/ml_models/coco_ssd_mobilenet.tflite',
      labelsAssetPath: 'assets/ml_models/coco_labels.txt',
      inputSize: 300,
      outputFormat: ModelOutputFormat.ssdFourTensor,
      publishedSizeNote: '~7.0 MB',
      publishedMapNote: '~19-22 COCO mAP (edge-device literature, not this app)',
    ),
    BenchmarkModelSpec(
      displayName: 'SSDLite MobileDet',
      modelAssetPath: 'assets/ml_models/benchmark_candidates/ssdlite_mobiledet.tflite',
      labelsAssetPath: 'assets/ml_models/benchmark_candidates/ssdlite_mobiledet_labels.txt',
      inputSize: 320,
      outputFormat: ModelOutputFormat.ssdFourTensor,
      publishedSizeNote: '~5.1 MB',
      publishedMapNote: '~27-30 COCO mAP (edge-device literature, not this app)',
    ),
    BenchmarkModelSpec(
      displayName: 'EfficientDet-Lite0',
      modelAssetPath: 'assets/ml_models/benchmark_candidates/efficientdet_lite0.tflite',
      labelsAssetPath: 'assets/ml_models/benchmark_candidates/efficientdet_lite0_labels.txt',
      inputSize: 320,
      outputFormat: ModelOutputFormat.efficientDetFourTensor,
      publishedSizeNote: '~5.7 MB',
      publishedMapNote: '~23-26 COCO mAP (edge-device literature, not this app)',
    ),
    BenchmarkModelSpec(
      displayName: 'YOLOv8n',
      modelAssetPath: 'assets/ml_models/benchmark_candidates/yolov8n.tflite',
      labelsAssetPath: 'assets/ml_models/benchmark_candidates/yolov8n_labels.txt',
      inputSize: 640,
      outputFormat: ModelOutputFormat.yoloSingleTensorNoNms,
      publishedSizeNote: '~6.5 MB (float) / ~3.9 MB (int8)',
      publishedMapNote: '~30-31 COCO mAP (edge-device literature, not this app)',
    ),
    // Optional fourth candidate, per explicit request — TFLite export
    // is supported for YOLO11n (community-confirmed via `yolo export
    // model=yolo11n.pt format=tflite`, producing a single-tensor
    // output of the same shape FAMILY as YOLOv8n — exact numBoxes
    // varies with export image size, e.g. (1, 84, 5040) at a
    // 384x640 export vs (1, 84, 8400) at square 640x640 — which is
    // exactly why `ModelBenchmarkService._runYoloStyle` reads
    // channels/numBoxes from the interpreter's own output tensor
    // shape at runtime rather than hardcoding either). Not assumed to
    // beat YOLOv8n or any other candidate — that's what the weighted
    // comparison report is for.
    BenchmarkModelSpec(
      displayName: 'YOLO11n',
      modelAssetPath: 'assets/ml_models/benchmark_candidates/yolo11n.tflite',
      labelsAssetPath: 'assets/ml_models/benchmark_candidates/yolo11n_labels.txt',
      inputSize: 640,
      outputFormat: ModelOutputFormat.yoloSingleTensorNoNms,
      publishedSizeNote: '~5.4 MB (float export)',
      publishedMapNote: '~39 COCO mAP (official Ultralytics figure, per community-reported '
          'export logs — not independently verified by this project)',
    ),
  ];
}
