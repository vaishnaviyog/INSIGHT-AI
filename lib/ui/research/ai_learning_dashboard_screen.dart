import 'package:flutter/material.dart';

import '../../services/ai_recommendation_engine.dart';
import '../../services/behaviour_learning_service.dart';
import '../../services/emergency_service.dart';
import '../../services/evaluation_service.dart';
import '../../services/research_aggregation_service.dart';
import '../../services/explainable_ai_service.dart';

const String _noData = 'Not enough data collected.';

/// Phase 2: visualizes REAL collected data only. Every section either
/// shows a genuine computed value or the literal string
/// "Not enough data collected." — there is no synthetic/placeholder
/// data path anywhere in this screen.
class AiLearningDashboardScreen extends StatelessWidget {
  final BehaviourLearningService behaviourLearningService;
  final EvaluationService evaluationService;
  final EmergencyService emergencyService;
  final AIRecommendationEngine recommendationEngine;
  final ResearchAggregationService aggregation;

  /// Phase 3 (Explainable AI Engine) output for the most recently
  /// detected hazard, if any — this dashboard shows the LATEST
  /// explanation only (full explanation history isn't persisted per
  /// record in this version; see known limitations).
  final ExplanationResult? lastExplanation;

  const AiLearningDashboardScreen({
    super.key,
    required this.behaviourLearningService,
    required this.evaluationService,
    required this.emergencyService,
    required this.recommendationEngine,
    required this.aggregation,
    this.lastExplanation,
  });

  @override
  Widget build(BuildContext context) {
    final profile = behaviourLearningService.profile;
    final records = evaluationService.allRecords;

    return Scaffold(
      appBar: AppBar(title: const Text('AI Learning Dashboard')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('1. Overview'),
          _row('Navigation sessions', profile?.totalNavigationSessions.toString() ?? _noData),
          _row('Distance walked',
              profile != null ? '${profile.totalWalkingDistanceMeters.toStringAsFixed(1)} m' : _noData),
          _row('Walking time', 'Not currently tracked (see known limitations)'),
          _row(
            'AI learning progress',
            profile != null
                ? '${((profile.totalNavigationSessions / 20.0).clamp(0.0, 1.0) * 100).toStringAsFixed(0)}% '
                    '(based on session count, not a trained-model metric)'
                : _noData,
          ),
          _row('Behaviour confidence', profile != null ? profile.confidenceScore.toStringAsFixed(2) : _noData),
          _section('2. Behaviour'),
          _row('Walking speed (avg)',
              profile != null && profile.speedSampleCount > 0
                  ? '${profile.averageWalkingSpeed.toStringAsFixed(2)} m/s'
                  : _noData),
          _row('Reaction time (avg)',
              profile != null && profile.reactionSampleCount > 0
                  ? '${profile.averageReactionTime.toStringAsFixed(2)} s'
                  : _noData),
          _row('Route familiarity', profile != null ? profile.routeFamiliarityScore.toStringAsFixed(2) : _noData),
          _row('Turning preference', profile?.preferredTurningDirection ?? 'none yet'),
          _row('Near misses', profile?.nearMisses.toString() ?? _noData),
          _row('Successful avoidances', profile?.successfulObstacleAvoidances.toString() ?? _noData),
          _section('3. Risk Intelligence'),
          ..._riskIntelligenceRows(records),
          _section('4. AI Learning Summary'),
          if (lastExplanation != null) ...[
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text('Most recent explanation (Phase 3):', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
            _row('Reason', lastExplanation!.reason),
            _row('Recommendation', lastExplanation!.recommendation),
            _row('Confidence', lastExplanation!.confidence.toStringAsFixed(2)),
            const SizedBox(height: 8),
          ],
          ..._learningSummaryRows(profile, records),
          const Padding(
            padding: EdgeInsets.only(top: 12, bottom: 4),
            child: Text('Recommendations (Phase 4):', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
          ...recommendationEngine.generateRecommendations(profile).map((r) => _row('•', r)),
          _section('5. Safety'),
          _row('Hazards detected', records.length.toString()),
          _row('Emergency events', emergencyService.eventLog.length.toString()),
          _row('Warning count', aggregation.warningCount(records).toString()),
          _row('Sessions completed', profile?.totalNavigationSessions.toString() ?? _noData),
          _section('6. Navigation History'),
          _row('Learned locations', profile?.frequentlyVisitedLocations.length.toString() ?? _noData),
          _row('Sessions logged', evaluationService.recordsBySession.length.toString()),
          _section('7. Performance Improvement'),
          ..._improvementRows(records),
          _section('8. Research Metrics'),
          _row('Average confidence', _statOrNoData(aggregation.averageDetectionConfidence(records))),
          ..._detectorUsageRows(records),
          _row(
            'Precision / Recall / F1',
            'Not available — requires manually labeled ground truth, '
                'which this app does not currently collect. See known limitations.',
          ),
          _section('9. Export'),
          _exportButtons(context),
        ],
      ),
    );
  }

  List<Widget> _riskIntelligenceRows(records) {
    final avg = aggregation.averageRiskScore(records);
    final highest = aggregation.highestRiskScore(records);
    final dangerous = aggregation.mostDangerousObject(records);
    final distribution = aggregation.riskLevelDistribution(records);
    final usage = aggregation.detectorUsage(records);

    return [
      _row('Average risk', _statOrNoData(avg)),
      _row('Highest risk', _statOrNoData(highest)),
      _row('Most dangerous object', dangerous.hasEnoughData ? dangerous.value! : _noData),
      _row(
        'Risk distribution',
        distribution.hasEnoughData
            ? distribution.value!.entries.map((e) => '${e.key}=${e.value}').join(', ')
            : _noData,
      ),
      _row(
        'Detector usage',
        usage.hasEnoughData ? usage.value!.entries.map((e) => '${e.key}=${e.value}').join(', ') : _noData,
      ),
    ];
  }

  List<Widget> _learningSummaryRows(profile, records) {
    if (profile == null || records.isEmpty) {
      return [_row('Observations', _noData)];
    }
    final observations = <String>[];
    final dangerous = aggregation.mostDangerousObject(records);
    if (dangerous.hasEnoughData) {
      observations.add('Most frequently significant hazard: ${dangerous.value}.');
    }
    if (profile.preferredTurningDirection != null) {
      observations.add('User shows a preference for turning ${profile.preferredTurningDirection}.');
    }
    final clearanceTrend = aggregation.firstVsSecondHalfDelta(records, (r) => r.hazardClearanceLatencySeconds);
    if (clearanceTrend.hasEnoughData) {
      observations.add(clearanceTrend.value! < 0
          ? 'Hazard clearance latency has improved (decreased) across recorded sessions.'
          : 'Hazard clearance latency has increased across recorded sessions — worth monitoring.');
    }
    if (observations.isEmpty) observations.add(_noData);
    return observations.map((o) => _row('•', o)).toList();
  }

  List<Widget> _improvementRows(records) {
    // NOTE (P0-5): this is warning-to-hazard-clearance latency, not a
    // measured human reaction time — see
    // EvaluationRecord.hazardClearanceLatencySeconds's doc comment.
    final clearanceDelta = aggregation.firstVsSecondHalfDelta(records, (r) => r.hazardClearanceLatencySeconds);
    final speedDelta = aggregation.firstVsSecondHalfDelta(records, (r) => r.walkingSpeedMetersPerSecond);
    return [
      _row('Hazard clearance latency change', _statOrNoData(clearanceDelta, suffix: ' s (negative = faster)')),
      _row('Walking speed change', _statOrNoData(speedDelta, suffix: ' m/s')),
      _row(
        'Near miss reduction',
        'Requires per-period comparison — not yet computed (see known limitations).',
      ),
    ];
  }

  List<Widget> _detectorUsageRows(records) {
    final usage = aggregation.detectorUsage(records);
    if (!usage.hasEnoughData) return [_row('Detector usage', _noData)];
    return [_row('Detector usage', usage.value!.entries.map((e) => '${e.key}=${e.value}').join(', '))];
  }

  Widget _exportButtons(BuildContext context) => Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          ElevatedButton(
            onPressed: () async {
              final path = await evaluationService.exportToCsv();
              _showResult(context, path, 'CSV');
            },
            child: const Text('Export CSV'),
          ),
          ElevatedButton(
            onPressed: () async {
              final path = await evaluationService.exportToJson();
              _showResult(context, path, 'JSON');
            },
            child: const Text('Export JSON'),
          ),
          ElevatedButton(
            onPressed: () => _showResult(context, null, 'Report (see Research Dashboard)'),
            child: const Text('Export Report'),
          ),
        ],
      );

  void _showResult(BuildContext context, String? path, String label) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(path != null ? '$label exported to: $path' : '$label export: no data to export yet.'),
    ));
  }

  String _statOrNoData(ResearchStat stat, {String suffix = ''}) {
    if (!stat.hasEnoughData || stat.value == null) return _noData;
    final v = stat.value;
    if (v is double) return '${v.toStringAsFixed(2)}$suffix';
    return '$v$suffix';
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 160, child: Text(label, style: const TextStyle(color: Colors.black54))),
            Expanded(child: Text(value)),
          ],
        ),
      );
}
