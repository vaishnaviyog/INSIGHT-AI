/// One row of `stop_times.txt` — the largest table by far (~1.36M
/// rows in the bundled Chennai feed). `arrivalTime`/`departureTime`
/// are kept as GTFS's own raw `"HH:MM:SS"` strings (NOT parsed into
/// `DateTime`): GTFS explicitly allows hour values >= 24 for trips
/// that run past midnight (e.g. "25:30:00"), which `DateTime`/
/// `TimeOfDay` can't represent directly — comparisons/arithmetic on
/// these are done as seconds-since-midnight by whichever future
/// service needs them (`NavigationPlanner`, not built in this stage),
/// not baked into this model.
class GtfsStopTime {
  final String tripId;
  final String arrivalTime;
  final String departureTime;
  final String stopId;
  final int stopSequence;
  final int? pickupType;
  final int? dropOffType;

  const GtfsStopTime({
    required this.tripId,
    required this.arrivalTime,
    required this.departureTime,
    required this.stopId,
    required this.stopSequence,
    this.pickupType,
    this.dropOffType,
  });

  Map<String, Object?> toDbMap() => {
        'trip_id': tripId,
        'arrival_time': arrivalTime,
        'departure_time': departureTime,
        'stop_id': stopId,
        'stop_sequence': stopSequence,
        'pickup_type': pickupType,
        'drop_off_type': dropOffType,
      };

  factory GtfsStopTime.fromDbMap(Map<String, Object?> map) => GtfsStopTime(
        tripId: map['trip_id'] as String,
        arrivalTime: map['arrival_time'] as String,
        departureTime: map['departure_time'] as String,
        stopId: map['stop_id'] as String,
        stopSequence: map['stop_sequence'] as int,
        pickupType: map['pickup_type'] as int?,
        dropOffType: map['drop_off_type'] as int?,
      );
}
