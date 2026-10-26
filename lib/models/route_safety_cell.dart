/// One grid cell of aggregated risk history — the "heatmap-ready"
/// unit Phase 7 asks for. Deliberately just a data structure: no map
/// rendering is implemented here, so a future GIS/mapping layer (or
/// `flutter_map`, already a dependency) can consume this list however
/// it likes without this module needing to change.
class RouteSafetyCell {
  final double latitude;
  final double longitude;
  final double averageRiskScore;
  final int incidentCount;

  /// Most frequently detected hazard type in this cell — a simple,
  /// real, non-fabricated summary statistic.
  final String dominantHazardType;

  const RouteSafetyCell({
    required this.latitude,
    required this.longitude,
    required this.averageRiskScore,
    required this.incidentCount,
    required this.dominantHazardType,
  });

  Map<String, dynamic> toJson() => {
        'latitude': latitude,
        'longitude': longitude,
        'averageRiskScore': averageRiskScore,
        'incidentCount': incidentCount,
        'dominantHazardType': dominantHazardType,
      };
}
