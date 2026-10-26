/// One row of `stops.txt`. `locationType`/`parentStation`/
/// `wheelchairBoarding` are standard-optional GTFS columns this
/// project's bundled feed doesn't include (it only has
/// `stop_id,stop_name,stop_lat,stop_lon`) — modeled here anyway,
/// nullable, so a future fuller-featured feed (e.g. one with proper
/// station/platform hierarchy) works without a model change.
class GtfsStop {
  final String stopId;
  final String stopName;
  final double stopLat;
  final double stopLon;
  final int? locationType;
  final String? parentStation;
  final int? wheelchairBoarding;

  const GtfsStop({
    required this.stopId,
    required this.stopName,
    required this.stopLat,
    required this.stopLon,
    this.locationType,
    this.parentStation,
    this.wheelchairBoarding,
  });

  Map<String, Object?> toDbMap() => {
        'stop_id': stopId,
        'stop_name': stopName,
        'stop_lat': stopLat,
        'stop_lon': stopLon,
        'location_type': locationType,
        'parent_station': parentStation,
        'wheelchair_boarding': wheelchairBoarding,
      };

  factory GtfsStop.fromDbMap(Map<String, Object?> map) => GtfsStop(
        stopId: map['stop_id'] as String,
        stopName: map['stop_name'] as String,
        stopLat: (map['stop_lat'] as num).toDouble(),
        stopLon: (map['stop_lon'] as num).toDouble(),
        locationType: map['location_type'] as int?,
        parentStation: map['parent_station'] as String?,
        wheelchairBoarding: map['wheelchair_boarding'] as int?,
      );
}
