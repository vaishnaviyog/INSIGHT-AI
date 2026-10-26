import 'package:flutter/material.dart';

import '../../services/behaviour_learning_service.dart';
import '../../services/evaluation_service.dart';
import '../../services/research_aggregation_service.dart';
import 'session_replay_screen.dart';

const String _noData = 'Not enough data collected.';

/// Phase 5: a separate, researcher-facing dashboard. Distinct from
/// the AI Learning Dashboard (Phase 2, more end-user/dissertation-
/// demo framed) — this one leads with methodology-relevant metrics
/// and is explicit about what CANNOT currently be measured.
class ResearchDashboardScreen extends StatelessWidget {
  final BehaviourLearningService behaviourLearningService;
  final EvaluationService evaluationService;
  final ResearchAggregationService aggregation;

  const ResearchDashboardScreen({
    super.key,
    required this.behaviourLearningService,
    required this.evaluationService,
    required this.aggregation,
  });

  @override
  Widget build(BuildContext context) {
    final records = evaluationService.allRecords;
    final profile = behaviourLearningService.profile;
    final sessions = evaluationService.recordsBySession;

    return Scaffold(
      appBar: AppBar(title: const Text('Research Dashboard')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _section('Detection Quality'),
          _row(
            'Precision / Recall / F1',
            'NOT AVAILABLE. These require manually labeled ground-truth '
                'data (confirmed true/false positives), which this app has '
                'no mechanism to collect automatically. Reported here as '
                'unavailable rather than fabricated — see known limitations.',
          ),
          _row('Average detection confidence', _fmt(aggregation.averageDetectionConfidence(records))),
          _row('Average processing latency', _fmt(aggregation.averageProcessingLatencyMs(records), suffix: ' ms')),
          _detectorUsageRow(records),
          _section('Risk Distribution'),
          _riskDistributionRow(records),
          _row('Average risk score', _fmt(aggregation.averageRiskScore(records))),
          _row('Highest risk score', _fmt(aggregation.highestRiskScore(records))),
          _section('Behaviour Statistics'),
          _row('Sessions recorded', profile?.totalNavigationSessions.toString() ?? _noData),
          _row('Avg walking speed', profile != null && profile.speedSampleCount > 0
              ? '${profile.averageWalkingSpeed.toStringAsFixed(2)} m/s'
              : _noData),
          _row('Avg reaction time', profile != null && profile.reactionSampleCount > 0
              ? '${profile.averageReactionTime.toStringAsFixed(2)} s'
              : _noData),
          _row('Near misses', profile?.nearMisses.toString() ?? _noData),
          _row('Successful avoidances', profile?.successfulObstacleAvoidances.toString() ?? _noData),
          _section('Session Replay'),
          if (sessions.isEmpty)
            _row('Sessions', _noData)
          else
            ...sessions.keys.map((sessionId) => ListTile(
                  title: Text('Session $sessionId'),
                  subtitle: Text('${sessions[sessionId]!.length} recorded event(s)'),
                  trailing: const Icon(Icons.play_arrow),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (context) => SessionReplayScreen(
                      sessionId: sessionId,
                      records: sessions[sessionId]!,
                    ),
                  )),
                )),
          _section('Evaluation History'),
          _row('Total records logged', records.length.toString()),
          _row('Total sessions', sessions.length.toString()),
          _section('Export Status'),
          _row('Last export format', evaluationService.lastExportFormat ?? 'never exported'),
          _row('Last export path', evaluationService.lastExportPath ?? '—'),
          _row(
            'Last export time',
            evaluationService.lastExportTime?.toIso8601String() ?? '—',
          ),
        ],
      ),
    );
  }

  Widget _detectorUsageRow(records) {
    final usage = aggregation.detectorUsage(records);
    return _row(
      'Detector usage',
      usage.hasEnoughData ? usage.value!.entries.map((e) => '${e.key}=${e.value}').join(', ') : _noData,
    );
  }

  Widget _riskDistributionRow(records) {
    final dist = aggregation.riskLevelDistribution(records);
    return _row(
      'Risk level distribution',
      dist.hasEnoughData ? dist.value!.entries.map((e) => '${e.key}=${e.value}').join(', ') : _noData,
    );
  }

  String _fmt(ResearchStat stat, {String suffix = ''}) {
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
            SizedBox(width: 180, child: Text(label, style: const TextStyle(color: Colors.black54))),
            Expanded(child: Text(value)),
          ],
        ),
      );
}
