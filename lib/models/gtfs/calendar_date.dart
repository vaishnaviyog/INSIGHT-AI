/// One row of `calendar_dates.txt` — a service exception (added or
/// removed service on a specific date), layered on top of
/// `calendar.txt`'s weekly pattern. THIS FILE IS ABSENT from the
/// bundled Chennai feed — a real, deliberate test of "handle missing
/// optional files gracefully" (see `GtfsImportService`), not a gap in
/// this model.
class GtfsCalendarDate {
  final String serviceId;
  final String date; // GTFS "YYYYMMDD"
  final int exceptionType; // 1 = service added, 2 = service removed

  const GtfsCalendarDate({
    required this.serviceId,
    required this.date,
    required this.exceptionType,
  });

  Map<String, Object?> toDbMap() => {
        'service_id': serviceId,
        'date': date,
        'exception_type': exceptionType,
      };

  factory GtfsCalendarDate.fromDbMap(Map<String, Object?> map) => GtfsCalendarDate(
        serviceId: map['service_id'] as String,
        date: map['date'] as String,
        exceptionType: map['exception_type'] as int,
      );
}
