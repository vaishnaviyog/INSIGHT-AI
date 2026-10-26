/// Contract for a future data source that can supply real pedestrian
/// availability, road width, traffic intensity, or lighting data near
/// a point — e.g. an Overpass API (OpenStreetMap tag) lookup, a
/// municipal open-data feed, or a commercial traffic API.
///
/// NO IMPLEMENTATION EXISTS YET. This interface mirrors the same
/// swappable-provider pattern already used throughout this codebase
/// (IHazardDetector, ITranslationProvider, IBehaviourSignalSource,
/// IEmergencySignalSource): [SafeRouteService] is written against
/// this interface today, so a future data source becomes usable by
/// implementing it and passing an instance in — no change to
/// [SafeRouteService] itself.
///
/// Returning `null` (rather than a fabricated neutral value) for a
/// point with no available data is required — [SafeRouteService]
/// treats `null` as "this signal is unavailable for this route" and
/// excludes it from the weighted score entirely, rather than diluting
/// the score with a made-up number.
abstract class RoadAttributesProvider {
  /// A risk contribution in [0.0, 1.0] (0 = safest, 1 = riskiest)
  /// summarizing pedestrian availability, road width, traffic
  /// intensity, and lighting near the given point — or `null` if none
  /// of that data is available for this location.
  Future<double?> riskContributionNear(double latitude, double longitude);
}
