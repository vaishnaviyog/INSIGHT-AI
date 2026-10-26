import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/benchmark_result.dart';

/// One metric dimension the comparison report scores across models.
/// [higherIsBetter] controls normalization direction; [weight] is the
/// DEFAULT suggested weight (see [BenchmarkComparisonService]'s doc
/// comment) — callers may pass a different weight map entirely.
enum ScoredMetric {
  fps,
  latency,
  memory,
  cpu,
  batteryDrain,
  thermalStability,
  precision,
  recall,
  detectionStability,
  timeToWarning,
  apkSize,
}

/// Aggregated, best-available measured profile for one candidate
/// model — built from whichever rows actually exist for it (across
/// delegates and test modes). A field left null means "not measured
/// for this model," not zero — see [BenchmarkComparisonService]'s
/// scoring logic for how nulls are handled (excluded from that
/// model's score, never penalized as worst).
class ModelProfile {
  final String modelName;
  final bool anySucceeded;

  final String? bestDelegateForSpeed;
  final double? fps;
  final double? meanLatencyMs;
  final int? nativeHeapDeltaBytes;
  final double? cpuUsagePercentOfOneCore;

  /// From a `continuousEndurance` row if one exists for this model;
  /// otherwise from the best quick-mode instantaneous current sample,
  /// with [batteryIsFromEnduranceTest] telling the report which.
  final double? avgBatteryCurrentMicroAmps;
  final int? batteryPercentDrop;
  final bool batteryIsFromEnduranceTest;

  final int? thermalStatusPeak;
  final double? thermalHeadroomAfter;

  final double? precision;
  final double? recall;
  final double? detectionStabilityScore;
  final double? meanTimeToWarningMs;
  final bool detectionQualityEvaluated;

  final int? estimatedApkSizeIncreaseBytes;
  final String? apkSizeManualNoteMb;

  const ModelProfile({
    required this.modelName,
    required this.anySucceeded,
    this.bestDelegateForSpeed,
    this.fps,
    this.meanLatencyMs,
    this.nativeHeapDeltaBytes,
    this.cpuUsagePercentOfOneCore,
    this.avgBatteryCurrentMicroAmps,
    this.batteryPercentDrop,
    this.batteryIsFromEnduranceTest = false,
    this.thermalStatusPeak,
    this.thermalHeadroomAfter,
    this.precision,
    this.recall,
    this.detectionStabilityScore,
    this.meanTimeToWarningMs,
    this.detectionQualityEvaluated = false,
    this.estimatedApkSizeIncreaseBytes,
    this.apkSizeManualNoteMb,
  });
}

class RankedModel {
  final ModelProfile profile;
  final double compositeScore; // 0-100
  final Map<ScoredMetric, double> perMetricNormalizedScore; // 0-1 each
  final List<ScoredMetric> metricsNotAvailable;
  const RankedModel({
    required this.profile,
    required this.compositeScore,
    required this.perMetricNormalizedScore,
    required this.metricsNotAvailable,
  });
}

/// Builds [ModelProfile]s from raw stored rows, scores them with
/// weighted, normalized metrics, and generates a Markdown ranking
/// report — the automatic, data-driven recommendation this framework
/// produces INSTEAD of a manually chosen winner.
///
/// WEIGHTS ARE SUGGESTED DEFAULTS, NOT A HARDCODED VERDICT: the
/// default weighting below reflects one reasonable prioritization for
/// a safety-relevant hazard-detection feature (detection quality and
/// speed-to-warning weighted highest, resource cost moderate, APK
/// size lowest) — but it is a judgment call, not a measured fact, and
/// callers can pass a different [weights] map entirely. The report
/// states the weights used, in full, so the recommendation is always
/// re-derivable and never presented as more objective than it is.
///
/// A METRIC MISSING FOR A MODEL IS EXCLUDED FROM THAT MODEL'S SCORE,
/// NEVER SCORED AS WORST: if only two of four candidates were
/// annotated for detection quality, the other two are ranked on their
/// remaining available metrics (with those two models' weights
/// renormalized to sum to 1 across just what they have), and the
/// report calls out exactly which metrics were unavailable for which
/// model rather than silently averaging past the gap.
class BenchmarkComparisonService {
  static const Map<ScoredMetric, double> defaultWeights = {
    ScoredMetric.precision: 0.16,
    ScoredMetric.recall: 0.16,
    ScoredMetric.timeToWarning: 0.14,
    ScoredMetric.detectionStability: 0.10,
    ScoredMetric.latency: 0.10,
    ScoredMetric.fps: 0.08,
    ScoredMetric.batteryDrain: 0.10,
    ScoredMetric.thermalStability: 0.06,
    ScoredMetric.cpu: 0.04,
    ScoredMetric.memory: 0.04,
    ScoredMetric.apkSize: 0.02,
  };

  List<ModelProfile> buildProfiles(List<ModelBenchmarkResult> allRows) {
    final byModel = <String, List<ModelBenchmarkResult>>{};
    for (final row in allRows) {
      byModel.putIfAbsent(row.modelName, () => []).add(row);
    }

    return byModel.entries.map((entry) {
      final modelName = entry.key;
      final rows = entry.value;
      final succeeded = rows.where((r) => r.succeeded).toList();
      if (succeeded.isEmpty) {
        return ModelProfile(modelName: modelName, anySucceeded: false);
      }

      final quickRows = succeeded.where((r) => r.testMode == BenchmarkTestMode.quick).toList();
      final enduranceRows =
          succeeded.where((r) => r.testMode == BenchmarkTestMode.continuousEndurance).toList();

      // Speed/memory/CPU: best (highest FPS) quick-mode delegate for
      // this model — a candidate should get credit for whichever
      // delegate actually works best for it, not penalized for a
      // delegate that happens to regress on this device.
      ModelBenchmarkResult? bestQuick;
      for (final row in quickRows) {
        if (row.estimatedFps == null) continue;
        if (bestQuick == null || row.estimatedFps! > bestQuick.estimatedFps!) bestQuick = row;
      }

      // Detection quality/stability/time-to-warning: CPU-delegate quick
      // row only (see ModelBenchmarkResult class doc for why).
      final cpuQuickRow = quickRows
          .where((r) => r.delegate == InferenceDelegate.cpu && r.precision != null)
          .cast<ModelBenchmarkResult?>()
          .firstWhere((r) => true, orElse: () => null);

      // Battery/thermal: prefer a real endurance-test row; fall back
      // to the best quick row's instantaneous current as a weaker
      // signal, clearly flagged via [batteryIsFromEnduranceTest].
      final enduranceRow = enduranceRows.isNotEmpty ? enduranceRows.first : null;

      final apkSource = succeeded
          .cast<ModelBenchmarkResult?>()
          .firstWhere((r) => r!.estimatedApkSizeIncreaseBytes != null, orElse: () => null);

      return ModelProfile(
        modelName: modelName,
        anySucceeded: true,
        bestDelegateForSpeed: bestQuick?.delegate.name,
        fps: bestQuick?.estimatedFps,
        meanLatencyMs: bestQuick?.meanLatencyMs,
        nativeHeapDeltaBytes: bestQuick?.nativeHeapDeltaBytes,
        cpuUsagePercentOfOneCore: bestQuick?.cpuUsagePercentOfOneCore,
        avgBatteryCurrentMicroAmps:
            enduranceRow?.avgBatteryCurrentMicroAmps ?? bestQuick?.avgBatteryCurrentMicroAmps,
        batteryPercentDrop: enduranceRow?.batteryPercentDrop,
        batteryIsFromEnduranceTest: enduranceRow != null,
        thermalStatusPeak: enduranceRow?.thermalStatusPeak ?? bestQuick?.thermalStatusPeak,
        thermalHeadroomAfter: enduranceRow?.thermalHeadroomAfter ?? bestQuick?.thermalHeadroomAfter,
        precision: cpuQuickRow?.precision,
        recall: cpuQuickRow?.recall,
        detectionStabilityScore: cpuQuickRow?.detectionStabilityScore,
        meanTimeToWarningMs: cpuQuickRow?.meanTimeToWarningMs,
        detectionQualityEvaluated: cpuQuickRow != null,
        estimatedApkSizeIncreaseBytes: apkSource?.estimatedApkSizeIncreaseBytes,
        apkSizeManualNoteMb: succeeded
            .map((r) => r.apkSizeManualNoteMb)
            .cast<String?>()
            .firstWhere((n) => n != null && n.isNotEmpty, orElse: () => null),
      );
    }).toList();
  }

  List<RankedModel> rank(List<ModelProfile> profiles, {Map<ScoredMetric, double>? weights}) {
    final effectiveWeights = weights ?? defaultWeights;
    final candidates = profiles.where((p) => p.anySucceeded).toList();

    double? metricValue(ModelProfile p, ScoredMetric m) => switch (m) {
          ScoredMetric.fps => p.fps,
          ScoredMetric.latency => p.meanLatencyMs,
          ScoredMetric.memory => p.nativeHeapDeltaBytes?.toDouble(),
          ScoredMetric.cpu => p.cpuUsagePercentOfOneCore,
          ScoredMetric.batteryDrain => p.avgBatteryCurrentMicroAmps?.abs(),
          ScoredMetric.thermalStability => p.thermalStatusPeak?.toDouble(),
          ScoredMetric.precision => p.precision,
          ScoredMetric.recall => p.recall,
          ScoredMetric.detectionStability => p.detectionStabilityScore,
          ScoredMetric.timeToWarning => p.meanTimeToWarningMs,
          ScoredMetric.apkSize => p.estimatedApkSizeIncreaseBytes?.toDouble(),
        };

    bool higherIsBetter(ScoredMetric m) => switch (m) {
          ScoredMetric.fps ||
          ScoredMetric.precision ||
          ScoredMetric.recall ||
          ScoredMetric.detectionStability =>
            true,
          _ => false,
        };

    // Min/max across candidates that actually have this metric.
    final ranges = <ScoredMetric, (double min, double max)>{};
    for (final m in ScoredMetric.values) {
      final values = candidates.map((p) => metricValue(p, m)).whereType<double>().toList();
      if (values.isEmpty) continue;
      ranges[m] = (values.reduce((a, b) => a < b ? a : b), values.reduce((a, b) => a > b ? a : b));
    }

    final results = <RankedModel>[];
    for (final profile in candidates) {
      final perMetricScore = <ScoredMetric, double>{};
      final missing = <ScoredMetric>[];
      double weightedSum = 0;
      double weightTotal = 0;

      for (final m in ScoredMetric.values) {
        final value = metricValue(profile, m);
        final range = ranges[m];
        if (value == null || range == null) {
          missing.add(m);
          continue;
        }
        final (min, max) = range;
        double normalized;
        if (max == min) {
          normalized = 1.0; // every candidate identical on this metric
        } else {
          normalized = (value - min) / (max - min);
          if (!higherIsBetter(m)) normalized = 1.0 - normalized;
        }
        perMetricScore[m] = normalized;
        final weight = effectiveWeights[m] ?? 0;
        weightedSum += normalized * weight;
        weightTotal += weight;
      }

      final composite = weightTotal > 0 ? (weightedSum / weightTotal) * 100 : 0.0;
      results.add(RankedModel(
        profile: profile,
        compositeScore: composite,
        perMetricNormalizedScore: perMetricScore,
        metricsNotAvailable: missing,
      ));
    }

    results.sort((a, b) => b.compositeScore.compareTo(a.compositeScore));

    // Failed-entirely models are appended at the bottom, unscored.
    for (final failed in profiles.where((p) => !p.anySucceeded)) {
      results.add(RankedModel(
        profile: failed,
        compositeScore: 0,
        perMetricNormalizedScore: const {},
        metricsNotAvailable: ScoredMetric.values,
      ));
    }
    return results;
  }

  String generateMarkdownReport(List<RankedModel> ranked, {Map<ScoredMetric, double>? weights}) {
    final effectiveWeights = weights ?? defaultWeights;
    final buffer = StringBuffer();
    buffer.writeln('# Vision Model Benchmark — Comparison Report');
    buffer.writeln();
    buffer.writeln('Generated ${DateTime.now().toIso8601String()}. Every number below comes from a '
        'measured `ModelBenchmarkResult` row — nothing here is a literature figure or an assumption.');
    buffer.writeln();
    buffer.writeln('## Weights used');
    buffer.writeln('These are suggested defaults reflecting one reasonable priority ordering for a '
        'safety-relevant hazard-detection feature — not an objective fact. Adjust and re-run if your '
        'priorities differ.');
    buffer.writeln();
    buffer.writeln('| Metric | Weight |');
    buffer.writeln('|---|---|');
    for (final m in ScoredMetric.values) {
      buffer.writeln('| ${m.name} | ${((effectiveWeights[m] ?? 0) * 100).toStringAsFixed(0)}% |');
    }
    buffer.writeln();

    buffer.writeln('## Ranking');
    buffer.writeln();
    buffer.writeln('| Rank | Model | Composite Score | Metrics Not Available |');
    buffer.writeln('|---|---|---|---|');
    for (int i = 0; i < ranked.length; i++) {
      final r = ranked[i];
      if (!r.profile.anySucceeded) {
        buffer.writeln('| ${i + 1} | ${r.profile.modelName} | — (failed every run) | all |');
        continue;
      }
      final missingList = r.metricsNotAvailable.isEmpty
          ? 'none'
          : r.metricsNotAvailable.map((m) => m.name).join(', ');
      buffer.writeln('| ${i + 1} | ${r.profile.modelName} | ${r.compositeScore.toStringAsFixed(1)} | $missingList |');
    }
    buffer.writeln();

    buffer.writeln('## Raw measured values per model');
    buffer.writeln();
    for (final r in ranked.where((r) => r.profile.anySucceeded)) {
      final p = r.profile;
      buffer.writeln('### ${p.modelName}');
      buffer.writeln('- Best delegate for speed: ${p.bestDelegateForSpeed ?? "n/a"}');
      buffer.writeln('- FPS: ${p.fps?.toStringAsFixed(1) ?? "n/a"} · Mean latency: '
          '${p.meanLatencyMs?.toStringAsFixed(1) ?? "n/a"} ms');
      buffer.writeln('- Native heap Δ: ${p.nativeHeapDeltaBytes != null ? '${(p.nativeHeapDeltaBytes! / 1024 / 1024).toStringAsFixed(1)} MB' : "n/a"} '
          '· CPU: ${p.cpuUsagePercentOfOneCore?.toStringAsFixed(0) ?? "n/a"}% of one core');
      buffer.writeln('- Battery: ${p.avgBatteryCurrentMicroAmps != null ? '${(p.avgBatteryCurrentMicroAmps! / 1000).toStringAsFixed(1)} mA' : "n/a"}'
          '${p.batteryIsFromEnduranceTest ? " (from a continuous endurance run)" : " (instantaneous, quick-pass proxy — run the endurance test for a stronger signal)"}'
          '${p.batteryPercentDrop != null ? " · ${p.batteryPercentDrop}% drop over the endurance window" : ""}');
      buffer.writeln('- Thermal peak status: ${p.thermalStatusPeak ?? "n/a"}'
          '${p.thermalHeadroomAfter != null ? " · headroom ${p.thermalHeadroomAfter!.toStringAsFixed(2)}" : ""}');
      if (p.detectionQualityEvaluated) {
        buffer.writeln('- Precision: ${p.precision != null ? '${(p.precision! * 100).toStringAsFixed(0)}%' : "n/a"} '
            '· Recall: ${p.recall != null ? '${(p.recall! * 100).toStringAsFixed(0)}%' : "n/a"} '
            '· Stability: ${p.detectionStabilityScore != null ? '${(p.detectionStabilityScore! * 100).toStringAsFixed(0)}%' : "n/a"} '
            '· Time-to-warning: ${p.meanTimeToWarningMs != null ? '${p.meanTimeToWarningMs!.toStringAsFixed(0)} ms (inference-side only)' : "n/a"}');
      } else {
        buffer.writeln('- Detection quality: NOT EVALUATED for this model — annotate ground truth in '
            'Step 2 and re-run the CPU-delegate quick pass to get this.');
      }
      buffer.writeln('- Estimated APK size contribution: ${p.estimatedApkSizeIncreaseBytes != null ? '${(p.estimatedApkSizeIncreaseBytes! / 1024 / 1024).toStringAsFixed(2)} MB (asset-size proxy, not a verified --analyze-size delta)' : "n/a"}'
          '${p.apkSizeManualNoteMb != null ? " · manually recorded: ${p.apkSizeManualNoteMb} MB" : ""}');
      buffer.writeln();
    }

    final topScored = ranked.where((r) => r.profile.anySucceeded).toList();
    buffer.writeln('## Recommendation');
    if (topScored.isEmpty) {
      buffer.writeln('No candidate completed a successful benchmark run — nothing to recommend yet.');
    } else {
      final winner = topScored.first;
      buffer.writeln('Highest composite score: **${winner.profile.modelName}** '
          '(${winner.compositeScore.toStringAsFixed(1)}/100 under the weights above).');
      if (winner.metricsNotAvailable.isNotEmpty) {
        buffer.writeln();
        buffer.writeln('This score is based on an incomplete metric set for this model — missing: '
            '${winner.metricsNotAvailable.map((m) => m.name).join(', ')}. Fill in the gaps (ground-truth '
            'annotation, a continuous endurance run) before treating this as final.');
      }
      buffer.writeln();
      buffer.writeln('This is a data-driven ranking under the stated weights, not a substitute for your '
          'own judgment about which metrics matter most for your deployment — re-run with adjusted '
          'weights if the priorities above don\'t match yours.');
    }

    return buffer.toString();
  }

  Future<String?> exportReportToFile(String markdown) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
      final filename = 'insight_model_comparison_${DateTime.now().millisecondsSinceEpoch}.md';
      final file = File('${directory.path}/$filename');
      await file.writeAsString(markdown);
      return file.path;
    } catch (e) {
      // ignore: avoid_print
      print('BenchmarkComparisonService: report export failed: $e');
      return null;
    }
  }
}
