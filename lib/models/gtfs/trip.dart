/// One row of `trips.txt`. `tripHeadsign`/`shapeId` are standard-
/// optional columns absent from the bundled feed's bus rows — see
/// `GtfsImportService`'s doc comment on the CMRL metro rows, which
/// DO carry a 5th (shape-linking) field but in a form that doesn't
/// match this file's own declared header and is rejected as
/// malformed rather than guessed at.
class GtfsTrip {
  final String tripId;
  final String routeId;
  final String serviceId;
  final int? directionId;
  final String? tripHeadsign;
  final String? shapeId;

  const GtfsTrip({
    required this.tripId,
    required this.routeId,
    required this.serviceId,
    this.directionId,
    this.tripHeadsign,
    this.shapeId,
  });

  Map<String, Object?> toDbMap() => {
        'trip_id': tripId,
        'route_id': routeId,
        'service_id': serviceId,
        'direction_id': directionId,
        'trip_headsign': tripHeadsign,
        'shape_id': shapeId,
      };

  factory GtfsTrip.fromDbMap(Map<String, Object?> map) => GtfsTrip(
        tripId: map['trip_id'] as String,
        routeId: map['route_id'] as String,
        serviceId: map['service_id'] as String,
        directionId: map['direction_id'] as int?,
        tripHeadsign: map['trip_headsign'] as String?,
        shapeId: map['shape_id'] as String?,
      );
}
