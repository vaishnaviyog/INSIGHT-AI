import 'package:flutter/material.dart';

import '../../services/evaluation_service.dart';
import '../../services/route_safety_service.dart';

const String _noData = 'Not enough data collected.';

/// Phase 7: displays the heatmap-ready [RouteSafetyCell] data as a
/// list (no map rendering implemented — see RouteSafetyService's doc
/// comment on why that's deliberately out of scope here, left for a
/// future GIS integration).
class RouteSafetyScreen extends StatelessWidget {
  final EvaluationService evaluationService;
  final RouteSafetyService routeSafetyService;

  const RouteSafetyScreen({
    super.key,
    required this.evaluationService,
    required this.routeSafetyService,
  });

  @override
  Widget build(BuildContext context) {
    final records = evaluationService.allRecords;
    final cells = routeSafetyService.buildSafetyMap(records);

    return Scaffold(
      appBar: AppBar(title: const Text('Route Safety Intelligence')),
      body: cells.isEmpty
          ? const Center(child: Text(_noData))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Heatmap-ready data (no map renderer implemented yet — '
                  'each row below is one aggregated grid cell, sorted by average risk).',
                  style: TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 12),
                Text('Frequently risky locations (top ${cells.length.clamp(0, 5)}):',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                for (final cell in cells.take(5))
                  ListTile(
                    leading: const Icon(Icons.warning_amber_outlined),
                    title: Text('${cell.latitude.toStringAsFixed(5)}, ${cell.longitude.toStringAsFixed(5)}'),
                    subtitle: Text(
                      'avg risk ${cell.averageRiskScore.toStringAsFixed(2)} · '
                      '${cell.incidentCount} incident(s) · most common: ${cell.dominantHazardType}',
                    ),
                  ),
                const Divider(height: 32),
                const Text('All cells (raw data):', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final cell in cells)
                  Text(
                    '${cell.latitude.toStringAsFixed(5)},${cell.longitude.toStringAsFixed(5)} '
                    'risk=${cell.averageRiskScore.toStringAsFixed(2)} n=${cell.incidentCount}',
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
              ],
            ),
    );
  }
}
