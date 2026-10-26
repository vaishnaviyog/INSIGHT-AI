import 'dart:typed_data';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../config/object_priority_config.dart';
import '../../config/research_tools_config.dart';
import '../../models/detected_hazard.dart';
import 'distance_estimator.dart';
import 'hazard_detector.dart';
import 'letterbox_transform.dart';
import 'yolo_label_config.dart';

/// Every check [YoloTfliteHazardDetector.initialize] performs, in
/// order — added per the explicit "detector self-test" requirement:
/// the app should know exactly WHICH step failed, not just a bare
/// true/false [YoloTfliteHazardDetector.isAvailable].
enum YoloDetectorCheck {
  modelFileFound,
  modelLoaded,
  labelFileFound,
  labelsLoaded,
  inputShapeValid,
  outputShapeValid,
  inferenceReady,
}

/// Result of every [YoloDetectorCheck], plus a human-readable summary
/// — read by [YoloTfliteHazardDetector.health] any time, not only
/// right after [YoloTfliteHazardDetector.initialize] returns.
class YoloDetectorHealth {
  final Map<YoloDetectorCheck, bool> checks;
  final String? failureReason;

  const YoloDetectorHealth({required this.checks, this.failureReason});

  bool get allPassed => checks.values.every((v) => v);

  /// The [YoloDetectorCheck.inferenceReady] status is derived FROM
  /// these six prerequisites — it must never appear on its own right
  /// side (that was the P0-1 bug: `checks.values.every(...)` included
  /// [YoloDetectorCheck.inferenceReady] itself, which is still false
  /// at the point of computing it, making the result permanently
  /// unsatisfiable). Kept as a pure static function — no Interpreter,
  /// no asset loading — specifically so this exact formula is
  /// unit-testable without a TFLite runtime; see
  /// `yolo_detector_health_test.dart`.
  static const List<YoloDetectorCheck> prerequisiteChecks = [
    YoloDetectorCheck.modelFileFound,
    YoloDetectorCheck.modelLoaded,
    YoloDetectorCheck.labelFileFound,
    YoloDetectorCheck.labelsLoaded,
    YoloDetectorCheck.inputShapeValid,
    YoloDetectorCheck.outputShapeValid,
  ];

  static bool computeInferenceReady(Map<YoloDetectorCheck, bool> checks, String? failureReason) {
    final allPrerequisitesPassed = prerequisiteChecks.every((c) => checks[c] == true);
    return allPrerequisitesPassed && failureReason == null;
  }

  /// "YOLO object detection unavailable: <reason>" once any check
  /// fails — the exact spoken/logged form the explicit requirement
  /// asks for ("Do NOT silently return zero detections" without
  /// telling anyone why).
  String get statusMessage =>
      allPassed ? 'YOLO object detection ready.' : 'YOLO object detection unavailable: ${failureReason ?? 'unknown failure'}';
}

/// Hazard detector backed by a YOLOv8n model, exported to TFLite,
/// run via `tflite_flutter` — REPLACES `CocoTfliteHazardDetector` (deleted) as
/// the production detection backend (see that class and
/// `assets/ml_models/README.md` for why it's retired, not deleted:
/// it remains a valid, independent "current baseline" candidate in
/// `ModelBenchmarkService`/`BenchmarkModelSpec`, which is intentionally
/// decoupled from the production pipeline).
///
/// WHY THIS ISN'T A NEW, SEPARATE OUTPUT-DECODE INVENTION: YOLOv8's
/// TFLite export shape and decode requirements were already
/// discovered, implemented, and exercised by
/// `ModelBenchmarkService._runYoloStyle` when the vision-module
/// benchmark harness evaluated YOLOv8n as a replacement candidate.
/// This class reuses that exact decode algorithm (argmax-per-box class
/// scoring, confidence filtering, greedy per-class IoU NMS) — extended
/// to keep full box geometry + class index (the benchmark version only
/// needed a `Set<String>` of labels present, for ground-truth
/// matching; production needs the actual [DetectedHazard] objects).
///
/// READS ACTUAL MODEL METADATA AT RUNTIME, PER EXPLICIT REQUIREMENT:
/// input width/height, input dtype (uint8 vs float32), and the output
/// tensor's own shape are all read from the loaded [Interpreter] in
/// [initialize]/[detect] — NONE of these are hardcoded/assumed, unlike
/// `CocoTfliteHazardDetector` (deleted)'s fixed 300×300 uint8 assumption (safe
/// there only because that specific legacy model family is always
/// exported that one way).
///
/// *** CRITICAL OPERATIONAL NOTE, CARRIED FORWARD *** — MODEL FILE NOT
/// BUNDLED: this repository does not contain
/// `assets/ml_models/yolov8n.tflite` (a binary model file; not
/// committed to source control, same reasoning as the retired SSD
/// model — see `assets/ml_models/README.md`). Until it's added,
/// [initialize] fails soft, [isAvailable] stays false, and — like the
/// detector it replaces — THERE IS NO FALLBACK: object detection
/// produces nothing at all until the file is present. See [health]
/// for exactly which check is failing.
class YoloTfliteHazardDetector implements IHazardDetector {
  static const String _modelAssetPath = 'assets/ml_models/yolov8n.tflite';
  static const String _labelsAssetPath = 'assets/ml_models/yolov8n_labels.txt';

  /// The pixel space [DistanceEstimationConfig.focalLengthPixels] was
  /// (un)calibrated against — the RETIRED SSD detector's 300×300 model
  /// input. This detector's own model input is a DIFFERENT resolution
  /// (read from the model itself, typically 640×640 for YOLOv8n — see
  /// [_inputWidth]/[_inputHeight]), so a raw YOLO bounding-box pixel
  /// height CANNOT be passed to [DistanceEstimationConfig.estimateDistanceMeters]
  /// directly: focal length in pixels scales with image resolution, so
  /// doing that would silently under/over-estimate every distance by
  /// roughly (actual input size / 300). Every box height is instead
  /// converted to a FRACTION of the frame first (already computed for
  /// the UI overlay anyway) and re-expressed in THIS reference space —
  /// `heightFraction * _distanceCalibrationReferenceSize` — before
  /// calling the shared distance formula, exactly reproducing what the
  /// SSD detector implicitly did by using its own native 300px input
  /// as both its model input AND its calibration reference. This keeps
  /// [DistanceEstimationConfig]'s existing (documented-uncalibrated)
  /// constant meaningful without changing that shared file at all.
  static const double _distanceCalibrationReferenceSize = 300.0;

  // PHASE C1 (vision-latency fix, interpreter execution performance
  // ONLY — model/tensor pipeline/decision logic untouched): the
  // interpreter was previously created via `Interpreter.fromAsset(path)`
  // with NO `InterpreterOptions` at all, which defaults to a single
  // CPU thread. Measured on-device (OPPO CPH2421, MediaTek mt6762),
  // mean YOLO inference time (T2->T3), 10-13 cycles per configuration:
  //   1 thread (previous default): ~3.04s  (~1 of 8 CPU cores used)
  //   threads = 2:                 ~2.48s
  //   threads = 4:                 ~1.82s  <- fastest measured, SELECTED
  //   threads = 6:                 ~1.94s  (worse than 4 — diminishing/
  //                                 reversing returns past 4 on this chip)
  //   NNAPI delegate:               ABANDONED — Interpreter.fromAsset()
  //                                 throws "Invalid argument(s): Unable
  //                                 to create interpreter." on this
  //                                 device. Fails cleanly (detector
  //                                 correctly reports itself
  //                                 unavailable, no crash) but unusable.
  //   GPU delegate (GpuDelegateV2): ABANDONED — identical failure mode
  //                                 to NNAPI on this device.
  // threads=4 is therefore the selected, final configuration — chosen
  // from measured on-device results, not assumed.
  static const int _interpreterThreadCount = 4;

  Interpreter? _interpreter;
  List<String> _labels = [];
  bool _isAvailable = false;
  bool _isBusy = false;
  int _inputWidth = 0;
  int _inputHeight = 0;
  bool _isQuantizedUint8 = false;

  // AUDIT ADD (int8 support — see assets/ml_models/README.md's "Supported
  // dtypes" note this replaces): a fully-integer-quantized TFLite export
  // (Ultralytics `int8=True`) typically produces BOTH an int8 input tensor
  // AND an int8 output tensor, each with its OWN scale/zero-point pair —
  // these are two independent affine mappings, not a shared constant, and
  // must be read from each tensor's own `params` at initialize() time, not
  // assumed equal to each other or hardcoded. Previously any int8 tensor
  // was rejected outright (see the removed health-check failure below);
  // this is the "real additional work this pass didn't have room to build
  // and verify without a device" that comment referred to.
  bool _isQuantizedInt8 = false;
  double _inputScale = 1.0;
  int _inputZeroPoint = 0;
  bool _outputIsQuantized = false;
  bool _outputIsInt8 = false; // false means uint8, when _outputIsQuantized
  double _outputScale = 1.0;
  int _outputZeroPoint = 0;

  YoloDetectorHealth _health = const YoloDetectorHealth(
    checks: {
      YoloDetectorCheck.modelFileFound: false,
      YoloDetectorCheck.modelLoaded: false,
      YoloDetectorCheck.labelFileFound: false,
      YoloDetectorCheck.labelsLoaded: false,
      YoloDetectorCheck.inputShapeValid: false,
      YoloDetectorCheck.outputShapeValid: false,
      YoloDetectorCheck.inferenceReady: false,
    },
    failureReason: 'initialize() has not run yet.',
  );

  /// Full self-test result — see [YoloDetectorCheck] for exactly what
  /// each entry means. Read this (not just [isAvailable]) to show a
  /// user/developer WHICH step is failing, per the explicit "detector
  /// health check" requirement.
  YoloDetectorHealth get health => _health;

  @override
  String get name => 'yolov8n_tflite';

  @override
  bool get isAvailable => _isAvailable;

  @override
  Future<void> initialize() async {
    final checks = <YoloDetectorCheck, bool>{
      for (final c in YoloDetectorCheck.values) c: false,
    };
    String? failureReason;

    try {
      // Asset existence is only truly confirmed by successfully
      // loading it — Flutter's asset bundle has no separate "does
      // this path exist" probe — so modelFileFound/modelLoaded are
      // necessarily verified together below, same convention
      // CocoTfliteHazardDetector already used.
      _interpreter = await Interpreter.fromAsset(
        _modelAssetPath,
        options: InterpreterOptions()..threads = _interpreterThreadCount,
      );
      checks[YoloDetectorCheck.modelFileFound] = true;
      checks[YoloDetectorCheck.modelLoaded] = true;

      final labelData = await rootBundle.loadString(_labelsAssetPath);
      checks[YoloDetectorCheck.labelFileFound] = true;
      _labels = labelData.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (_labels.isEmpty) {
        failureReason = 'Label file $_labelsAssetPath loaded but contained no labels.';
      } else {
        checks[YoloDetectorCheck.labelsLoaded] = true;
      }

      // READ ACTUAL MODEL METADATA — do not assume shape (explicit
      // requirement). Expected: input [1, height, width, 3].
      final inputTensor = _interpreter!.getInputTensors().first;
      final inputShape = inputTensor.shape;
      if (inputShape.length == 4 && inputShape[1] > 0 && inputShape[2] > 0 && inputShape[3] == 3) {
        // AUDIT FIX (int8 support): a fully-integer-quantized export's
        // input tensor is signed int8 (-128..127), a genuinely different
        // encoding from uint8's 0..255 — now handled properly by reading
        // the tensor's own [scale, zeroPoint] (`inputTensor.params`) and
        // re-quantizing each normalized pixel value against them at
        // detect()-time (see `_imageToInt8Bytes`/`_quantizeInt8`), rather
        // than being rejected or silently mishandled as float32.
        _inputHeight = inputShape[1];
        _inputWidth = inputShape[2];
        _isQuantizedUint8 = inputTensor.type == TensorType.uint8;
        _isQuantizedInt8 = inputTensor.type == TensorType.int8;
        if (_isQuantizedInt8) {
          final params = inputTensor.params;
          _inputScale = params.scale;
          _inputZeroPoint = params.zeroPoint;
        }
        checks[YoloDetectorCheck.inputShapeValid] = true;
      } else {
        failureReason = 'Unexpected input tensor shape $inputShape (expected [1, height, width, 3]).';
      }

      // Expected: output [1, 4+numClasses, numBoxes] — the
      // single-tensor, no-built-in-NMS YOLOv8 export layout (see
      // ModelOutputFormat.yoloSingleTensorNoNms's doc comment).
      final outputTensor = _interpreter!.getOutputTensors().first;
      final outputShape = outputTensor.shape;
      if (outputShape.length == 3 && outputShape[1] > 4 && outputShape[2] > 0) {
        checks[YoloDetectorCheck.outputShapeValid] = true;
        // AUDIT ADD (int8 support): a fully-integer-quantized export
        // typically quantizes the OUTPUT tensor too (its own independent
        // [scale, zeroPoint] pair, not the input's) — confidence scores
        // and box coordinates arrive as raw int8/uint8 and must be
        // dequantized back to real float values before the existing
        // argmax/NMS decode logic (written against float32 semantics)
        // can run against them unchanged.
        _outputIsQuantized = outputTensor.type == TensorType.int8 || outputTensor.type == TensorType.uint8;
        _outputIsInt8 = outputTensor.type == TensorType.int8;
        if (_outputIsQuantized) {
          final params = outputTensor.params;
          _outputScale = params.scale;
          _outputZeroPoint = params.zeroPoint;
        }
      } else {
        failureReason ??= 'Unexpected output tensor shape $outputShape '
            '(expected [1, 4+numClasses, numBoxes] — got rank ${outputShape.length}).';
      }

      // AUDIT FIX (P0-1): see YoloDetectorHealth.computeInferenceReady's
      // doc comment for why this must be a pure function of the SIX
      // prerequisite checks, never of `checks` as a whole.
      checks[YoloDetectorCheck.inferenceReady] =
          YoloDetectorHealth.computeInferenceReady(checks, failureReason);
      _isAvailable = checks[YoloDetectorCheck.inferenceReady]!;
      _health = YoloDetectorHealth(checks: checks, failureReason: _isAvailable ? null : failureReason);

      final inputDtypeLabel = _isQuantizedInt8 ? 'int8' : (_isQuantizedUint8 ? 'uint8' : 'float32');
      final outputDtypeLabel =
          _outputIsQuantized ? (_outputIsInt8 ? 'int8' : 'uint8') : 'float32';
      // ignore: avoid_print
      print(_isAvailable
          ? 'YoloTfliteHazardDetector ready: input=${_inputWidth}x$_inputHeight '
              'inputDtype=$inputDtypeLabel outputDtype=$outputDtypeLabel labels=${_labels.length}'
          : 'YoloTfliteHazardDetector NOT ready: ${_health.statusMessage}');
    } catch (e) {
      // Model/labels not bundled yet, or failed to load — fail soft,
      // same IHazardDetector contract CocoTfliteHazardDetector used.
      failureReason = 'Exception during initialize(): $e';
      _health = YoloDetectorHealth(checks: checks, failureReason: failureReason);
      _isAvailable = false;
      // ignore: avoid_print
      print('YoloTfliteHazardDetector unavailable: $failureReason');
    }
  }

  @override
  Future<List<DetectedHazard>> detect(CameraImage image, int sensorOrientation) async {
    if (!_isAvailable || _isBusy || _interpreter == null) return [];
    _isBusy = true;
    // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T1 =
    // preprocessing begins. Safe to remove after this phase.
    logLatency('T1_preprocessBegin=${DateTime.now().toIso8601String()}');

    try {
      final rgbImage = _convertCameraImageToRgb(image, sensorOrientation);
      if (rgbImage == null) return [];
      // PHASE C4 TEMPORARY DIAGNOSTIC (fresh device latency breakdown —
      // additive only, no detection logic/threshold changed): T1a =
      // camera-frame-to-RGB conversion finished.
      logLatency('T1a_conversionEnd=${DateTime.now().toIso8601String()}');

      // AUDIT FIX (BLOCKER 10 — real letterboxing, not a stretch):
      // previously `img.copyResize(rgbImage, width: _inputWidth,
      // height: _inputHeight)` directly — which STRETCHES the frame
      // to the model's aspect ratio whenever it doesn't match the
      // camera's own (the normal case), distorting every object's
      // apparent proportions and, concretely, this app's own
      // height-based distance estimate. `LetterboxTransform` (a pure,
      // separately-tested class — see letterbox_transform.dart)
      // computes the fit-inside scale + centered padding; the scaled
      // image is pasted onto a fixed grey (114,114,114 — Ultralytics'
      // own standard letterbox padding color) canvas of exactly
      // `_inputWidth`x`_inputHeight` before being fed to the model.
      final letterbox = LetterboxTransform.compute(
        originalWidth: rgbImage.width,
        originalHeight: rgbImage.height,
        targetWidth: _inputWidth,
        targetHeight: _inputHeight,
      );
      final scaledImage = img.copyResize(rgbImage, width: letterbox.scaledWidth, height: letterbox.scaledHeight);
      final paddedCanvas = img.Image(width: _inputWidth, height: _inputHeight);
      // AUDIT FIX (real-device validation phase — measured bottleneck):
      // previously `img.fill(paddedCanvas, ...)` colored the ENTIRE
      // `_inputWidth`x`_inputHeight` canvas grey before `compositeImage`
      // immediately overwrote the whole content region with
      // `scaledImage` — every pixel under that overwritten region was
      // filled for nothing. Fresh on-device measurement (OPPO CPH2421,
      // MediaTek mt6762/6765, 55 real detection cycles) found this
      // fill+composite step averaging ~579ms, the single largest
      // non-inference cost in the pipeline (larger than YUV->RGB
      // conversion). `LetterboxTransform`'s "fit inside" scale always
      // leaves padding on at most one axis at a time (the other side's
      // scaled dimension exactly fills the canvas) — so only the actual
      // padding bars need the grey fill; the content rectangle is
      // always fully overwritten by `compositeImage` below regardless
      // of what was there before. This produces a BYTE-IDENTICAL final
      // image (verified by the existing letterbox/detector tests, which
      // assert on decoded output, not on how the canvas was built) —
      // nothing about detection, confidence, NMS, or decision logic
      // changed. Both axes are still filled defensively (not just
      // whichever LetterboxTransform is expected to use) in case a
      // future caller ever produces a non-degenerate transform with
      // padding on both axes.
      final padXPx = letterbox.padX.round();
      final padYPx = letterbox.padY.round();
      final letterboxGrey = img.ColorRgb8(114, 114, 114);
      if (padXPx > 0) {
        img.fillRect(paddedCanvas, x1: 0, y1: 0, x2: padXPx - 1, y2: _inputHeight - 1, color: letterboxGrey);
        img.fillRect(paddedCanvas,
            x1: _inputWidth - padXPx, y1: 0, x2: _inputWidth - 1, y2: _inputHeight - 1, color: letterboxGrey);
      }
      if (padYPx > 0) {
        img.fillRect(paddedCanvas, x1: 0, y1: 0, x2: _inputWidth - 1, y2: padYPx - 1, color: letterboxGrey);
        img.fillRect(paddedCanvas,
            x1: 0, y1: _inputHeight - padYPx, x2: _inputWidth - 1, y2: _inputHeight - 1, color: letterboxGrey);
      }
      img.compositeImage(
        paddedCanvas,
        scaledImage,
        dstX: padXPx,
        dstY: padYPx,
      );
      // PHASE C4 TEMPORARY DIAGNOSTIC: T1b = letterbox resize/pad
      // finished, tensor-byte conversion (T1b -> T2) is next.
      logLatency('T1b_letterboxEnd=${DateTime.now().toIso8601String()}');

      // AUDIT FIX (Phase B — "Node number 0 (PAD) failed to prepare"
      // root cause): a bare `Float32List` passed here is NOT safe —
      // traced into `tflite_flutter`'s own source
      // (`Tensor.getInputShapeIfDifferent`, tensor.dart): it special-cases
      // `Uint8List`/`ByteBuffer` to skip its shape check entirely, but
      // for anything else (including `Float32List`, which IS a `List`)
      // it calls `computeShapeOf`, which treats a FLAT typed list as a
      // 1-D array and infers a WRONG shape (e.g. `[1228800]` for a
      // 640x640x3 input, instead of the tensor's real `[1,640,640,3]`).
      // That wrong shape then triggers `resizeInputTensor` on EVERY
      // single call — but the package's `runInference` never resets
      // `_allocated` to `false` after a resize, so the next `invoke()`
      // runs against a graph that was never re-prepared for the new
      // (wrong) shape, and the first shape-dependent op (Node 0, PAD)
      // fails to prepare — every single frame, which is exactly the
      // observed ~1.2-1.4s-interval continuous failure (one per
      // detection attempt, not a retry timer or repeated
      // initialization — confirmed no other code path calls
      // `initialize()`/`Interpreter.fromAsset()` more than once).
      // FIX: pass the underlying `ByteBuffer` instead of the flat
      // typed list — `ByteConversionUtils.convertObjectToBytes` reads
      // a `ByteBuffer`'s raw bytes directly (`o.asUint8List()`),
      // byte-identical to what the flat-list path would have produced,
      // while taking the SAME safe early-return `getInputShapeIfDifferent`
      // already gives `Uint8List`/`ByteBuffer` — no resize is ever
      // triggered, so the interpreter's one-time `allocateTensors()`
      // (done in its constructor) remains valid for every subsequent
      // `invoke()`, exactly as a correctly-prepared graph should behave.
      // The uint8 branch was never affected by this bug (`Uint8List`
      // already hits that early return) — wrapped in `.buffer` too only
      // for consistency, not because it was broken.
      final Object input = _isQuantizedInt8
          ? _imageToInt8Bytes(paddedCanvas).buffer
          : (_isQuantizedUint8
              ? _imageToUint8Bytes(paddedCanvas).buffer
              : _imageToFloat32Bytes(paddedCanvas).buffer);

      // Output shape read fresh each call (cheap — already validated
      // once in initialize(), re-read here defensively rather than
      // cached, in case a future interpreter reload ever changes it).
      final outputShape = _interpreter!.getOutputTensors().first.shape; // [1, channels, numBoxes]
      final channels = outputShape[1];
      final numBoxes = outputShape[2];
      final numClasses = channels - 4;

      final output = List.generate(1, (_) => List.generate(channels, (_) => List.filled(numBoxes, 0.0)));
      // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T2 =
      // YOLO inference begins. Safe to remove after this phase.
      logLatency('T2_inferenceBegin=${DateTime.now().toIso8601String()}');
      if (_outputIsQuantized) {
        // AUDIT ADD (int8 support): run into a flat raw buffer matching
        // the quantized tensor's actual byte layout (tflite_flutter's
        // Tensor.copyTo special-cases Uint8List/ByteBuffer destinations
        // to a raw byte copy — see tensor.dart — so this is the correct
        // way to retrieve unconverted quantized output), then dequantize
        // every element with THIS tensor's own [scale, zeroPoint] (never
        // the input tensor's — they are independent) into the same
        // nested double `output` structure the unchanged decode logic
        // below already expects, so nothing past this point needs to
        // know the model was quantized at all.
        final totalElements = channels * numBoxes;
        final raw = _outputIsInt8 ? Int8List(totalElements) : Uint8List(totalElements);
        _interpreter!.run(input, raw.buffer);
        int idx = 0;
        for (int c = 0; c < channels; c++) {
          for (int i = 0; i < numBoxes; i++) {
            output[0][c][i] = (raw[idx] - _outputZeroPoint) * _outputScale;
            idx++;
          }
        }
      } else {
        _interpreter!.run(input, output);
      }
      logLatency('T3_inferenceEnd=${DateTime.now().toIso8601String()}');

      // --- Decode: argmax-per-box class scoring + confidence filter
      // (same algorithm as ModelBenchmarkService._runYoloStyle) -------
      final candidates = <List<double>>[]; // [cx, cy, w, h, score, classIndex]
      for (int i = 0; i < numBoxes; i++) {
        double bestScore = 0;
        int bestClass = -1;
        for (int c = 0; c < numClasses; c++) {
          final score = output[0][4 + c][i];
          if (score > bestScore) {
            bestScore = score;
            bestClass = c;
          }
        }
        if (bestScore >= YoloLabelConfig.confidenceThreshold && bestClass >= 0) {
          candidates.add([output[0][0][i], output[0][1][i], output[0][2][i], output[0][3][i], bestScore, bestClass.toDouble()]);
        }
      }
      // PHASE C4 TEMPORARY DIAGNOSTIC: T3a = argmax-per-box decode +
      // confidence filter finished, NMS (T3a -> T3b) is next.
      logLatency('T3a_decodeEnd=${DateTime.now().toIso8601String()} candidates=${candidates.length}');

      // --- Greedy per-class NMS (same algorithm/threshold already
      // proven in the benchmark harness for this exact model family) --
      candidates.sort((a, b) => b[4].compareTo(a[4]));
      final kept = <List<double>>[];
      for (final candidate in candidates) {
        bool overlaps = false;
        for (final k in kept) {
          if (candidate[5] == k[5] && _iou(candidate, k) > YoloLabelConfig.nmsIouThreshold) {
            overlaps = true;
            break;
          }
        }
        if (!overlaps) kept.add(candidate);
      }
      // PHASE C4 TEMPORARY DIAGNOSTIC: T3b = NMS finished, coordinate
      // mapping + distance estimation (T3b -> T4) is next.
      logLatency('T3b_nmsEnd=${DateTime.now().toIso8601String()} kept=${kept.length}');

      // --- Coordinate-space normalization ------------------------------
      // Ultralytics' TFLite export normalizes box coordinates to 0..1
      // of the model's own input for the standard float export; some
      // export variants instead emit raw pixel coordinates relative to
      // the input size. CANNOT BE VERIFIED FROM THIS ENVIRONMENT (no
      // TFLite runtime available here — see this class's "model not
      // bundled" note) — this defends against BOTH cases rather than
      // assuming one: if the largest coordinate among kept boxes is
      // clearly outside the 0..1 range, every box is treated as
      // pixel-space and divided by the input dimensions first. VERIFY
      // ON A REAL DEVICE once the model file is added — see
      // assets/ml_models/README.md.
      final looksPixelSpace = kept.any((b) => b[0] > 1.5 || b[1] > 1.5 || b[2] > 1.5 || b[3] > 1.5);

      final results = <DetectedHazard>[];
      for (final box in kept) {
        final classIndex = box[5].toInt();
        if (classIndex < 0 || classIndex >= _labels.length) continue;
        final label = _labels[classIndex].toLowerCase();
        final priority = YoloLabelConfig.hazardPriorities[label];
        if (priority == null) continue; // not in the navigation-hazard allowlist

        // AUDIT FIX (BLOCKER 10): box coordinates are in MODEL-CANVAS
        // space (the padded _inputWidth x _inputHeight canvas) — they
        // must go through the SAME LetterboxTransform, in reverse, to
        // land back in the ORIGINAL camera frame's fractional
        // coordinates. Previously this simply divided by
        // _inputWidth/_inputHeight directly, which was only correct
        // because the image had been stretched to exactly that
        // rectangle with no padding — now that the model input is a
        // real letterboxed canvas, that shortcut would silently
        // misplace every box within the padding bars.
        double cxModelPx = box[0], cyModelPx = box[1], wModelPx = box[2], hModelPx = box[3];
        if (!looksPixelSpace) {
          // Normalized 0..1 of the model canvas — convert to model
          // canvas PIXELS first, since LetterboxTransform's inverse
          // mapping operates in pixel space (it needs to subtract a
          // pixel-valued padY/padX before dividing by scale).
          cxModelPx *= _inputWidth;
          cyModelPx *= _inputHeight;
          wModelPx *= _inputWidth;
          hModelPx *= _inputHeight;
        }
        final leftModelPx = cxModelPx - wModelPx / 2;
        final topModelPx = cyModelPx - hModelPx / 2;

        final originalFractionRect = letterbox.mapModelPixelBoxToOriginalFraction(
          left: leftModelPx,
          top: topModelPx,
          width: wModelPx,
          height: hModelPx,
        );
        final leftF = originalFractionRect.left;
        final topF = originalFractionRect.top;
        final boxWidthF = originalFractionRect.width;
        final boxHeightF = originalFractionRect.height;

        // See _distanceCalibrationReferenceSize's doc comment: convert
        // to the SAME reference pixel space DistanceEstimationConfig
        // was (un)calibrated against, not this model's own native
        // input size.
        final boxHeightCalibrationPixels = boxHeightF * _distanceCalibrationReferenceSize;
        final estimatedDistance = DistanceEstimationConfig.estimateDistanceMeters(label, boxHeightCalibrationPixels);

        final areaFraction = boxWidthF * boxHeightF;
        final distanceBand = estimatedDistance != null
            ? DistanceEstimationConfig.distanceBandForMeters(estimatedDistance)
            : ObjectPriorityConfig.distanceBandFor(areaFraction);

        final centerXFraction = leftF + (boxWidthF / 2);
        final horizontalPosition = centerXFraction < 0.4
            ? HorizontalPosition.left
            : centerXFraction > 0.6
                ? HorizontalPosition.right
                : HorizontalPosition.center;

        results.add(DetectedHazard(
          label: label,
          priority: priority,
          confidence: box[4],
          distanceBand: distanceBand,
          sourceDetector: name,
          boundingBox: Rect.fromLTWH(leftF, topF, boxWidthF, boxHeightF),
          estimatedDistanceMeters: estimatedDistance,
          horizontalPosition: horizontalPosition,
        ));
      }

      results.sort((a, b) {
        final byPriority = a.priority.index.compareTo(b.priority.index);
        if (byPriority != 0) return byPriority;
        return b.confidence.compareTo(a.confidence);
      });

      // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T4 =
      // detection accepted (confidence/allowlist-filtered, decoded,
      // NMS'd). Safe to remove after this phase.
      logLatency('T4_detectionAccepted=${DateTime.now().toIso8601String()} count=${results.length}');
      return results;
    } catch (e) {
      // ignore: avoid_print
      print('YoloTfliteHazardDetector error: $e');
      return [];
    } finally {
      _isBusy = false;
    }
  }

  /// Standard center-form IoU — identical to
  /// `ModelBenchmarkService._iou`, reused here rather than
  /// reimplemented differently.
  double _iou(List<double> a, List<double> b) {
    final aLeft = a[0] - a[2] / 2, aRight = a[0] + a[2] / 2;
    final aTop = a[1] - a[3] / 2, aBottom = a[1] + a[3] / 2;
    final bLeft = b[0] - b[2] / 2, bRight = b[0] + b[2] / 2;
    final bTop = b[1] - b[3] / 2, bBottom = b[1] + b[3] / 2;

    final interLeft = aLeft > bLeft ? aLeft : bLeft;
    final interTop = aTop > bTop ? aTop : bTop;
    final interRight = aRight < bRight ? aRight : bRight;
    final interBottom = aBottom < bBottom ? aBottom : bBottom;

    final interWidth = (interRight - interLeft).clamp(0, double.infinity);
    final interHeight = (interBottom - interTop).clamp(0, double.infinity);
    final interArea = interWidth * interHeight;

    final aArea = a[2] * a[3];
    final bArea = b[2] * b[3];
    final unionArea = aArea + bArea - interArea;
    return unionArea <= 0 ? 0 : interArea / unionArea;
  }

  // --- Camera-frame conversion — a self-contained copy of the same
  // logic in CocoTfliteHazardDetector/ModelBenchmarkService, matching
  // this project's existing convention of NOT sharing this via a
  // common import across detector implementations (see
  // ModelBenchmarkService's own doc comment on why it keeps its own
  // copy too). A future refactor could centralize this; not done here
  // to keep this migration scoped to the detection backend itself. ---

  img.Image? _convertCameraImageToRgb(CameraImage image, int sensorOrientation) {
    try {
      // AUDIT FIX (P0-2): branch on the image's OWN reported format
      // rather than assuming Android always means one specific byte
      // layout. The previous code called a YUV_420_888-shaped 3-plane
      // decoder unconditionally on Android while the camera was
      // actually configured for `nv21` — a real byte-layout mismatch,
      // and, since `nv21` frames are frequently NOT delivered as 3
      // separate planes, a potential `RangeError` on `image.planes[2]`
      // rather than merely wrong colors. `navigation_screen.dart` now
      // requests `ImageFormatGroup.yuv420` on Android (see that file's
      // comment), but this still branches explicitly rather than
      // assuming — correct behavior if that ever changes, and
      // correct behavior for `bgra8888` (iOS) either way.
      img.Image converted;
      switch (image.format.group) {
        case ImageFormatGroup.yuv420:
          converted = _yuv420ToImage(image);
          break;
        case ImageFormatGroup.nv21:
          converted = _nv21ToImage(image);
          break;
        case ImageFormatGroup.bgra8888:
          converted = _bgra8888ToImage(image);
          break;
        default:
          // ignore: avoid_print
          print('YoloTfliteHazardDetector: unsupported camera image format ${image.format.group} '
              '(raw=${image.format.raw}) — skipping this frame rather than guessing a byte layout.');
          return null;
      }
      if (sensorOrientation == 90) converted = img.copyRotate(converted, angle: 90);
      if (sensorOrientation == 180) converted = img.copyRotate(converted, angle: 180);
      if (sensorOrientation == 270) converted = img.copyRotate(converted, angle: 270);
      return converted;
    } catch (e) {
      // ignore: avoid_print
      print('YoloTfliteHazardDetector: image conversion failed: $e');
      return null;
    }
  }

  /// Converts a standard 3-plane YUV_420_888 [CameraImage] (Y, U, V —
  /// U/V possibly sub-sampled with their own row stride and pixel
  /// stride, per the plane metadata the platform actually reports).
  /// Requested via `ImageFormatGroup.yuv420` — see
  /// `navigation_screen.dart`'s camera initialization.
  img.Image _yuv420ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final out = img.Image(width: width, height: height);
    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yRowStride + x;
        final uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;
        final yValue = yPlane.bytes[yIndex];
        final uValue = uPlane.bytes[uvIndex];
        final vValue = vPlane.bytes[uvIndex];
        final r = (yValue + 1.402 * (vValue - 128)).clamp(0, 255).toInt();
        final g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).clamp(0, 255).toInt();
        final b = (yValue + 1.772 * (uValue - 128)).clamp(0, 255).toInt();
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  /// Converts an NV21 [CameraImage] — Y plane followed by a SINGLE
  /// interleaved VU plane (V, U, V, U, ... — note the V-before-U
  /// order, which is what makes NV21 different from NV12/standard
  /// planar YUV420). Handles BOTH shapes the `camera` plugin has been
  /// observed to deliver for this format group across versions:
  /// a single combined plane (`image.planes.length == 1`, containing
  /// the full Y+VU buffer back to back) and a 2-plane split (Y, then
  /// interleaved VU as its own plane). NOT exercised by this app's
  /// default camera configuration (which now requests `yuv420` — see
  /// `navigation_screen.dart`) but implemented for real, not stubbed,
  /// per the explicit requirement to support this format defensively.
  /// *** UNVERIFIED ON A REAL DEVICE — no camera hardware/plugin
  /// runtime available in the environment this was written in; the
  /// two-shapes handling above is based on documented/observed
  /// `camera` plugin behavior, not something this environment could
  /// execute and confirm. ***
  img.Image _nv21ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final out = img.Image(width: width, height: height);

    final yPlane = image.planes[0];
    final yRowStride = yPlane.bytesPerRow;

    late final Uint8List vuBytes;
    late final int vuRowStride;
    if (image.planes.length >= 2) {
      final vuPlane = image.planes[1];
      vuBytes = vuPlane.bytes;
      vuRowStride = vuPlane.bytesPerRow;
    } else {
      // Single combined buffer: VU immediately follows the full Y
      // plane, and — per NV21's definition — is tightly packed at
      // `width` bytes per chroma row (2 bytes per chroma sample pair,
      // width/2 sample pairs per row).
      vuBytes = yPlane.bytes;
      vuRowStride = width;
    }
    final yBytes = yPlane.bytes;
    final vuByteOffset = image.planes.length >= 2 ? 0 : width * height;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yRowStride + x;
        // V then U, interleaved, 2 bytes per chroma sample pair.
        final vuIndex = vuByteOffset + (y ~/ 2) * vuRowStride + (x ~/ 2) * 2;
        if (yIndex >= yBytes.length || vuIndex + 1 >= vuBytes.length) continue;
        final yValue = yBytes[yIndex];
        final vValue = vuBytes[vuIndex];
        final uValue = vuBytes[vuIndex + 1];
        final r = (yValue + 1.402 * (vValue - 128)).clamp(0, 255).toInt();
        final g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128)).clamp(0, 255).toInt();
        final b = (yValue + 1.772 * (uValue - 128)).clamp(0, 255).toInt();
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  img.Image _bgra8888ToImage(CameraImage image) {
    final width = image.width;
    final height = image.height;
    final plane = image.planes[0];
    final out = img.Image(width: width, height: height);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final index = y * plane.bytesPerRow + x * 4;
        final b = plane.bytes[index];
        final g = plane.bytes[index + 1];
        final r = plane.bytes[index + 2];
        out.setPixelRgb(x, y, r, g, b);
      }
    }
    return out;
  }

  Uint8List _imageToUint8Bytes(img.Image image) {
    final bytes = Uint8List(_inputWidth * _inputHeight * 3);
    int i = 0;
    for (int y = 0; y < _inputHeight; y++) {
      for (int x = 0; x < _inputWidth; x++) {
        final pixel = image.getPixel(x, y);
        bytes[i++] = pixel.r.toInt();
        bytes[i++] = pixel.g.toInt();
        bytes[i++] = pixel.b.toInt();
      }
    }
    return bytes;
  }

  Float32List _imageToFloat32Bytes(img.Image image) {
    final floats = Float32List(_inputWidth * _inputHeight * 3);
    int i = 0;
    for (int y = 0; y < _inputHeight; y++) {
      for (int x = 0; x < _inputWidth; x++) {
        final pixel = image.getPixel(x, y);
        floats[i++] = pixel.r / 255.0;
        floats[i++] = pixel.g / 255.0;
        floats[i++] = pixel.b / 255.0;
      }
    }
    return floats;
  }

  /// AUDIT ADD (int8 support): quantizes each pixel channel (normalized
  /// to 0..1, same convention [_imageToFloat32Bytes] uses) against THIS
  /// model's own input [_inputScale]/[_inputZeroPoint] — read once in
  /// [initialize] from `inputTensor.params`, never hardcoded, since a
  /// different export/calibration run produces different values. The
  /// standard TFLite affine quantization formula:
  /// `quantized = round(real / scale) + zeroPoint`, clamped to int8's
  /// representable range.
  Int8List _imageToInt8Bytes(img.Image image) {
    final bytes = Int8List(_inputWidth * _inputHeight * 3);
    int i = 0;
    for (int y = 0; y < _inputHeight; y++) {
      for (int x = 0; x < _inputWidth; x++) {
        final pixel = image.getPixel(x, y);
        bytes[i++] = _quantizeInt8(pixel.r / 255.0);
        bytes[i++] = _quantizeInt8(pixel.g / 255.0);
        bytes[i++] = _quantizeInt8(pixel.b / 255.0);
      }
    }
    return bytes;
  }

  int _quantizeInt8(double normalizedValue) {
    final quantized = (normalizedValue / _inputScale).round() + _inputZeroPoint;
    return quantized.clamp(-128, 127);
  }

  @override
  void dispose() {
    _interpreter?.close();
    _isAvailable = false;
  }
}
