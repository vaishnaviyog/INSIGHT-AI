/// One row of `agency.txt`. Only `agencyId`, `agencyName`, `agencyUrl`,
/// and `agencyTimezone` are required by the GTFS spec; `agencyLang` and
/// every other optional standard field are nullable. This project's
/// bundled Chennai feed has exactly these 5 columns (see
/// `GtfsImportService` for the header-driven column mapping that
/// makes this work regardless of column order or which optional
/// columns are present).
class GtfsAgency {
  final String agencyId;
  final String agencyName;
  final String agencyUrl;
  final String agencyTimezone;
  final String? agencyLang;

  const GtfsAgency({
    required this.agencyId,
    required this.agencyName,
    required this.agencyUrl,
    required this.agencyTimezone,
    this.agencyLang,
  });

  Map<String, Object?> toDbMap() => {
        'agency_id': agencyId,
        'agency_name': agencyName,
        'agency_url': agencyUrl,
        'agency_timezone': agencyTimezone,
        'agency_lang': agencyLang,
      };

  factory GtfsAgency.fromDbMap(Map<String, Object?> map) => GtfsAgency(
        agencyId: map['agency_id'] as String,
        agencyName: map['agency_name'] as String,
        agencyUrl: map['agency_url'] as String,
        agencyTimezone: map['agency_timezone'] as String,
        agencyLang: map['agency_lang'] as String?,
      );
}
