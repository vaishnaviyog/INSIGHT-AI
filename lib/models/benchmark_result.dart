import 'dart:convert';

/// Which inference backend a benchmark run used. Mirrors the real
/// delegate options `tflite_flutter` exposes on Android — deliberately
/// NOT collapsed into a single "accelerated: bool" flag, because
/// published literature (and this project's own audit) shows NNAPI
/// does not uniformly help: it can slow inference down, or fail to
/// initialize at all, depending on chipset and model. Each delegate
/// gets its own measured row rather than assuming any one of them
/// wins in general.
enum InferenceDelegate { cpu, nnapi, gpu }

/// Which pass produced this row — kept explicit rather than inferred
/// from iteration count, so the comparison report and CSV consumers
/// never have to guess whether a row's battery/thermal numbers came
/// from a real sustained window.
enum BenchmarkTestMode {
  /// Short pass (tens of iterations): FPS/latency/memory/CPU, plus
  /// detection quality and time-to-warning if the frame burst was
  /// annotated. Battery/thermal fields are still populated but are
  /// too short a window to show real drain/throttling — see
  /// `ModelBenchmarkResult`'s doc comment.
  quick,

  /// A genuinely long, continuous run (target: 15 minutes) used
  /// specifically to measure battery percentage drop and thermal
  /// throttling under sustained load — see
  /// `ModelBenchmarkService.runContinuousEnduranceTest`.
  continuousEndurance,
}

/// One (candidate model x delegate x device x test mode) benchmark
/// row — the atomic unit the research framework's comparison report
/// aggregates and ranks.
///
/// DETECTION-QUALITY AND STABILITY FIELDS ARE ONLY EVER POPULATED ON
/// THE [InferenceDelegate.cpu] ROW FOR A GIVEN MODEL, deliberately —
/// detection *output* is delegate-invariant for correctness purposes
/// (NNAPI/GPU change speed, not what's detected), so this harness
/// measures each candidate MODEL's detection quality once, against
/// ground truth you annotate, using the one delegate guaranteed to be
/// available everywhere. The nnapi/gpu rows for the same model leave
/// these fields null and carry a [detectionQualityNote] pointing back
/// to the CPU row.
class ModelBenchmarkResult {
  final String modelName;
  final String modelAssetPath;
  final InferenceDelegate delegate;
  final BenchmarkTestMode testMode;

  /// True only if the interpreter (and delegate, if any) initialized
  /// AND every timed iteration completed without throwing. A `false`
  /// row still gets exported — "this model/delegate combo doesn't
  /// work on this device" is itself a real, useful data point.
  final bool succeeded;

  // --- Speed --------------------------------------------------------
  final double? meanLatencyMs;
  final double? medianLatencyMs;
  final double? p90LatencyMs;
  final double? minLatencyMs;
  final double? maxLatencyMs;
  final double? estimatedFps;

  // --- Memory ---------------------------------------------------------
  final int? nativeHeapDeltaBytes;

  // --- CPU ------------------------------------------------------------
  /// Normalized to "percent of one core" (100 = one core fully busy).
  final double? cpuUsagePercentOfOneCore;
  final int? cpuCoreCount;

  // --- Battery: instantaneous (every pass) -----------------------------
  /// Mean of several `BATTERY_PROPERTY_CURRENT_NOW` samples during the
  /// run, in microamps. Sign is manufacturer-dependent — reported as-is.
  final double? avgBatteryCurrentMicroAmps;

  // --- Battery: sustained drain (continuousEndurance mode only) --------
  final int? batteryPercentBefore;
  final int? batteryPercentAfter;
  final int? batteryPercentDrop; // before - after; null if either sample failed
  final int? testDurationSeconds;

  // --- Thermal ------------------------------------------------------------
  /// `PowerManager` thermal status (0=NONE..6=SHUTDOWN). Null on
  /// Android < 10. [thermalStatusPeak] is the worst value observed at
  /// ANY sample point during the run (periodic sampling in
  /// continuousEndurance mode), not just the final reading — a run
  /// that spikes to SEVERE mid-way and recovers by the end would
  /// otherwise hide that spike if only before/after were kept.
  final int? thermalStatusBefore;
  final int? thermalStatusAfter;
  final int? thermalStatusPeak;
  final double? thermalHeadroomBefore;
  final double? thermalHeadroomAfter;

  // --- Detection quality (CPU-delegate row only; see class doc) --------
  /// Frame-level, class-presence proxy — NOT IoU-matched mAP. See
  /// `HazardLabelCanonicalizer`'s doc comment for the class-vocabulary
  /// side of the same honesty requirement.
  final int? truePositives;
  final int? falsePositives;
  final int? falseNegatives;
  final double? precision; // TP / (TP + FP)
  final double? recall; // TP / (TP + FN)
  final Map<String, Map<String, int>>? perClassBreakdown;

  // --- Detection stability (CPU-delegate row only) ---------------------
  /// Fraction of ground-truth-present classes that, across the ORIGINAL
  /// temporal order of the captured frame burst, detect without
  /// flickering (no detected -> not-detected -> detected transitions
  /// while the class remains genuinely present) — 1.0 is perfectly
  /// stable, 0.0 means every present class flickered at least once.
  /// This is the same "does it flicker" concern
  /// `HazardTemporalFilter` exists to absorb in production, measured
  /// here as a per-model comparison point BEFORE any temporal
  /// filtering is applied — a model that's naturally more stable
  /// needs less of that filter's 3-frame delay to feel reliable.
  final double? detectionStabilityScore;

  // --- Time-to-warning (CPU-delegate row only) -------------------------
  /// Milliseconds from the frame where a ground-truth class first
  /// becomes present in the burst to the frame where the SAME
  /// 3-consecutive-frame confirmation rule `HazardTemporalFilter`
  /// uses in production would confirm it — i.e. real inference-side
  /// latency until this model would trigger an announcement, not
  /// including TTS speak() time (tracked separately elsewhere in the
  /// app via `RuntimeMetricsCollector`). Null if no ground-truth class
  /// ever reached 3 consecutive confirmed detections in the burst.
  final double? meanTimeToWarningMs;

  final String? detectionQualityNote;

  // --- APK size ---------------------------------------------------------
  /// Automatically computed: sum of this candidate's own .tflite +
  /// labels file byte size on disk. A CLOSE PROXY, not an exact APK
  /// delta — actual APK size impact also depends on compression/
  /// alignment Android applies at build time, which this can't
  /// observe from inside a running app. See
  /// [apkSizeManualNoteMb] for the real, verified number.
  final int? estimatedApkSizeIncreaseBytes;

  /// NEVER computed automatically — see `assets/ml_models/README.md`'s
  /// "Measuring per-model APK size" section for how to get the real
  /// `--analyze-size` delta and record it here after the fact. Blank
  /// means "not recorded," never zero.
  final String? apkSizeManualNoteMb;

  final int iterationsCompleted;
  final int iterationsRequested;

  /// Present only when [succeeded] is false.
  final String? failureReason;

  // --- Device fingerprint ----------------------------------------------
  final String deviceModel;
  final String deviceManufacturer;
  final String androidRelease;
  final int androidSdkInt;
  final String? chipsetHardware;

  final DateTime timestamp;

  const ModelBenchmarkResult({
    required this.modelName,
    required this.modelAssetPath,
    required this.delegate,
    required this.testMode,
    required this.succeeded,
    required this.iterationsCompleted,
    required this.iterationsRequested,
    required this.deviceModel,
    required this.deviceManufacturer,
    required this.androidRelease,
    required this.androidSdkInt,
    required this.timestamp,
    this.meanLatencyMs,
    this.medianLatencyMs,
    this.p90LatencyMs,
    this.minLatencyMs,
    this.maxLatencyMs,
    this.estimatedFps,
    this.nativeHeapDeltaBytes,
    this.cpuUsagePercentOfOneCore,
    this.cpuCoreCount,
    this.avgBatteryCurrentMicroAmps,
    this.batteryPercentBefore,
    this.batteryPercentAfter,
    this.batteryPercentDrop,
    this.testDurationSeconds,
    this.thermalStatusBefore,
    this.thermalStatusAfter,
    this.thermalStatusPeak,
    this.thermalHeadroomBefore,
    this.thermalHeadroomAfter,
    this.truePositives,
    this.falsePositives,
    this.falseNegatives,
    this.precision,
    this.recall,
    this.perClassBreakdown,
    this.detectionStabilityScore,
    this.meanTimeToWarningMs,
    this.detectionQualityNote,
    this.estimatedApkSizeIncreaseBytes,
    this.apkSizeManualNoteMb,
    this.failureReason,
    this.chipsetHardware,
  });

  static const List<String> csvHeader = [
    'timestamp',
    'model_name',
    'model_asset_path',
    'delegate',
    'test_mode',
    'succeeded',
    'iterations_completed',
    'iterations_requested',
    'mean_latency_ms',
    'median_latency_ms',
    'p90_latency_ms',
    'min_latency_ms',
    'max_latency_ms',
    'estimated_fps',
    'native_heap_delta_bytes',
    'cpu_usage_percent_of_one_core',
    'cpu_core_count',
    'avg_battery_current_microamps',
    'battery_percent_before',
    'battery_percent_after',
    'battery_percent_drop',
    'test_duration_seconds',
    'thermal_status_before',
    'thermal_status_after',
    'thermal_status_peak',
    'thermal_headroom_before',
    'thermal_headroom_after',
    'true_positives',
    'false_positives',
    'false_negatives',
    'precision',
    'recall',
    'per_class_breakdown_json',
    'detection_stability_score',
    'mean_time_to_warning_ms',
    'detection_quality_note',
    'estimated_apk_size_increase_bytes',
    'apk_size_manual_note_mb',
    'failure_reason',
    'device_model',
    'device_manufacturer',
    'android_release',
    'android_sdk_int',
    'chipset_hardware',
  ];

  List<String> toCsvRow() => [
        timestamp.toIso8601String(),
        modelName,
        modelAssetPath,
        delegate.name,
        testMode.name,
        succeeded.toString(),
        iterationsCompleted.toString(),
        iterationsRequested.toString(),
        meanLatencyMs?.toStringAsFixed(2) ?? '',
        medianLatencyMs?.toStringAsFixed(2) ?? '',
        p90LatencyMs?.toStringAsFixed(2) ?? '',
        minLatencyMs?.toStringAsFixed(2) ?? '',
        maxLatencyMs?.toStringAsFixed(2) ?? '',
        estimatedFps?.toStringAsFixed(2) ?? '',
        nativeHeapDeltaBytes?.toString() ?? '',
        cpuUsagePercentOfOneCore?.toStringAsFixed(1) ?? '',
        cpuCoreCount?.toString() ?? '',
        avgBatteryCurrentMicroAmps?.toStringAsFixed(0) ?? '',
        batteryPercentBefore?.toString() ?? '',
        batteryPercentAfter?.toString() ?? '',
        batteryPercentDrop?.toString() ?? '',
        testDurationSeconds?.toString() ?? '',
        thermalStatusBefore?.toString() ?? '',
        thermalStatusAfter?.toString() ?? '',
        thermalStatusPeak?.toString() ?? '',
        thermalHeadroomBefore?.toStringAsFixed(3) ?? '',
        thermalHeadroomAfter?.toStringAsFixed(3) ?? '',
        truePositives?.toString() ?? '',
        falsePositives?.toString() ?? '',
        falseNegatives?.toString() ?? '',
        precision?.toStringAsFixed(3) ?? '',
        recall?.toStringAsFixed(3) ?? '',
        perClassBreakdown != null ? jsonEncode(perClassBreakdown) : '',
        detectionStabilityScore?.toStringAsFixed(3) ?? '',
        meanTimeToWarningMs?.toStringAsFixed(1) ?? '',
        detectionQualityNote ?? '',
        estimatedApkSizeIncreaseBytes?.toString() ?? '',
        apkSizeManualNoteMb ?? '',
        failureReason ?? '',
        deviceModel,
        deviceManufacturer,
        androidRelease,
        androidSdkInt.toString(),
        chipsetHardware ?? '',
      ];

  Map<String, dynamic> toMap() => {
        for (int i = 0; i < csvHeader.length; i++) csvHeader[i]: toCsvRow()[i],
      };

  static double? _parseDouble(String? s) => (s == null || s.isEmpty) ? null : double.tryParse(s);
  static int? _parseInt(String? s) => (s == null || s.isEmpty) ? null : int.tryParse(s);

  /// Reconstructs a result from a persisted row (as produced by
  /// [toMap]) — used by `BenchmarkComparisonService` to read back
  /// every stored row (across sessions/devices) for ranking, without
  /// duplicating field-by-field parsing logic at each call site.
  factory ModelBenchmarkResult.fromMap(Map<String, dynamic> map) {
    String? str(String key) => (map[key] as String?)?.isEmpty ?? true ? null : map[key] as String?;
    Map<String, Map<String, int>>? perClass;
    final rawBreakdown = str('per_class_breakdown_json');
    if (rawBreakdown != null) {
      final decoded = jsonDecode(rawBreakdown) as Map<String, dynamic>;
      perClass = decoded.map((k, v) => MapEntry(k, Map<String, int>.from(v as Map)));
    }
    return ModelBenchmarkResult(
      modelName: map['model_name'] as String,
      modelAssetPath: map['model_asset_path'] as String,
      delegate: InferenceDelegate.values.byName(map['delegate'] as String),
      testMode: BenchmarkTestMode.values.byName((map['test_mode'] as String?) ?? 'quick'),
      succeeded: map['succeeded'] == 'true',
      iterationsCompleted: int.parse(map['iterations_completed'] as String),
      iterationsRequested: int.parse(map['iterations_requested'] as String),
      deviceModel: map['device_model'] as String,
      deviceManufacturer: map['device_manufacturer'] as String,
      androidRelease: map['android_release'] as String,
      androidSdkInt: int.parse(map['android_sdk_int'] as String),
      timestamp: DateTime.parse(map['timestamp'] as String),
      meanLatencyMs: _parseDouble(str('mean_latency_ms')),
      medianLatencyMs: _parseDouble(str('median_latency_ms')),
      p90LatencyMs: _parseDouble(str('p90_latency_ms')),
      minLatencyMs: _parseDouble(str('min_latency_ms')),
      maxLatencyMs: _parseDouble(str('max_latency_ms')),
      estimatedFps: _parseDouble(str('estimated_fps')),
      nativeHeapDeltaBytes: _parseInt(str('native_heap_delta_bytes')),
      cpuUsagePercentOfOneCore: _parseDouble(str('cpu_usage_percent_of_one_core')),
      cpuCoreCount: _parseInt(str('cpu_core_count')),
      avgBatteryCurrentMicroAmps: _parseDouble(str('avg_battery_current_microamps')),
      batteryPercentBefore: _parseInt(str('battery_percent_before')),
      batteryPercentAfter: _parseInt(str('battery_percent_after')),
      batteryPercentDrop: _parseInt(str('battery_percent_drop')),
      testDurationSeconds: _parseInt(str('test_duration_seconds')),
      thermalStatusBefore: _parseInt(str('thermal_status_before')),
      thermalStatusAfter: _parseInt(str('thermal_status_after')),
      thermalStatusPeak: _parseInt(str('thermal_status_peak')),
      thermalHeadroomBefore: _parseDouble(str('thermal_headroom_before')),
      thermalHeadroomAfter: _parseDouble(str('thermal_headroom_after')),
      truePositives: _parseInt(str('true_positives')),
      falsePositives: _parseInt(str('false_positives')),
      falseNegatives: _parseInt(str('false_negatives')),
      precision: _parseDouble(str('precision')),
      recall: _parseDouble(str('recall')),
      perClassBreakdown: perClass,
      detectionStabilityScore: _parseDouble(str('detection_stability_score')),
      meanTimeToWarningMs: _parseDouble(str('mean_time_to_warning_ms')),
      detectionQualityNote: str('detection_quality_note'),
      estimatedApkSizeIncreaseBytes: _parseInt(str('estimated_apk_size_increase_bytes')),
      apkSizeManualNoteMb: str('apk_size_manual_note_mb'),
      failureReason: str('failure_reason'),
      chipsetHardware: str('chipset_hardware'),
    );
  }
}
