/// One row of `calendar.txt` — a weekly service pattern. `serviceId`
/// is validated by `GtfsImportService` against a safe identifier
/// pattern before import (see that file's doc comment): the bundled
/// feed's `calendar.txt` contains a literal script-injection payload
/// as a `service_id` value, which this validation rejects rather than
/// storing verbatim.
class GtfsCalendar {
  final String serviceId;
  final bool monday;
  final bool tuesday;
  final bool wednesday;
  final bool thursday;
  final bool friday;
  final bool saturday;
  final bool sunday;
  final String startDate; // GTFS "YYYYMMDD"
  final String endDate;

  const GtfsCalendar({
    required this.serviceId,
    required this.monday,
    required this.tuesday,
    required this.wednesday,
    required this.thursday,
    required this.friday,
    required this.saturday,
    required this.sunday,
    required this.startDate,
    required this.endDate,
  });

  Map<String, Object?> toDbMap() => {
        'service_id': serviceId,
        'monday': monday ? 1 : 0,
        'tuesday': tuesday ? 1 : 0,
        'wednesday': wednesday ? 1 : 0,
        'thursday': thursday ? 1 : 0,
        'friday': friday ? 1 : 0,
        'saturday': saturday ? 1 : 0,
        'sunday': sunday ? 1 : 0,
        'start_date': startDate,
        'end_date': endDate,
      };

  factory GtfsCalendar.fromDbMap(Map<String, Object?> map) => GtfsCalendar(
        serviceId: map['service_id'] as String,
        monday: (map['monday'] as int) == 1,
        tuesday: (map['tuesday'] as int) == 1,
        wednesday: (map['wednesday'] as int) == 1,
        thursday: (map['thursday'] as int) == 1,
        friday: (map['friday'] as int) == 1,
        saturday: (map['saturday'] as int) == 1,
        sunday: (map['sunday'] as int) == 1,
        startDate: map['start_date'] as String,
        endDate: map['end_date'] as String,
      );
}
