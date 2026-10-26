import '../models/evaluation_record.dart';

/// A single computed statistic, always paired with whether there was
/// enough data to compute it — used everywhere in the research
/// dashboards to enforce "never fabricate statistics".
class ResearchStat<T> {
  final T? value;
  final bool hasEnoughData;
  const ResearchStat(this.value, this.hasEnoughData);
  const ResearchStat.insufficient()
      : value = null,
        hasEnoughData = false;
}

/// Computes shared statistics from [EvaluationRecord]s. Used by both
/// the AI Learning Dashboard (Phase 2) and Research Dashboard (Phase
/// 5) so the two screens can never silently disagree about how a
/// number was computed.
///
/// EVERY method here returns [ResearchStat], which is explicitly
/// either a real value or "not enough data" — there is no code path
/// that returns a plausible-looking placeholder number.
class ResearchAggregationService {
  static const int _minRecordsForDistribution = 3;
  static const int _minRecordsForTrend = 10;

  ResearchStat<double> averageRiskScore(List<EvaluationRecord> records) {
    if (records.isEmpty) return const ResearchStat.insufficient();
    final avg = records.map((r) => r.riskScore).reduce((a, b) => a + b) / records.length;
    return ResearchStat(avg, true);
  }

  ResearchStat<double> highestRiskScore(List<EvaluationRecord> records) {
    if (records.isEmpty) return const ResearchStat.insufficient();
    return ResearchStat(records.map((r) => r.riskScore).reduce((a, b) => a > b ? a : b), true);
  }

  ResearchStat<Map<String, int>> riskLevelDistribution(List<EvaluationRecord> records) {
    if (records.length < _minRecordsForDistribution) return const ResearchStat.insufficient();
    final dist = <String, int>{};
    for (final r in records) {
      dist[r.riskLevel] = (dist[r.riskLevel] ?? 0) + 1;
    }
    return ResearchStat(dist, true);
  }

  ResearchStat<String> mostDangerousObject(List<EvaluationRecord> records) {
    if (records.isEmpty) return const ResearchStat.insufficient();
    final byObject = <String, List<double>>{};
    for (final r in records) {
      byObject.putIfAbsent(r.objectType, () => []).add(r.riskScore);
    }
    String? best;
    double bestAvg = -1;
    for (final entry in byObject.entries) {
      final avg = entry.value.reduce((a, b) => a + b) / entry.value.length;
      if (avg > bestAvg) {
        bestAvg = avg;
        best = entry.key;
      }
    }
    return ResearchStat(best, true);
  }

  ResearchStat<Map<String, int>> detectorUsage(List<EvaluationRecord> records) {
    if (records.isEmpty) return const ResearchStat.insufficient();
    final usage = <String, int>{};
    for (final r in records) {
      usage[r.detectorSource] = (usage[r.detectorSource] ?? 0) + 1;
    }
    return ResearchStat(usage, true);
  }

  ResearchStat<double> averageDetectionConfidence(List<EvaluationRecord> records) {
    if (records.isEmpty) return const ResearchStat.insufficient();
    final avg = records.map((r) => r.detectionConfidence).reduce((a, b) => a + b) / records.length;
    return ResearchStat(avg, true);
  }

  ResearchStat<double> averageProcessingLatencyMs(List<EvaluationRecord> records) {
    final withLatency = records.where((r) => r.processingLatencyMs != null).toList();
    if (withLatency.isEmpty) return const ResearchStat.insufficient();
    final avg = withLatency.map((r) => r.processingLatencyMs!).reduce((a, b) => a + b) / withLatency.length;
    return ResearchStat(avg, true);
  }

  int warningCount(List<EvaluationRecord> records) =>
      records.where((r) => r.voiceWarningTimestamp != null).length;

  /// AUDIT FIX (P0-5): renamed from `averageReactionTime` — this is a
  /// warning-to-hazard-clearance latency average, not a measured human
  /// reaction time. See EvaluationRecord.hazardClearanceLatencySeconds's
  /// doc comment for why.
  ResearchStat<double> averageHazardClearanceLatency(List<EvaluationRecord> records) {
    final withClearance = records.where((r) => r.hazardClearanceLatencySeconds != null).toList();
    if (withClearance.isEmpty) return const ResearchStat.insufficient();
    final avg = withClearance.map((r) => r.hazardClearanceLatencySeconds!).reduce((a, b) => a + b) / withClearance.length;
    return ResearchStat(avg, true);
  }

  /// Compares the first half vs second half of chronologically
  /// ordered records for a numeric field — the basis for Phase 2's
  /// "Performance Improvement" section. Positive = improved (lower is
  /// better, e.g. reaction time); interpretation is left to the
  /// caller since "improvement" direction differs per metric.
  ResearchStat<double> firstVsSecondHalfDelta(
    List<EvaluationRecord> records,
    double? Function(EvaluationRecord) selector,
  ) {
    final values = records.map(selector).whereType<double>().toList();
    if (values.length < _minRecordsForTrend) return const ResearchStat.insufficient();

    final mid = values.length ~/ 2;
    final firstHalf = values.sublist(0, mid);
    final secondHalf = values.sublist(mid);
    final firstAvg = firstHalf.reduce((a, b) => a + b) / firstHalf.length;
    final secondAvg = secondHalf.reduce((a, b) => a + b) / secondHalf.length;
    return ResearchStat(secondAvg - firstAvg, true);
  }
}
