import '../models/evaluation_record.dart';
import '../models/route_safety_cell.dart';

/// Builds heatmap-ready [RouteSafetyCell] data from historical
/// [EvaluationRecord]s. Purely a data-aggregation module — no map
/// rendering, no routing engine, no GIS integration; those are
/// explicitly named as future work in the Phase 7 brief, and this
/// class's output shape is designed so a future GIS layer could
/// consume it directly.
///
/// GRID PRECISION NOTE: uses the same 4-decimal-place grid bucketing
/// concept as `BehaviourLearningService` (M2), reimplemented here
/// rather than calling into it, because `BehaviourLearningService`'s
/// grid-key method is private and M2 is a completed milestone that
/// should not be modified to expose it. This is a small, explicitly
/// justified duplication — documented rather than silently
/// introduced.
class RouteSafetyService {
  static const int _gridPrecision = 4;

  /// Aggregates all records with GPS coordinates into grid cells,
  /// each with an average risk score, incident count, and the most
  /// common hazard type seen there.
  List<RouteSafetyCell> buildSafetyMap(List<EvaluationRecord> records) {
    final withGps = records.where((r) => r.gpsLatitude != null && r.gpsLongitude != null).toList();
    if (withGps.isEmpty) return [];

    final Map<String, List<EvaluationRecord>> grouped = {};
    for (final record in withGps) {
      final key = _gridKey(record.gpsLatitude!, record.gpsLongitude!);
      grouped.putIfAbsent(key, () => []).add(record);
    }

    final cells = <RouteSafetyCell>[];
    for (final entry in grouped.entries) {
      final cellRecords = entry.value;
      final avgRisk = cellRecords.map((r) => r.riskScore).reduce((a, b) => a + b) / cellRecords.length;

      final hazardCounts = <String, int>{};
      for (final r in cellRecords) {
        hazardCounts[r.objectType] = (hazardCounts[r.objectType] ?? 0) + 1;
      }
      final dominant = hazardCounts.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

      cells.add(RouteSafetyCell(
        latitude: cellRecords.first.gpsLatitude!,
        longitude: cellRecords.first.gpsLongitude!,
        averageRiskScore: avgRisk,
        incidentCount: cellRecords.length,
        dominantHazardType: dominant,
      ));
    }

    cells.sort((a, b) => b.averageRiskScore.compareTo(a.averageRiskScore));
    return cells;
  }

  /// Top-N riskiest cells — "frequently risky locations" / "dangerous
  /// intersections" in Phase 7's terms.
  List<RouteSafetyCell> mostDangerousLocations(List<EvaluationRecord> records, {int limit = 5}) {
    final all = buildSafetyMap(records);
    return all.take(limit).toList();
  }

  String _gridKey(double lat, double lng) =>
      '${lat.toStringAsFixed(_gridPrecision)},${lng.toStringAsFixed(_gridPrecision)}';
}
