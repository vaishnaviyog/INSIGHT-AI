import '../../models/gtfs/stop.dart';
import '../location_service.dart';
import 'gtfs_query_service.dart';

/// Wires GPS (the app's EXISTING `LocationService` — not a new
/// location integration) to `GtfsQueryService`'s spatial queries.
/// Scope for this stage is deliberately narrow, per the brief: nearest
/// bus stop and nearest metro station only — no route guidance, no
/// walking-plus-transit planning (that's `NavigationPlanner`, a later
/// stage).
class GtfsLocationService {
  final LocationService locationService;
  final GtfsQueryService queryService;

  GtfsLocationService({required this.locationService, required this.queryService});

  /// Null if the current GPS position is unavailable (permission
  /// denied, GPS off, no fix yet) — matches `LocationService
  /// .getCurrentLocation()`'s own nullable return, never a fabricated
  /// fallback position.
  Future<GtfsStop?> nearestBusStop() async {
    final position = await locationService.getCurrentLocation();
    if (position == null) return null;
    return queryService.getNearestStop(latitude: position.latitude, longitude: position.longitude);
  }

  /// See `GtfsQueryService.getNearestMetroStation`'s doc comment for a
  /// known data-quality limitation: the bundled feed's metro routes
  /// currently fail import validation, so this will honestly return
  /// null until that source data issue is fixed.
  Future<GtfsStop?> nearestMetroStation() async {
    final position = await locationService.getCurrentLocation();
    if (position == null) return null;
    return queryService.getNearestMetroStation(latitude: position.latitude, longitude: position.longitude);
  }
}
