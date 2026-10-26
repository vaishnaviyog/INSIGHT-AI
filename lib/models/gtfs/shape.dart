/// One point of `shapes.txt` — a vertex of a route's physical path
/// polyline. The bundled feed has 89 shape points, all for the 3
/// CMRL metro shape IDs — worth noting in the validation report that
/// no bus `trips.txt` row in this feed actually references a
/// `shape_id` (bus trips have no shape_id column at all in this
/// feed), so these shapes exist in the data but aren't yet linked
/// from any trip — a real data-completeness gap in the source feed,
/// not something this importer fabricates a link for.
class GtfsShapePoint {
  final String shapeId;
  final double shapePtLat;
  final double shapePtLon;
  final int shapePtSequence;
  final double? shapeDistTraveled;

  const GtfsShapePoint({
    required this.shapeId,
    required this.shapePtLat,
    required this.shapePtLon,
    required this.shapePtSequence,
    this.shapeDistTraveled,
  });

  Map<String, Object?> toDbMap() => {
        'shape_id': shapeId,
        'shape_pt_lat': shapePtLat,
        'shape_pt_lon': shapePtLon,
        'shape_pt_sequence': shapePtSequence,
        'shape_dist_traveled': shapeDistTraveled,
      };

  factory GtfsShapePoint.fromDbMap(Map<String, Object?> map) => GtfsShapePoint(
        shapeId: map['shape_id'] as String,
        shapePtLat: (map['shape_pt_lat'] as num).toDouble(),
        shapePtLon: (map['shape_pt_lon'] as num).toDouble(),
        shapePtSequence: map['shape_pt_sequence'] as int,
        shapeDistTraveled: (map['shape_dist_traveled'] as num?)?.toDouble(),
      );
}
