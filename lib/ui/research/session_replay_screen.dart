import 'package:flutter/material.dart';
import '../../models/evaluation_record.dart';

/// Phase 6: replays one navigation session as a timeline, built
/// entirely from that session's [EvaluationRecord]s — no synthetic
/// steps. "Destination reached" is honestly labeled as not currently
/// tracked (this app has no explicit "arrived" event yet) rather than
/// inferred or guessed.
class SessionReplayScreen extends StatelessWidget {
  final String sessionId;
  final List<EvaluationRecord> records;

  const SessionReplayScreen({super.key, required this.sessionId, required this.records});

  @override
  Widget build(BuildContext context) {
    final sorted = [...records]..sort((a, b) => a.detectionTimestamp.compareTo(b.detectionTimestamp));

    return Scaffold(
      appBar: AppBar(title: Text('Session Replay — $sessionId')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _timelineEntry(Icons.play_circle_outline, 'Session started', null),
          for (final record in sorted) ..._recordTimeline(record),
          _timelineEntry(
            Icons.flag_outlined,
            'Destination reached',
            'Not currently tracked — this app has no explicit arrival event yet.',
          ),
        ],
      ),
    );
  }

  List<Widget> _recordTimeline(EvaluationRecord record) {
    return [
      const Divider(height: 32),
      _timelineEntry(
        Icons.visibility,
        'Hazard detected: ${record.objectType}',
        '${record.detectionTimestamp.toIso8601String()} · confidence '
            '${record.detectionConfidence.toStringAsFixed(2)} · source ${record.detectorSource}',
      ),
      _timelineEntry(
        Icons.calculate_outlined,
        'Risk calculated',
        'score ${record.riskScore.toStringAsFixed(2)} · level ${record.riskLevel}',
      ),
      if (record.voiceWarningTimestamp != null)
        _timelineEntry(
          Icons.record_voice_over,
          'Voice warning',
          '${record.voiceWarningTimestamp!.toIso8601String()} · mode: ${record.adaptiveGuidanceMode}',
        )
      else
        _timelineEntry(Icons.volume_off, 'Voice warning', 'Not spoken (suppressed by guidance decision)'),
      if (record.hazardClearanceTimestamp != null) ...[
        _timelineEntry(
          Icons.check_circle_outline,
          'Hazard cleared',
          record.hazardClearanceLatencySeconds != null
              ? '${record.hazardClearanceTimestamp!.toIso8601String()} · clearance latency '
                  '${record.hazardClearanceLatencySeconds!.toStringAsFixed(2)}s'
              : record.hazardClearanceTimestamp!.toIso8601String(),
        ),
        _timelineEntry(Icons.trending_down, 'Risk reduced', 'Hazard no longer present in frame'),
      ] else
        _timelineEntry(Icons.help_outline, 'Hazard clearance', 'Not recorded — session may have ended first'),
    ];
  }

  Widget _timelineEntry(IconData icon, String title, String? subtitle) => ListTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: subtitle != null ? Text(subtitle) : null,
      );
}
