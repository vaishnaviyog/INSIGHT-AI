/// One row of `routes.txt`. `routeColor`/`routeTextColor` are
/// standard-optional columns not present in the bundled feed —
/// nullable for forward compatibility with a fuller feed later.
class GtfsRoute {
  final String routeId;
  final String? agencyId;
  final String? routeShortName;
  final String? routeLongName;
  final int routeType;
  final String? routeColor;
  final String? routeTextColor;

  const GtfsRoute({
    required this.routeId,
    required this.routeType,
    this.agencyId,
    this.routeShortName,
    this.routeLongName,
    this.routeColor,
    this.routeTextColor,
  });

  Map<String, Object?> toDbMap() => {
        'route_id': routeId,
        'agency_id': agencyId,
        'route_short_name': routeShortName,
        'route_long_name': routeLongName,
        'route_type': routeType,
        'route_color': routeColor,
        'route_text_color': routeTextColor,
      };

  factory GtfsRoute.fromDbMap(Map<String, Object?> map) => GtfsRoute(
        routeId: map['route_id'] as String,
        agencyId: map['agency_id'] as String?,
        routeShortName: map['route_short_name'] as String?,
        routeLongName: map['route_long_name'] as String?,
        routeType: map['route_type'] as int,
        routeColor: map['route_color'] as String?,
        routeTextColor: map['route_text_color'] as String?,
      );
}
