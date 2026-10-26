import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../evaluation_service.dart';
import '../behaviour_learning_service.dart';
import '../../models/navigation_session_record.dart';
import 'navigation_metrics_tracker.dart';
import 'runtime_metrics_collector.dart';
import 'statistics_utils.dart';

/// One named metric value in the final report. [value] is nullable —
/// null means "not computable from the data collected this session"
/// (e.g. zero navigation sessions recorded), which is always reported
/// explicitly via [notes] rather than silently defaulted to 0.
class MetricEntry {
  final String category;
  final String name;
  final double? value;
  final String unit;
  final int sampleSize;
  final String notes;

  const MetricEntry({
    required this.category,
    required this.name,
    required this.value,
    required this.unit,
    required this.sampleSize,
    this.notes = '',
  });

  Map<String, dynamic> toJson() => {
        'category': category,
        'metric': name,
        'value': value,
        'unit': unit,
        'sample_size': sampleSize,
        'notes': notes,
      };

  List<String> toCsvRow() => [
        category,
        name,
        value == null ? '' : value!.toStringAsFixed(6),
        unit,
        sampleSize.toString(),
        notes,
      ];
}

/// The full computed report for one export cycle. Built entirely from
/// data already collected by EvaluationService, BehaviourLearningService,
/// NavigationMetricsTracker, and RuntimeMetricsCollector — see
/// MetricsReportService.computeReport() for exactly how each field is
/// derived, and the accompanying explanation for the formula behind
/// every entry.
class MetricsReport {
  final DateTime generatedAt;
  final List<MetricEntry> entries;
  final Map<String, StatSummary> statisticalSummaries;
  final Map<String, PairedComparisonResult?> pairwiseComparisons;
  final Map<String, String> pairwiseComparisonNotes;

  const MetricsReport({
    required this.generatedAt,
    required this.entries,
    required this.statisticalSummaries,
    required this.pairwiseComparisons,
    required this.pairwiseComparisonNotes,
  });

  static const List<String> _csvHeader = [
    'category',
    'metric',
    'value',
    'unit',
    'sample_size',
    'notes',
  ];

  String toCsv() {
    final buffer = StringBuffer();
    buffer.writeln(_csvHeader.map(_csvEscape).join(','));
    for (final entry in entries) {
      buffer.writeln(entry.toCsvRow().map(_csvEscape).join(','));
    }
    // Full statistical breakdown, one row per (distribution, statistic).
    statisticalSummaries.forEach((distributionName, summary) {
      final map = summary.toMap();
      for (final statName in [
        'n',
        'mean',
        'median',
        'standard_deviation',
        'variance',
        'min',
        'max',
        'ci_95_lower',
        'ci_95_upper'
      ]) {
        final v = map[statName];
        buffer.writeln([
          'Statistical',
          '$distributionName — $statName',
          v == null ? '' : (v is int ? v.toString() : (v as double).toStringAsFixed(6)),
          '',
          summary.n.toString(),
          '',
        ].map(_csvEscape).join(','));
      }
    });
    // Paired comparisons.
    pairwiseComparisons.forEach((label, result) {
      if (result == null) {
        buffer.writeln([
          'Statistical Comparison',
          '$label — status',
          '',
          '',
          '0',
          pairwiseComparisonNotes[label] ?? 'insufficient/mismatched data',
        ].map(_csvEscape).join(','));
      } else {
        final map = result.toMap();
        map.forEach((k, v) {
          buffer.writeln([
            'Statistical Comparison',
            '$label — $k',
            v == null ? '' : (v is int ? v.toString() : (v as double).toStringAsFixed(6)),
            '',
            result.n.toString(),
            '',
          ].map(_csvEscape).join(','));
        });
      }
    });
    return buffer.toString();
  }

  String _csvEscape(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  Map<String, dynamic> toJsonMap() => {
        'generated_at': generatedAt.toIso8601String(),
        'metrics': entries.map((e) => e.toJson()).toList(),
        'statistics': statisticalSummaries.map((k, v) => MapEntry(k, v.toMap())),
        'comparisons': pairwiseComparisons.map((k, v) => MapEntry(
              k,
              v?.toMap() ?? {'status': 'unavailable', 'reason': pairwiseComparisonNotes[k]},
            )),
      };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJsonMap());

  String toMarkdown() {
    final buffer = StringBuffer();
    buffer.writeln('# Evaluation Metrics Report');
    buffer.writeln();
    buffer.writeln('Generated: ${generatedAt.toIso8601String()}');
    buffer.writeln();
    buffer.writeln('All values below are computed only from data collected at runtime by this '
        'application. A `null`/blank value means there was not yet enough collected data to '
        'compute that metric — it is never estimated or filled in.');
    buffer.writeln();

    final categories = <String>[];
    for (final e in entries) {
      if (!categories.contains(e.category)) categories.add(e.category);
    }

    for (final category in categories) {
      buffer.writeln('## $category');
      buffer.writeln();
      buffer.writeln('| Metric | Value | Unit | Sample Size | Notes |');
      buffer.writeln('|---|---|---|---|---|');
      for (final e in entries.where((e) => e.category == category)) {
        final valueStr = e.value == null ? '—' : e.value!.toStringAsFixed(4);
        buffer.writeln('| ${e.name} | $valueStr | ${e.unit} | ${e.sampleSize} | ${e.notes} |');
      }
      buffer.writeln();
    }

    buffer.writeln('## Statistical Summaries');
    buffer.writeln();
    buffer.writeln('| Distribution | n | Mean | Median | Std Dev | Variance | Min | Max | 95% CI |');
    buffer.writeln('|---|---|---|---|---|---|---|---|---|');
    statisticalSummaries.forEach((name, s) {
      if (s.n == 0) {
        buffer.writeln('| $name | 0 | — | — | — | — | — | — | — |');
      } else {
        buffer.writeln('| $name | ${s.n} | ${s.mean.toStringAsFixed(4)} | '
            '${s.median.toStringAsFixed(4)} | ${s.standardDeviation.toStringAsFixed(4)} | '
            '${s.variance.toStringAsFixed(4)} | ${s.min.toStringAsFixed(4)} | '
            '${s.max.toStringAsFixed(4)} | '
            '[${s.confidenceIntervalLower.toStringAsFixed(4)}, '
            '${s.confidenceIntervalUpper.toStringAsFixed(4)}] |');
      }
    });
    buffer.writeln();

    if (pairwiseComparisons.isNotEmpty) {
      buffer.writeln('## Paired Comparisons (Two-Dataset Statistics)');
      buffer.writeln();
      pairwiseComparisons.forEach((label, result) {
        buffer.writeln('### $label');
        buffer.writeln();
        if (result == null) {
          buffer.writeln(pairwiseComparisonNotes[label] ?? 'Insufficient or mismatched data.');
        } else {
          final undefinedNote =
              ' (undefined — every pair had an identical difference, so standard error is zero)';
          buffer.writeln('- Pairs (n): ${result.n}');
          buffer.writeln('- Mean difference: ${result.meanDifference.toStringAsFixed(4)}');
          buffer.writeln('- t-statistic: ${result.tStatistic.isNaN ? 'undefined$undefinedNote' : result.tStatistic.toStringAsFixed(4)}');
          buffer.writeln('- Degrees of freedom: ${result.degreesOfFreedom}');
          buffer.writeln('- p-value (two-tailed): ${result.pValueTwoTailed.isNaN ? 'undefined$undefinedNote' : result.pValueTwoTailed.toStringAsFixed(6)}');
          buffer.writeln("- Cohen's d: ${result.cohensD.isNaN ? 'undefined$undefinedNote' : result.cohensD.toStringAsFixed(4)}");
        }
        buffer.writeln();
      });
    }

    return buffer.toString();
  }
}

/// Computes a [MetricsReport] from the app's existing data sources and
/// exports it to `evaluation_metrics.csv` / `.json` / `.md`.
///
/// SCOPE BOUNDARY: read-only over EvaluationService,
/// BehaviourLearningService, NavigationMetricsTracker, and
/// RuntimeMetricsCollector. Never calls any mutating method on them,
/// never influences navigation/detection/speech/guidance.
class MetricsReportService {
  MetricsReportService._internal();
  static final MetricsReportService instance = MetricsReportService._internal();

  static const String csvFileName = 'evaluation_metrics.csv';
  static const String jsonFileName = 'evaluation_metrics.json';
  static const String mdFileName = 'evaluation_metrics.md';

  /// [currentSessionOverride], if provided, is included alongside the
  /// persisted [NavigationMetricsTracker.allSessions] history for the
  /// NAVIGATION metrics below. This exists so a caller computing a
  /// report at teardown time (e.g. a widget's `dispose()`) can include
  /// the just-ended session WITHOUT first awaiting
  /// [NavigationMetricsTracker.endSession]'s async Hive write — this
  /// method itself has no `await` anywhere in it, which is what lets
  /// it run synchronously before any Hive box is closed. See
  /// navigation_screen.dart's `dispose()`.
  MetricsReport computeReport({
    required EvaluationService evaluationService,
    required BehaviourLearningService behaviourLearningService,
    required NavigationMetricsTracker navigationMetricsTracker,
    NavigationSessionRecord? currentSessionOverride,
  }) {
    final allRecords = evaluationService.allRecords;
    final profile = behaviourLearningService.profile;
    final sessions = [
      ...navigationMetricsTracker.allSessions,
      if (currentSessionOverride != null) currentSessionOverride,
    ];
    final runtime = RuntimeMetricsCollector.instance;

    final confidenceValues = allRecords.map((r) => r.detectionConfidence).toList();
    final detectionLatencyValues =
        allRecords.map((r) => r.processingLatencyMs).whereType<double>().toList();
    // P0-5 rename: this is warning-to-clearance latency, not a
    // measured human reaction time — see
    // EvaluationRecord.hazardClearanceLatencySeconds's doc comment.
    final clearanceLatencyValues =
        allRecords.map((r) => r.hazardClearanceLatencySeconds).whereType<double>().toList();

    final confidenceStats = StatisticsUtils.summarize(confidenceValues);
    final detectionLatencyStats = StatisticsUtils.summarize(detectionLatencyValues);
    final processingLatencyStats = StatisticsUtils.summarize(runtime.processingLatencySamplesMs);
    final speechLatencyStats = StatisticsUtils.summarize(runtime.speechLatencySamplesMs);
    final memoryStats = StatisticsUtils.summarize(runtime.memoryUsageSamplesBytes);

    final entries = <MetricEntry>[];

    // ---------------------------------------------------------------
    // OBJECT DETECTION
    // ---------------------------------------------------------------
    final groundTruth = runtime.groundTruthAnnotations;
    final hasGroundTruth = groundTruth.isNotEmpty;

    // AUDIT FIX (P1-9 — research integrity): WITHOUT real ground
    // truth, TP/FP/TN/FN/Precision/Recall/F1/Accuracy are now null —
    // never computed from a behavioral proxy and reported as if they
    // were object-detection accuracy. The previous code computed a
    // "warning spoken + hazard later cleared = TP" style proxy here
    // and reported it directly as Object Detection Precision/Recall/
    // F1/TP/FP/TN, with only a `notes` string disclosing the caveat —
    // easy to miss, and the wrong place to gate correctness on a
    // string a reader might not open. The equivalent BEHAVIORAL
    // signals (was a warning followed by a clearance event) still
    // exist — see the "Safety" section's "Warning→Clearance Rate"
    // below — but they are not presented as detection accuracy.
    int? tp, fp, tn, fn;
    double? precision, recall, f1, accuracy;
    String detectionSourceNote;
    if (hasGroundTruth) {
      tp = groundTruth.where((a) => a.hazardActuallyPresent && a.hazardWasDetected).length;
      fp = groundTruth.where((a) => !a.hazardActuallyPresent && a.hazardWasDetected).length;
      tn = groundTruth.where((a) => !a.hazardActuallyPresent && !a.hazardWasDetected).length;
      fn = groundTruth.where((a) => a.hazardActuallyPresent && !a.hazardWasDetected).length;
      final tpFpDenominator = tp + fp;
      precision = tpFpDenominator > 0 ? tp / tpFpDenominator : null;
      recall = (tp + fn) > 0 ? tp / (tp + fn) : null;
      f1 = (precision != null && recall != null && (precision + recall) > 0)
          ? 2 * precision * recall / (precision + recall)
          : null;
      final accuracyDenominator = tp + tn + fp + fn;
      accuracy = accuracyDenominator > 0 ? (tp + tn) / accuracyDenominator : null;
      detectionSourceNote = 'Computed from ${groundTruth.length} externally-supplied '
          'ground-truth annotations (recordGroundTruthAnnotation).';
    } else {
      tp = null;
      fp = null;
      tn = null;
      fn = null;
      precision = null;
      recall = null;
      f1 = null;
      accuracy = null;
      detectionSourceNote = 'Unavailable — requires ground-truth annotations '
          '(recordGroundTruthAnnotation). No behavioral proxy is substituted here; '
          'see the Safety section for the related (differently-named, differently-scoped) '
          'behavioral signal.';
    }

    entries.addAll([
      MetricEntry(
        category: 'Object Detection',
        name: 'Accuracy',
        value: accuracy,
        unit: 'ratio',
        sampleSize: hasGroundTruth ? (tp! + tn! + fp! + fn!) : 0,
        notes: detectionSourceNote,
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'Precision',
        value: precision,
        unit: 'ratio',
        sampleSize: hasGroundTruth ? (tp! + fp!) : 0,
        notes: detectionSourceNote,
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'Recall',
        value: recall,
        unit: 'ratio',
        sampleSize: hasGroundTruth ? (tp! + fn!) : 0,
        notes: detectionSourceNote,
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'F1 Score',
        value: f1,
        unit: 'ratio',
        sampleSize: hasGroundTruth ? (tp! + fn!) : 0,
        notes: detectionSourceNote,
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'Average Detection Confidence',
        value: confidenceStats.n > 0 ? confidenceStats.mean : null,
        unit: 'ratio (0-1)',
        sampleSize: confidenceStats.n,
        notes: 'Mean of detectionConfidence across all logged hazard episodes.',
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'Average Detection Latency',
        value: detectionLatencyStats.n > 0 ? detectionLatencyStats.mean : null,
        unit: 'ms',
        sampleSize: detectionLatencyStats.n,
        notes: 'Mean Stopwatch-measured time for HazardDetectionService.detectHazards() per episode.',
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'True Positives',
        value: tp?.toDouble(),
        unit: 'count',
        sampleSize: tp ?? 0,
        notes: detectionSourceNote,
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'False Positives',
        value: fp?.toDouble(),
        unit: 'count',
        sampleSize: fp ?? 0,
        notes: detectionSourceNote,
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'True Negatives',
        value: tn?.toDouble(),
        unit: 'count',
        sampleSize: tn ?? 0,
        notes: detectionSourceNote,
      ),
      MetricEntry(
        category: 'Object Detection',
        name: 'False Negatives',
        value: fn?.toDouble(),
        unit: 'count',
        sampleSize: fn ?? 0,
        notes: detectionSourceNote,
      ),
    ]);

    // ---------------------------------------------------------------
    // NAVIGATION
    // ---------------------------------------------------------------
    final totalSessions = sessions.length;
    final successfulSessions = sessions.where((s) => s.reachedDestination).length;
    final durations = sessions.map((s) => s.durationSeconds).whereType<double>().toList();
    final completionPercentages = sessions.map((s) => s.completionPercentage).toList();
    final totalDeviations = sessions.fold<int>(0, (sum, s) => sum + s.deviationCount);
    final durationStats = StatisticsUtils.summarize(durations);
    final completionStats = StatisticsUtils.summarize(completionPercentages);

    entries.addAll([
      MetricEntry(
        category: 'Navigation',
        name: 'Navigation Success Rate',
        value: totalSessions > 0 ? successfulSessions / totalSessions : null,
        unit: 'ratio',
        sampleSize: totalSessions,
        notes: 'Sessions where the OSRM "arrive" instruction was spoken ÷ total recorded sessions.',
      ),
      MetricEntry(
        category: 'Navigation',
        name: 'Average Route Completion Time',
        value: durationStats.n > 0 ? durationStats.mean : null,
        unit: 'seconds',
        sampleSize: durationStats.n,
        notes: 'Mean of (session end time − session start time) across ended sessions.',
      ),
      MetricEntry(
        category: 'Navigation',
        name: 'Route Deviations',
        value: totalDeviations.toDouble(),
        unit: 'count (total)',
        sampleSize: totalSessions,
        notes: 'Sum of off-route/moving-away guidance events across all recorded sessions.',
      ),
      MetricEntry(
        category: 'Navigation',
        name: 'Route Completion Percentage',
        value: completionStats.n > 0 ? completionStats.mean : null,
        unit: 'percent',
        sampleSize: completionStats.n,
        notes: 'Mean of (route steps reached ÷ total route steps × 100) across recorded sessions.',
      ),
    ]);

    // ---------------------------------------------------------------
    // SAFETY
    // ---------------------------------------------------------------
    final hazardsDetected = allRecords.length;
    final hazardsAvoided = profile?.successfulObstacleAvoidances ?? 0;
    final missedHazards = allRecords.where((r) => r.voiceWarningTimestamp == null).length;
    final warningsIssued = allRecords.where((r) => r.voiceWarningTimestamp != null).length;
    // AUDIT NOTE (P1-9): renamed from `warningsConfirmed` for clarity
    // — this is a warning-then-clearance-event proxy, the same kind
    // of signal P0-5 renamed elsewhere, and explicitly NOT an
    // object-detection ground-truth measurement (see the Object
    // Detection section above, which no longer uses any variant of
    // this signal for TP/FP/accuracy).
    final warningsFollowedByClearance = allRecords
        .where((r) => r.voiceWarningTimestamp != null && r.hazardClearanceTimestamp != null)
        .length;
    final warningToClearanceRate = warningsIssued > 0 ? warningsFollowedByClearance / warningsIssued : null;

    entries.addAll([
      MetricEntry(
        category: 'Safety',
        name: 'Hazards Detected',
        value: hazardsDetected.toDouble(),
        unit: 'count',
        sampleSize: hazardsDetected,
        notes: 'Total EvaluationRecord episodes (one per detected-hazard episode).',
      ),
      MetricEntry(
        category: 'Safety',
        name: 'Hazards Avoided',
        value: hazardsAvoided.toDouble(),
        unit: 'count',
        sampleSize: hazardsAvoided,
        notes: 'UserBehaviourProfile.successfulObstacleAvoidances (warning followed by a clearance event).',
      ),
      MetricEntry(
        category: 'Safety',
        name: 'Missed Hazards',
        value: missedHazards.toDouble(),
        unit: 'count',
        sampleSize: missedHazards,
        notes: 'Detected-hazard episodes for which no warning was ever spoken (voice_warning_timestamp is null).',
      ),
      MetricEntry(
        category: 'Safety',
        name: 'Warnings Issued',
        value: warningsIssued.toDouble(),
        unit: 'count',
        sampleSize: warningsIssued,
        notes: 'Behavioral count, kept separate from any accuracy claim — total spoken warnings.',
      ),
      MetricEntry(
        category: 'Safety',
        name: 'Empty Detection Frames',
        value: runtime.emptyDetectionFrameCount.toDouble(),
        unit: 'count',
        sampleSize: runtime.emptyDetectionFrameCount,
        notes: 'Behavioral count of camera frames with zero detections — NOT used as a True '
            'Negative proxy for object-detection accuracy (see the Object Detection section above).',
      ),
      MetricEntry(
        category: 'Safety',
        name: 'Warning\u2192Clearance Rate',
        value: warningToClearanceRate,
        unit: 'ratio',
        sampleSize: warningsIssued,
        notes: 'BEHAVIORAL PROXY, NOT object-detection accuracy: spoken warnings followed by a '
            'hazard-clearance event \u00f7 total spoken warnings. A cleared hazard is not a '
            'confirmed human response — see EvaluationRecord.hazardClearanceTimestamp\'s doc comment.',
      ),
      MetricEntry(
        category: 'Safety',
        name: 'Warnings Not Followed By Clearance',
        value: warningToClearanceRate != null ? 1.0 - warningToClearanceRate : null,
        unit: 'ratio',
        sampleSize: warningsIssued,
        notes: 'BEHAVIORAL PROXY, NOT a verified false-alarm rate: 1 \u2212 Warning\u2192Clearance Rate. '
            'A warning with no observed clearance is not necessarily wrong — the session may have '
            'ended, or the hazard may have genuinely remained present.',
      ),
    ]);

    // ---------------------------------------------------------------
    // BEHAVIOUR
    // ---------------------------------------------------------------
    entries.addAll([
      MetricEntry(
        category: 'Behaviour',
        name: 'Average Hazard Clearance Latency',
        value: (profile != null && profile.reactionSampleCount > 0) ? profile.averageReactionTime : null,
        unit: 'seconds',
        sampleSize: profile?.reactionSampleCount ?? 0,
        notes: 'BEHAVIORAL PROXY, NOT a measured human reaction time: '
            'UserBehaviourProfile.averageReactionTime — running average of warning-spoken-to-'
            'hazard-cleared latency. Field name kept for Hive persistence compatibility; see '
            'that model\'s doc comment.',
      ),
      MetricEntry(
        category: 'Behaviour',
        name: 'Familiarity Score',
        value: profile?.routeFamiliarityScore,
        unit: 'ratio (0-1)',
        sampleSize: profile?.totalNavigationSessions ?? 0,
        notes: 'UserBehaviourProfile.routeFamiliarityScore.',
      ),
      MetricEntry(
        category: 'Behaviour',
        name: 'Behaviour Profile Updates',
        value: behaviourLearningService.profileUpdateCount.toDouble(),
        unit: 'count',
        sampleSize: behaviourLearningService.profileUpdateCount,
        notes: 'Count of BehaviourLearningService._applyEvent() calls (every recorded behaviour event).',
      ),
    ]);

    // ---------------------------------------------------------------
    // SYSTEM PERFORMANCE
    // ---------------------------------------------------------------
    final sessionDuration = runtime.sessionWallClockDuration;
    final fps = (sessionDuration != null && sessionDuration.inMilliseconds > 0 && runtime.cameraFrameCount > 0)
        ? runtime.cameraFrameCount / (sessionDuration.inMilliseconds / 1000.0)
        : null;

    entries.addAll([
      MetricEntry(
        category: 'System Performance',
        name: 'Camera FPS',
        value: fps,
        unit: 'frames/sec',
        sampleSize: runtime.cameraFrameCount,
        notes: 'Camera frame callbacks ÷ session wall-clock duration.',
      ),
      MetricEntry(
        category: 'System Performance',
        name: 'Processing Latency',
        value: processingLatencyStats.n > 0 ? processingLatencyStats.mean : null,
        unit: 'ms',
        sampleSize: processingLatencyStats.n,
        notes: 'Mean whole-pipeline per-frame time (detection + risk assessment + logging), Stopwatch-measured.',
      ),
      MetricEntry(
        category: 'System Performance',
        name: 'Speech Latency',
        value: speechLatencyStats.n > 0 ? speechLatencyStats.mean : null,
        unit: 'ms',
        sampleSize: speechLatencyStats.n,
        notes: 'Mean AudioService.speak() call duration, Stopwatch-measured at the single TTS call site.',
      ),
      MetricEntry(
        category: 'System Performance',
        name: 'Memory Usage',
        value: (runtime.memorySamplingSupported && memoryStats.n > 0) ? memoryStats.mean : null,
        unit: 'bytes (RSS)',
        sampleSize: memoryStats.n,
        notes: runtime.memorySamplingSupported
            ? 'Mean of dart:io ProcessInfo.currentRss samples taken during frame processing.'
            : 'Not available — ProcessInfo.currentRss unsupported on this platform/run.',
      ),
    ]);

    // ---------------------------------------------------------------
    // STATISTICAL METRICS (full distributions, for CSV/JSON/MD)
    // ---------------------------------------------------------------
    final statisticalSummaries = <String, StatSummary>{
      'Detection Confidence': confidenceStats,
      'Detection Latency (ms)': detectionLatencyStats,
      'Processing Latency (ms)': processingLatencyStats,
      'Speech Latency (ms)': speechLatencyStats,
      'Memory Usage (bytes)': memoryStats,
      'Route Completion Time (s)': durationStats,
      'Route Completion Percentage': completionStats,
      'Hazard Clearance Latency (s)': StatisticsUtils.summarize(clearanceLatencyValues),
    };

    // ---------------------------------------------------------------
    // PAIRED COMPARISON — two most recent sessions, if both exist and
    // have equal-length per-episode sample arrays for a given metric.
    // ---------------------------------------------------------------
    final pairwiseComparisons = <String, PairedComparisonResult?>{};
    final pairwiseComparisonNotes = <String, String>{};

    final bySession = evaluationService.recordsBySession;
    final sessionIdsWithRecords = bySession.keys.toList()
      ..sort((a, b) => int.parse(a).compareTo(int.parse(b)));

    if (sessionIdsWithRecords.length >= 2) {
      final recentTwo = sessionIdsWithRecords.sublist(sessionIdsWithRecords.length - 2);
      final sessionA = bySession[recentTwo[0]]!;
      final sessionB = bySession[recentTwo[1]]!;

      final confA = sessionA.map((r) => r.detectionConfidence).toList();
      final confB = sessionB.map((r) => r.detectionConfidence).toList();
      final latA = sessionA.map((r) => r.processingLatencyMs).whereType<double>().toList();
      final latB = sessionB.map((r) => r.processingLatencyMs).whereType<double>().toList();

      final confComparison = StatisticsUtils.pairedComparison(confA, confB);
      pairwiseComparisons['Detection Confidence: session ${recentTwo[0]} vs ${recentTwo[1]}'] =
          confComparison;
      if (confComparison == null) {
        pairwiseComparisonNotes['Detection Confidence: session ${recentTwo[0]} vs ${recentTwo[1]}'] =
            'Sessions have unequal episode counts (${confA.length} vs ${confB.length}) — a paired test requires matching sample sizes.';
      }

      final latComparison = StatisticsUtils.pairedComparison(latA, latB);
      pairwiseComparisons['Detection Latency: session ${recentTwo[0]} vs ${recentTwo[1]}'] =
          latComparison;
      if (latComparison == null) {
        pairwiseComparisonNotes['Detection Latency: session ${recentTwo[0]} vs ${recentTwo[1]}'] =
            'Sessions have unequal episode counts (${latA.length} vs ${latB.length}) — a paired test requires matching sample sizes.';
      }
    } else {
      pairwiseComparisons['Session-to-session comparison'] = null;
      pairwiseComparisonNotes['Session-to-session comparison'] =
          'Fewer than two sessions with recorded hazard episodes exist yet (${sessionIdsWithRecords.length} found).';
    }

    return MetricsReport(
      generatedAt: DateTime.now(),
      entries: entries,
      statisticalSummaries: statisticalSummaries,
      pairwiseComparisons: pairwiseComparisons,
      pairwiseComparisonNotes: pairwiseComparisonNotes,
    );
  }

  /// Computes the report and writes all three export files to the
  /// app's documents directory, overwriting any previous export (the
  /// filenames are fixed, per requirement, so each completed testing
  /// session's export is the latest cumulative snapshot rather than a
  /// growing pile of timestamped files).
  ///
  /// Returns the three file paths, or null entries for any file that
  /// failed to write (logged, never thrown — this must never crash
  /// the app, matching every other export path in this codebase).
  ///
  /// NOTE ON CALL ORDER: [computeReport] itself is fully synchronous
  /// (no `await` anywhere in it) specifically so a caller in a
  /// synchronous context (e.g. a widget's `dispose()`) can compute the
  /// report BEFORE closing any of the Hive boxes it reads from, then
  /// hand the already-built, in-memory [MetricsReport] to
  /// [writeReportFiles] — which touches only the filesystem, never the
  /// Hive-backed services — as a separate, safely-later async step.
  /// See navigation_screen.dart's `dispose()` for exactly this pattern.
  Future<Map<String, String?>> computeAndExport({
    required EvaluationService evaluationService,
    required BehaviourLearningService behaviourLearningService,
    required NavigationMetricsTracker navigationMetricsTracker,
  }) async {
    final report = computeReport(
      evaluationService: evaluationService,
      behaviourLearningService: behaviourLearningService,
      navigationMetricsTracker: navigationMetricsTracker,
    );
    return writeReportFiles(report);
  }

  /// Writes an already-computed [MetricsReport] to disk. Touches only
  /// the filesystem (via path_provider) — no Hive box, no live
  /// service reference — so it's safe to call after those have been
  /// disposed.
  Future<Map<String, String?>> writeReportFiles(MetricsReport report) async {
    String? csvPath;
    String? jsonPath;
    String? mdPath;

    try {
      final directory = await getApplicationDocumentsDirectory();

      final csvFile = File('${directory.path}/$csvFileName');
      await csvFile.writeAsString(report.toCsv());
      csvPath = csvFile.path;

      final jsonFile = File('${directory.path}/$jsonFileName');
      await jsonFile.writeAsString(report.toJsonString());
      jsonPath = jsonFile.path;

      final mdFile = File('${directory.path}/$mdFileName');
      await mdFile.writeAsString(report.toMarkdown());
      mdPath = mdFile.path;
    } catch (e) {
      // ignore: avoid_print
      print('MetricsReportService: export failed (non-blocking): $e');
    }

    return {
      'csv': csvPath,
      'json': jsonPath,
      'md': mdPath,
    };
  }
}
