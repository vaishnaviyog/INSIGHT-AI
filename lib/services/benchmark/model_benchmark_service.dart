import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../models/benchmark_result.dart';
import 'benchmark_model_spec.dart';
import 'device_fingerprint_service.dart';
import 'hazard_label_canonicalizer.dart';
import 'native_metrics_channel.dart';

/// Runs ONE (candidate model x delegate) combination and returns a
/// measured [ModelBenchmarkResult] — never a guessed or literature-
/// sourced one. Two entry points:
///
/// - [runQuickBenchmark]: tens of iterations — FPS/latency/memory/CPU,
///   plus (on the CPU-delegate row, if the frame burst was annotated)
///   detection precision/recall/FP/FN, detection stability, and
///   time-to-warning.
/// - [runContinuousEnduranceTest]: a genuinely long, continuous run
///   (target: minutes, e.g. 15) for real battery-percentage drain and
///   thermal-throttling observation — the two things a short pass
///   cannot show.
///
/// DELIBERATELY SEPARATE FROM `IHazardDetector`/`HazardDetectionService`:
/// this is measurement-only scaffolding for deciding which model to
/// promote to a real detector next — see `BenchmarkModelSpec`'s doc
/// comment. Nothing here is wired into the live navigation pipeline;
/// the production detector is not touched until the comparison report
/// (see `BenchmarkComparisonService`) recommends a winner from
/// measured data.
class ModelBenchmarkService {
  Future<ModelBenchmarkResult> runQuickBenchmark({
    required BenchmarkModelSpec spec,
    required InferenceDelegate delegate,
    required List<CameraImage> sampleFrames,
    required int sensorOrientation,
    required DeviceFingerprint device,
    List<Set<String>>? groundTruthByFrameIndex,
    int warmupIterations = 5,
    int timedIterations = 30,
  }) async {
    final timestamp = DateTime.now();
    final loaded = await _loadForRun(spec: spec, delegate: delegate);
    if (loaded.failureReason != null) {
      return _failure(spec, delegate, BenchmarkTestMode.quick, loaded.failureReason!, device, timestamp,
          iterationsRequested: timedIterations);
    }
    final interpreter = loaded.interpreter!;
    final gpuDelegate = loaded.gpuDelegate;
    final labels = loaded.labels!;
    final isQuantizedUint8 = loaded.isQuantizedUint8;

    try {
      if (groundTruthByFrameIndex != null && groundTruthByFrameIndex.length != sampleFrames.length) {
        return _failure(
            spec,
            delegate,
            BenchmarkTestMode.quick,
            'Ground truth list length (${groundTruthByFrameIndex.length}) does not match '
                'sample frame count (${sampleFrames.length}).',
            device,
            timestamp,
            iterationsRequested: timedIterations);
      }

      int frameCursor = 0;
      for (int i = 0; i < warmupIterations; i++) {
        _runOneFrame(interpreter, spec, sampleFrames[frameCursor % sampleFrames.length], sensorOrientation,
            isQuantizedUint8, labels);
        frameCursor++;
      }

      final heapBefore = await NativeMetricsChannel.readNativeHeapBytes();
      final cpuTimeBefore = await NativeMetricsChannel.readProcessCpuTimeMs();
      final wallBefore = await NativeMetricsChannel.readElapsedRealtimeMs();
      final coreCount = await NativeMetricsChannel.readCpuCoreCount();
      final thermalBefore = await NativeMetricsChannel.readThermalStatus();
      final thermalHeadroomBefore = await NativeMetricsChannel.readThermalHeadroom();

      final latenciesMs = <double>[];
      final batterySamples = <int>[];
      int completed = 0;
      for (int i = 0; i < timedIterations; i++) {
        final frame = sampleFrames[frameCursor % sampleFrames.length];
        frameCursor++;
        final stopwatch = Stopwatch()..start();
        final detected =
            _runOneFrame(interpreter, spec, frame, sensorOrientation, isQuantizedUint8, labels);
        stopwatch.stop();
        if (detected == null) continue;
        latenciesMs.add(stopwatch.elapsedMicroseconds / 1000.0);
        completed++;
        if (i % 5 == 0) {
          final sample = await NativeMetricsChannel.readBatteryCurrentNowMicroAmps();
          if (sample != null) batterySamples.add(sample);
        }
      }

      if (latenciesMs.isEmpty) {
        return _failure(spec, delegate, BenchmarkTestMode.quick,
            'Every timed iteration failed (conversion or inference error) — see logs.', device, timestamp,
            iterationsRequested: timedIterations, iterationsCompleted: completed);
      }

      final heapAfter = await NativeMetricsChannel.readNativeHeapBytes();
      final cpuTimeAfter = await NativeMetricsChannel.readProcessCpuTimeMs();
      final wallAfter = await NativeMetricsChannel.readElapsedRealtimeMs();
      final thermalAfter = await NativeMetricsChannel.readThermalStatus();
      final thermalHeadroomAfter = await NativeMetricsChannel.readThermalHeadroom();

      latenciesMs.sort();
      final mean = latenciesMs.reduce((a, b) => a + b) / latenciesMs.length;

      // --- Detection quality / stability / time-to-warning: CPU row only,
      // and only if ground truth was supplied — a SEQUENTIAL, single
      // pass over the ORIGINAL frame order (not cycled), since
      // stability/time-to-warning are meaningless without real
      // temporal order. ---------------------------------------------------
      int? tp, fp, fn;
      double? precision, recall, stability, timeToWarning;
      Map<String, Map<String, int>>? perClassBreakdown;
      String? qualityNote;

      if (groundTruthByFrameIndex != null) {
        if (delegate != InferenceDelegate.cpu) {
          qualityNote = 'Detection quality/stability/time-to-warning are only evaluated on the '
              'CPU-delegate row for this model — see that row.';
        } else {
          final sequential = _runSequentialPass(
              interpreter, spec, sampleFrames, sensorOrientation, isQuantizedUint8, labels);
          final quality = _scoreDetectionQuality(sequential.detectedByFrame, groundTruthByFrameIndex);
          tp = quality.tp;
          fp = quality.fp;
          fn = quality.fn;
          precision = quality.precision;
          recall = quality.recall;
          perClassBreakdown = quality.perClass;
          stability = _scoreStability(sequential.detectedByFrame, groundTruthByFrameIndex);
          timeToWarning = _scoreTimeToWarning(
              sequential.detectedByFrame, groundTruthByFrameIndex, sequential.latenciesMs);
          qualityNote = 'Frame-level class-presence proxy over ${sampleFrames.length} annotated frames — '
              'not IoU-matched mAP. Time-to-warning is inference-side only (excludes '
              "HazardDetectionService's 300ms min-interval throttle and TTS speak() latency, "
              'both separate in production) — see ModelBenchmarkResult class doc.';
        }
      }

      final apkSizeEstimate = await _estimateApkSizeIncreaseBytes(spec);

      return ModelBenchmarkResult(
        modelName: spec.displayName,
        modelAssetPath: spec.modelAssetPath,
        delegate: delegate,
        testMode: BenchmarkTestMode.quick,
        succeeded: true,
        iterationsCompleted: completed,
        iterationsRequested: timedIterations,
        meanLatencyMs: mean,
        medianLatencyMs: _percentile(latenciesMs, 0.50),
        p90LatencyMs: _percentile(latenciesMs, 0.90),
        minLatencyMs: latenciesMs.first,
        maxLatencyMs: latenciesMs.last,
        estimatedFps: mean > 0 ? 1000.0 / mean : null,
        nativeHeapDeltaBytes:
            (heapBefore != null && heapAfter != null) ? heapAfter - heapBefore : null,
        cpuUsagePercentOfOneCore: _cpuPercent(cpuTimeBefore, cpuTimeAfter, wallBefore, wallAfter),
        cpuCoreCount: coreCount,
        avgBatteryCurrentMicroAmps:
            batterySamples.isEmpty ? null : batterySamples.reduce((a, b) => a + b) / batterySamples.length,
        thermalStatusBefore: thermalBefore,
        thermalStatusAfter: thermalAfter,
        thermalStatusPeak: _maxNullable(thermalBefore, thermalAfter),
        thermalHeadroomBefore: thermalHeadroomBefore,
        thermalHeadroomAfter: thermalHeadroomAfter,
        truePositives: tp,
        falsePositives: fp,
        falseNegatives: fn,
        precision: precision,
        recall: recall,
        perClassBreakdown: perClassBreakdown,
        detectionStabilityScore: stability,
        meanTimeToWarningMs: timeToWarning,
        detectionQualityNote: qualityNote,
        estimatedApkSizeIncreaseBytes: apkSizeEstimate,
        deviceModel: device.model,
        deviceManufacturer: device.manufacturer,
        androidRelease: device.androidRelease,
        androidSdkInt: device.androidSdkInt,
        chipsetHardware: device.hardware,
        timestamp: timestamp,
      );
    } finally {
      interpreter.close();
      gpuDelegate?.delete();
    }
  }

  /// A genuinely long, continuous run — target duration, not a fixed
  /// iteration count — used specifically for real battery-percentage
  /// drain and thermal-throttling observation. Runs inference back to
  /// back at maximum rate for [targetDuration] (default 15 minutes),
  /// sampling battery percentage/current and thermal status
  /// periodically throughout, not just before/after, so a mid-run
  /// spike is never hidden by a recovered final reading.
  ///
  /// Deliberately a SEPARATE, explicit action in the UI rather than
  /// folded into the quick pass's loop — a real 15-minute run per
  /// candidate/delegate combination is a genuine time cost (12
  /// combinations x 15 minutes = 3 hours), so this should be run
  /// intentionally per combination you actually want sustained data
  /// for, not automatically multiplied across every selection.
  Future<ModelBenchmarkResult> runContinuousEnduranceTest({
    required BenchmarkModelSpec spec,
    required InferenceDelegate delegate,
    required List<CameraImage> sampleFrames,
    required int sensorOrientation,
    required DeviceFingerprint device,
    Duration targetDuration = const Duration(minutes: 15),
    void Function(Duration elapsed, Duration remaining)? onProgress,
  }) async {
    final timestamp = DateTime.now();
    final loaded = await _loadForRun(spec: spec, delegate: delegate);
    if (loaded.failureReason != null) {
      return _failure(spec, delegate, BenchmarkTestMode.continuousEndurance, loaded.failureReason!, device,
          timestamp,
          iterationsRequested: 0);
    }
    final interpreter = loaded.interpreter!;
    final gpuDelegate = loaded.gpuDelegate;
    final labels = loaded.labels!;
    final isQuantizedUint8 = loaded.isQuantizedUint8;

    try {
      final batteryPercentBefore = await NativeMetricsChannel.readBatteryPercentage();
      final thermalBefore = await NativeMetricsChannel.readThermalStatus();
      final thermalHeadroomBefore = await NativeMetricsChannel.readThermalHeadroom();
      final runStart = DateTime.now();

      final latenciesMs = <double>[];
      final batteryCurrentSamples = <int>[];
      int? thermalPeak = thermalBefore;
      int completed = 0;
      int frameCursor = 0;
      int iterationIndex = 0;

      while (DateTime.now().difference(runStart) < targetDuration) {
        final frame = sampleFrames[frameCursor % sampleFrames.length];
        frameCursor++;
        final stopwatch = Stopwatch()..start();
        final detected =
            _runOneFrame(interpreter, spec, frame, sensorOrientation, isQuantizedUint8, labels);
        stopwatch.stop();
        if (detected != null) {
          latenciesMs.add(stopwatch.elapsedMicroseconds / 1000.0);
          completed++;
        }
        iterationIndex++;

        // Sample roughly once every 10 seconds of wall time rather
        // than every N iterations — iteration duration varies wildly
        // across candidates (a slow model would otherwise sample far
        // less often per minute than a fast one).
        if (iterationIndex % 20 == 0) {
          final currentSample = await NativeMetricsChannel.readBatteryCurrentNowMicroAmps();
          if (currentSample != null) batteryCurrentSamples.add(currentSample);
          final thermalNow = await NativeMetricsChannel.readThermalStatus();
          if (thermalNow != null) thermalPeak = _maxNullable(thermalPeak, thermalNow) ?? thermalNow;
          onProgress?.call(DateTime.now().difference(runStart), targetDuration - DateTime.now().difference(runStart));
        }
      }

      final elapsed = DateTime.now().difference(runStart);
      final batteryPercentAfter = await NativeMetricsChannel.readBatteryPercentage();
      final thermalAfter = await NativeMetricsChannel.readThermalStatus();
      final thermalHeadroomAfter = await NativeMetricsChannel.readThermalHeadroom();

      final apkSizeEstimate = await _estimateApkSizeIncreaseBytes(spec);

      if (latenciesMs.isEmpty) {
        return _failure(spec, delegate, BenchmarkTestMode.continuousEndurance,
            'No iteration completed during the endurance window — see logs.', device, timestamp,
            iterationsRequested: 0, iterationsCompleted: 0);
      }

      latenciesMs.sort();
      final mean = latenciesMs.reduce((a, b) => a + b) / latenciesMs.length;

      return ModelBenchmarkResult(
        modelName: spec.displayName,
        modelAssetPath: spec.modelAssetPath,
        delegate: delegate,
        testMode: BenchmarkTestMode.continuousEndurance,
        succeeded: true,
        iterationsCompleted: completed,
        iterationsRequested: completed, // duration-driven, not a preset target
        meanLatencyMs: mean,
        medianLatencyMs: _percentile(latenciesMs, 0.50),
        p90LatencyMs: _percentile(latenciesMs, 0.90),
        minLatencyMs: latenciesMs.first,
        maxLatencyMs: latenciesMs.last,
        estimatedFps: mean > 0 ? 1000.0 / mean : null,
        avgBatteryCurrentMicroAmps: batteryCurrentSamples.isEmpty
            ? null
            : batteryCurrentSamples.reduce((a, b) => a + b) / batteryCurrentSamples.length,
        batteryPercentBefore: batteryPercentBefore,
        batteryPercentAfter: batteryPercentAfter,
        batteryPercentDrop: (batteryPercentBefore != null && batteryPercentAfter != null)
            ? batteryPercentBefore - batteryPercentAfter
            : null,
        testDurationSeconds: elapsed.inSeconds,
        thermalStatusBefore: thermalBefore,
        thermalStatusAfter: thermalAfter,
        thermalStatusPeak: thermalPeak,
        thermalHeadroomBefore: thermalHeadroomBefore,
        thermalHeadroomAfter: thermalHeadroomAfter,
        estimatedApkSizeIncreaseBytes: apkSizeEstimate,
        deviceModel: device.model,
        deviceManufacturer: device.manufacturer,
        androidRelease: device.androidRelease,
        androidSdkInt: device.androidSdkInt,
        chipsetHardware: device.hardware,
        timestamp: timestamp,
      );
    } finally {
      interpreter.close();
      gpuDelegate?.delete();
    }
  }

  // ---------------------------------------------------------------------
  // Shared setup
  // ---------------------------------------------------------------------

  Future<_LoadedModel> _loadForRun({
    required BenchmarkModelSpec spec,
    required InferenceDelegate delegate,
  }) async {
    List<String> labels;
    try {
      await rootBundle.load(spec.modelAssetPath);
      final labelData = await rootBundle.loadString(spec.labelsAssetPath);
      labels = labelData.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    } catch (e) {
      return _LoadedModel.failed('Model or labels asset not found (${spec.modelAssetPath} / '
          '${spec.labelsAssetPath}) — see assets/ml_models/README.md for what to download and '
          'where to place it.');
    }

    final options = InterpreterOptions();
    GpuDelegateV2? gpuDelegate;
    switch (delegate) {
      case InferenceDelegate.cpu:
        break;
      case InferenceDelegate.nnapi:
        if (!Platform.isAndroid) return _LoadedModel.failed('NNAPI delegate is Android-only.');
        options.useNnApiForAndroid = true;
        break;
      case InferenceDelegate.gpu:
        if (!Platform.isAndroid) {
          return _LoadedModel.failed('GPU delegate benchmarking is currently implemented for Android only.');
        }
        try {
          gpuDelegate = GpuDelegateV2();
          options.addDelegate(gpuDelegate);
        } catch (e) {
          return _LoadedModel.failed('GPU delegate failed to initialize on this device/model: $e');
        }
        break;
    }

    try {
      final interpreter = await Interpreter.fromAsset(spec.modelAssetPath, options: options);
      final isQuantizedUint8 = _InputQuantization.fromTensor(interpreter.getInputTensors().first);
      return _LoadedModel(interpreter: interpreter, gpuDelegate: gpuDelegate, labels: labels, isQuantizedUint8: isQuantizedUint8);
    } catch (e) {
      return _LoadedModel.failed('Interpreter failed to load with delegate ${delegate.name}: $e');
    }
  }

  ModelBenchmarkResult _failure(
    BenchmarkModelSpec spec,
    InferenceDelegate delegate,
    BenchmarkTestMode mode,
    String reason,
    DeviceFingerprint device,
    DateTime timestamp, {
    int iterationsCompleted = 0,
    required int iterationsRequested,
  }) =>
      ModelBenchmarkResult(
        modelName: spec.displayName,
        modelAssetPath: spec.modelAssetPath,
        delegate: delegate,
        testMode: mode,
        succeeded: false,
        iterationsCompleted: iterationsCompleted,
        iterationsRequested: iterationsRequested,
        deviceModel: device.model,
        deviceManufacturer: device.manufacturer,
        androidRelease: device.androidRelease,
        androidSdkInt: device.androidSdkInt,
        chipsetHardware: device.hardware,
        timestamp: timestamp,
        failureReason: reason,
      );

  /// Sum of this candidate's own bundled asset byte sizes — a close
  /// proxy for its APK size contribution, not an exact `--analyze-size`
  /// delta (Android's own compression/alignment isn't observable from
  /// inside a running app) — see [ModelBenchmarkResult.estimatedApkSizeIncreaseBytes]'s
  /// doc comment.
  Future<int?> _estimateApkSizeIncreaseBytes(BenchmarkModelSpec spec) async {
    try {
      final modelBytes = (await rootBundle.load(spec.modelAssetPath)).lengthInBytes;
      final labelBytes = (await rootBundle.load(spec.labelsAssetPath)).lengthInBytes;
      return modelBytes + labelBytes;
    } catch (e) {
      return null;
    }
  }

  double? _cpuPercent(int? cpuBefore, int? cpuAfter, int? wallBefore, int? wallAfter) {
    if (cpuBefore == null || cpuAfter == null || wallBefore == null || wallAfter == null) return null;
    final wallDelta = wallAfter - wallBefore;
    if (wallDelta <= 0) return null;
    return ((cpuAfter - cpuBefore) / wallDelta) * 100.0;
  }

  int? _maxNullable(int? a, int? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a > b ? a : b;
  }

  double _percentile(List<double> sortedAscending, double fraction) {
    if (sortedAscending.isEmpty) return 0;
    final index = ((sortedAscending.length - 1) * fraction).round();
    return sortedAscending[index];
  }

  // ---------------------------------------------------------------------
  // Sequential pass (for stability + time-to-warning) — original frame
  // order preserved, run exactly once.
  // ---------------------------------------------------------------------

  _SequentialPassResult _runSequentialPass(
    Interpreter interpreter,
    BenchmarkModelSpec spec,
    List<CameraImage> sampleFrames,
    int sensorOrientation,
    _InputQuantization isQuantizedUint8,
    List<String> labels,
  ) {
    final detectedByFrame = <Set<String>>[];
    final latenciesMs = <double>[];
    for (final frame in sampleFrames) {
      final stopwatch = Stopwatch()..start();
      final detected =
          _runOneFrame(interpreter, spec, frame, sensorOrientation, isQuantizedUint8, labels);
      stopwatch.stop();
      detectedByFrame.add(detected ?? <String>{});
      latenciesMs.add(stopwatch.elapsedMicroseconds / 1000.0);
    }
    return _SequentialPassResult(detectedByFrame: detectedByFrame, latenciesMs: latenciesMs);
  }

  _QualityScore _scoreDetectionQuality(
    List<Set<String>> detectedByFrame,
    List<Set<String>> groundTruthByFrameIndex,
  ) {
    final perClass = <String, Map<String, int>>{
      for (final c in HazardLabelCanonicalizer.canonicalClasses) c: {'tp': 0, 'fp': 0, 'fn': 0},
    };
    for (int f = 0; f < detectedByFrame.length; f++) {
      final detected = detectedByFrame[f];
      final truth = groundTruthByFrameIndex[f];
      for (final c in HazardLabelCanonicalizer.canonicalClasses) {
        final wasDetected = detected.contains(c);
        final wasPresent = truth.contains(c);
        if (wasDetected && wasPresent) {
          perClass[c]!['tp'] = perClass[c]!['tp']! + 1;
        } else if (wasDetected && !wasPresent) {
          perClass[c]!['fp'] = perClass[c]!['fp']! + 1;
        } else if (!wasDetected && wasPresent) {
          perClass[c]!['fn'] = perClass[c]!['fn']! + 1;
        }
      }
    }
    final tp = perClass.values.fold(0, (sum, m) => sum + m['tp']!);
    final fp = perClass.values.fold(0, (sum, m) => sum + m['fp']!);
    final fn = perClass.values.fold(0, (sum, m) => sum + m['fn']!);
    return _QualityScore(
      tp: tp,
      fp: fp,
      fn: fn,
      precision: (tp + fp) > 0 ? tp / (tp + fp) : null,
      recall: (tp + fn) > 0 ? tp / (tp + fn) : null,
      perClass: perClass,
    );
  }

  /// For each class present in ground truth in at least one frame,
  /// finds every maximal contiguous run where it's genuinely present
  /// and counts detected/not-detected FLIPS within that run — a class
  /// detected consistently across a present-run scores 1.0 for that
  /// run; one that flickers on/off scores lower. Classes never present
  /// in this burst are excluded from the average rather than penalized.
  double? _scoreStability(List<Set<String>> detectedByFrame, List<Set<String>> groundTruth) {
    final classScores = <double>[];
    for (final c in HazardLabelCanonicalizer.canonicalClasses) {
      int runStart = -1;
      final runs = <List<int>>[]; // [start, endInclusive]
      for (int f = 0; f < groundTruth.length; f++) {
        final present = groundTruth[f].contains(c);
        if (present && runStart == -1) runStart = f;
        if (!present && runStart != -1) {
          runs.add([runStart, f - 1]);
          runStart = -1;
        }
      }
      if (runStart != -1) runs.add([runStart, groundTruth.length - 1]);
      if (runs.isEmpty) continue; // never present in this burst — not scored

      for (final run in runs) {
        final start = run[0], end = run[1];
        if (end == start) {
          classScores.add(1.0); // single-frame run, no transition possible
          continue;
        }
        int flips = 0;
        for (int f = start + 1; f <= end; f++) {
          if (detectedByFrame[f].contains(c) != detectedByFrame[f - 1].contains(c)) flips++;
        }
        final maxPossibleFlips = end - start;
        classScores.add(1.0 - (flips / maxPossibleFlips));
      }
    }
    if (classScores.isEmpty) return null;
    return classScores.reduce((a, b) => a + b) / classScores.length;
  }

  /// For each class, from the start of its first present-run, finds
  /// the earliest point at which it has been DETECTED for 3
  /// consecutive frames — mirroring production `HazardTemporalFilter`'s
  /// confirmation rule — and sums the per-frame processing latency
  /// from appearance to confirmation. Averaged across classes that
  /// reached confirmation within the burst; a class that never
  /// confirms is excluded, not penalized with an arbitrary large value.
  double? _scoreTimeToWarning(
    List<Set<String>> detectedByFrame,
    List<Set<String>> groundTruth,
    List<double> latenciesMs,
  ) {
    final timings = <double>[];
    for (final c in HazardLabelCanonicalizer.canonicalClasses) {
      int? firstPresent;
      for (int f = 0; f < groundTruth.length; f++) {
        if (groundTruth[f].contains(c)) {
          firstPresent = f;
          break;
        }
      }
      if (firstPresent == null) continue; // never present in this burst

      int consecutive = 0;
      int? confirmedAt;
      for (int f = firstPresent; f < detectedByFrame.length; f++) {
        consecutive = detectedByFrame[f].contains(c) ? consecutive + 1 : 0;
        if (consecutive >= 3) {
          confirmedAt = f;
          break;
        }
      }
      if (confirmedAt == null) continue; // never confirmed within the burst

      double cumulative = 0;
      for (int f = firstPresent; f <= confirmedAt; f++) {
        cumulative += latenciesMs[f];
      }
      timings.add(cumulative);
    }
    if (timings.isEmpty) return null;
    return timings.reduce((a, b) => a + b) / timings.length;
  }

  // ---------------------------------------------------------------------
  // Per-frame inference (shared by both quick and endurance passes)
  // ---------------------------------------------------------------------

  Set<String>? _runOneFrame(
    Interpreter interpreter,
    BenchmarkModelSpec spec,
    CameraImage image,
    int sensorOrientation,
    _InputQuantization isQuantizedUint8,
    List<String> labels,
  ) {
    try {
      final rgb = _convertCameraImageToRgb(image, sensorOrientation);
      if (rgb == null) return null;
      final resized = img.copyResize(rgb, width: spec.inputSize, height: spec.inputSize);
      final input = isQuantizedUint8.isInt8
          ? _imageToInt8Bytes(resized, isQuantizedUint8)
          : (isQuantizedUint8.isUint8 ? _imageToUint8Bytes(resized) : _imageToFloat32Bytes(resized));

      switch (spec.outputFormat) {
        case ModelOutputFormat.ssdFourTensor:
        case ModelOutputFormat.efficientDetFourTensor:
          return _runSsdStyle(interpreter, input, spec, labels);
        case ModelOutputFormat.yoloSingleTensorNoNms:
          return _runYoloStyle(interpreter, input, spec, labels);
      }
    } catch (e) {
      // ignore: avoid_print
      print('ModelBenchmarkService: frame failed for ${spec.displayName}: $e');
      return null;
    }
  }

  Set<String> _runSsdStyle(Interpreter interpreter, Object input, BenchmarkModelSpec spec, List<String> labels) {
    const maxDetections = 10;
    final outputLocations =
        List.generate(1, (_) => List.generate(maxDetections, (_) => List.filled(4, 0.0)));
    final outputClasses = List.generate(1, (_) => List.filled(maxDetections, 0.0));
    final outputScores = List.generate(1, (_) => List.filled(maxDetections, 0.0));
    final outputCount = List.filled(1, 0.0);

    interpreter.runForMultipleInputs([input], {
      0: outputLocations,
      1: outputClasses,
      2: outputScores,
      3: outputCount,
    });

    final detectionCount = outputCount[0].round().clamp(0, maxDetections);
    final detected = <String>{};
    for (int i = 0; i < detectionCount; i++) {
      final score = outputScores[0][i];
      if (score < spec.confidenceThreshold) continue;
      final labelIndex = outputClasses[0][i].round() + spec.labelIndexOffset;
      if (labelIndex < 0 || labelIndex >= labels.length) continue;
      final canonical = HazardLabelCanonicalizer.canonicalize(labels[labelIndex]);
      if (canonical != null) detected.add(canonical);
    }
    return detected;
  }

  Set<String> _runYoloStyle(Interpreter interpreter, Object input, BenchmarkModelSpec spec, List<String> labels) {
    final outputTensor = interpreter.getOutputTensors().first;
    final shape = outputTensor.shape; // [1, 4+numClasses, numBoxes]
    final channels = shape[1];
    final numBoxes = shape[2];
    final numClasses = channels - 4;

    final output = List.generate(1, (_) => List.generate(channels, (_) => List.filled(numBoxes, 0.0)));
    // AUDIT ADD (int8 support): a fully-integer-quantized export's output
    // tensor is typically ALSO int8/uint8 with its own independent
    // [scale, zeroPoint] (never the input tensor's) — read directly from
    // `outputTensor` (already in scope above) and dequantized into the
    // same nested-double `output` the unchanged decode logic below
    // expects, same approach as `YoloTfliteHazardDetector`.
    if (outputTensor.type == TensorType.int8 || outputTensor.type == TensorType.uint8) {
      final params = outputTensor.params;
      final totalElements = channels * numBoxes;
      final raw =
          outputTensor.type == TensorType.int8 ? Int8List(totalElements) : Uint8List(totalElements);
      interpreter.run(input, raw.buffer);
      int idx = 0;
      for (int c = 0; c < channels; c++) {
        for (int i = 0; i < numBoxes; i++) {
          output[0][c][i] = (raw[idx] - params.zeroPoint) * params.scale;
          idx++;
        }
      }
    } else {
      interpreter.run(input, output);
    }

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
      if (bestScore >= spec.confidenceThreshold && bestClass >= 0) {
        candidates.add([
          output[0][0][i],
          output[0][1][i],
          output[0][2][i],
          output[0][3][i],
          bestScore,
          bestClass.toDouble(),
        ]);
      }
    }

    candidates.sort((a, b) => b[4].compareTo(a[4]));
    final kept = <List<double>>[];
    for (final candidate in candidates) {
      bool overlaps = false;
      for (final k in kept) {
        if (candidate[5] == k[5] && _iou(candidate, k) > 0.45) {
          overlaps = true;
          break;
        }
      }
      if (!overlaps) kept.add(candidate);
    }

    final detected = <String>{};
    for (final box in kept) {
      final classIndex = box[5].toInt();
      if (classIndex < 0 || classIndex >= labels.length) continue;
      final canonical = HazardLabelCanonicalizer.canonicalize(labels[classIndex]);
      if (canonical != null) detected.add(canonical);
    }
    return detected;
  }

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

  // --- Shared camera-frame conversion, intentionally a self-contained
  // copy of the logic in CocoTfliteHazardDetector rather than a shared
  // import: this benchmark module must stay fully decoupled from the
  // production detector. ------------------------------------------------

  img.Image? _convertCameraImageToRgb(CameraImage image, int sensorOrientation) {
    try {
      img.Image converted = Platform.isAndroid ? _yuv420ToImage(image) : _bgra8888ToImage(image);
      if (sensorOrientation == 90) converted = img.copyRotate(converted, angle: 90);
      if (sensorOrientation == 180) converted = img.copyRotate(converted, angle: 180);
      if (sensorOrientation == 270) converted = img.copyRotate(converted, angle: 270);
      return converted;
    } catch (e) {
      return null;
    }
  }

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
    final size = image.width;
    final bytes = Uint8List(size * size * 3);
    int i = 0;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final pixel = image.getPixel(x, y);
        bytes[i++] = pixel.r.toInt();
        bytes[i++] = pixel.g.toInt();
        bytes[i++] = pixel.b.toInt();
      }
    }
    return bytes;
  }

  /// AUDIT ADD (int8 support) — mirrors
  /// `YoloTfliteHazardDetector._imageToInt8Bytes`: quantizes each
  /// normalized (0..1) pixel channel against `quant`'s `[scale,
  /// zeroPoint]`, read from the model's own input tensor, never assumed.
  Int8List _imageToInt8Bytes(img.Image image, _InputQuantization quant) {
    final size = image.width;
    final bytes = Int8List(size * size * 3);
    int i = 0;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final pixel = image.getPixel(x, y);
        bytes[i++] = _quantizeInt8(pixel.r / 255.0, quant);
        bytes[i++] = _quantizeInt8(pixel.g / 255.0, quant);
        bytes[i++] = _quantizeInt8(pixel.b / 255.0, quant);
      }
    }
    return bytes;
  }

  int _quantizeInt8(double normalizedValue, _InputQuantization quant) {
    final quantized = (normalizedValue / quant.scale).round() + quant.zeroPoint;
    return quantized.clamp(-128, 127);
  }

  Float32List _imageToFloat32Bytes(img.Image image) {
    final size = image.width;
    final floats = Float32List(size * size * 3);
    int i = 0;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final pixel = image.getPixel(x, y);
        floats[i++] = pixel.r / 255.0;
        floats[i++] = pixel.g / 255.0;
        floats[i++] = pixel.b / 255.0;
      }
    }
    return floats;
  }
}

class _LoadedModel {
  final Interpreter? interpreter;
  final GpuDelegateV2? gpuDelegate;
  final List<String>? labels;
  final _InputQuantization isQuantizedUint8;
  final String? failureReason;

  _LoadedModel({
    required this.interpreter,
    required this.gpuDelegate,
    required this.labels,
    required this.isQuantizedUint8,
  }) : failureReason = null;

  _LoadedModel.failed(this.failureReason)
      : interpreter = null,
        gpuDelegate = null,
        labels = null,
        isQuantizedUint8 = const _InputQuantization.float32();
}

/// AUDIT ADD (int8 support — mirrors the identical fix in the production
/// detector, `YoloTfliteHazardDetector`): replaces a bare `bool
/// isQuantizedUint8` with a type that can ALSO represent int8, carrying
/// that tensor's own `[scale, zeroPoint]` — a fully-integer-quantized
/// export's input tensor is signed int8 with its own affine mapping, a
/// genuinely different encoding from uint8's 0..255 raw bytes, and
/// previously would have been silently (and incorrectly) treated as the
/// float32 path by `== TensorType.uint8`'s false result.
class _InputQuantization {
  final bool isUint8;
  final bool isInt8;
  final double scale;
  final int zeroPoint;

  const _InputQuantization.float32()
      : isUint8 = false,
        isInt8 = false,
        scale = 1.0,
        zeroPoint = 0;

  const _InputQuantization.uint8()
      : isUint8 = true,
        isInt8 = false,
        scale = 1.0,
        zeroPoint = 0;

  _InputQuantization.int8(this.scale, this.zeroPoint)
      : isUint8 = false,
        isInt8 = true;

  factory _InputQuantization.fromTensor(Tensor tensor) {
    if (tensor.type == TensorType.int8) {
      final params = tensor.params;
      return _InputQuantization.int8(params.scale, params.zeroPoint);
    }
    if (tensor.type == TensorType.uint8) {
      return const _InputQuantization.uint8();
    }
    return const _InputQuantization.float32();
  }
}

class _SequentialPassResult {
  final List<Set<String>> detectedByFrame;
  final List<double> latenciesMs;
  _SequentialPassResult({required this.detectedByFrame, required this.latenciesMs});
}

class _QualityScore {
  final int tp, fp, fn;
  final double? precision, recall;
  final Map<String, Map<String, int>> perClass;
  _QualityScore({
    required this.tp,
    required this.fp,
    required this.fn,
    required this.precision,
    required this.recall,
    required this.perClass,
  });
}
