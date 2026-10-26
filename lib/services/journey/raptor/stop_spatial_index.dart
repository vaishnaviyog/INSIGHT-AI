import 'dart:math';

import '../../../models/gtfs/stop.dart';

/// A uniform-grid spatial index over a fixed set of [GtfsStop]s, built
/// ONCE and queried many times — replaces a brute-force "compute
/// haversine distance to every stop in the whole feed" scan with a
/// lookup into the handful of grid cells that could possibly contain a
/// stop within [cellSizeMeters] of the query point.
///
/// WHY THIS EXISTS (RAPTOR + footpath optimization, Phase A):
/// `RaptorRouter`'s footpath-relaxation step (Step B) previously did
/// exactly that brute-force scan — for every stop improved in a round,
/// it computed a haversine distance to ALL ~5,580 stops in the bundled
/// Chennai feed, discarding the ~99% that turned out to be outside the
/// walking radius. Measured on a real Android device: this step alone
/// (`step_b_ms`) accounted for ~98% of total RAPTOR time (~54.1s of
/// ~55.2s) for a single representative journey search, with the cost
/// growing round-over-round as the reachable-stop frontier expanded
/// (by round 5, nearly the whole feed's ~5,580 stops had been
/// "newly marked," each triggering its own full 5,580-stop scan — see
/// `RaptorRouter`'s own `footpathCandidateScans` diagnostic, which hit
/// 28.7 million in round 5 alone).
///
/// CORRECTNESS: built with [cellSizeMeters] set to the exact walking
/// radius the caller will query with (`RaptorRouter.walkingRadiusMeters`
/// — see that class's constructor). With cell size >= query radius, any
/// point within the query radius of a given coordinate is guaranteed to
/// fall within that coordinate's own grid cell or one of its 8
/// immediate neighbors (a standard grid-index correctness property —
/// see [candidatesNear]'s doc comment for the short proof) — so
/// scanning that 3x3 neighborhood can NEVER miss a genuinely-nearby
/// stop. The exact haversine distance check the caller already performs
/// on each candidate is UNCHANGED — this index only narrows which
/// stops that exact check runs against, it never approximates or skips
/// the real distance calculation for a stop it does return.
///
/// A single reference latitude (the mean of all indexed stops' latitude
/// — Chennai's real stop set spans under 0.5° of latitude) is used to
/// convert the longitude cell size from meters to degrees. This is the
/// same simplification `GtfsQueryService.getNearbyStops`'s bounding-box
/// pre-filter already makes for a single query point; using one
/// reference value for the whole grid (rather than a per-stop cosine)
/// is accurate to well under 1% over a ~40km metro area and avoids
/// needing a different cell size per latitude band.
class StopSpatialIndex {
  final double cellSizeMeters;
  final double _latCellSizeDegrees;
  final double _lonCellSizeDegrees;
  final Map<_CellKey, List<GtfsStop>> _cells = {};

  StopSpatialIndex._({
    required this.cellSizeMeters,
    required double latCellSizeDegrees,
    required double lonCellSizeDegrees,
  })  : _latCellSizeDegrees = latCellSizeDegrees,
        _lonCellSizeDegrees = lonCellSizeDegrees;

  factory StopSpatialIndex.build(Iterable<GtfsStop> stops, {required double cellSizeMeters}) {
    final stopList = stops.toList();
    final refLat = stopList.isEmpty
        ? 0.0
        : stopList.map((s) => s.stopLat).reduce((a, b) => a + b) / stopList.length;
    // GUARD: a walking radius of exactly 0 is a legitimate, deliberate
    // configuration (see RaptorRouter's own tests — it means "only a
    // zero-distance/same-location transfer counts," not "no index").
    // The grid math only needs a non-zero CELL size to avoid division
    // by zero; the real distance filter downstream in RaptorRouter's
    // Step B (`distance > walkingRadiusMeters`) still uses the true,
    // unmodified radius, so clamping ONLY the internal bucket size here
    // changes nothing about which stops are considered "reachable" —
    // it only ensures every stop lands in some finite grid cell.
    final effectiveCellSizeMeters = cellSizeMeters > 0 ? cellSizeMeters : 1.0;
    final latCellSizeDegrees = effectiveCellSizeMeters / 111320.0;
    final lonCellSizeDegrees = effectiveCellSizeMeters / (111320.0 * max(cos(refLat * pi / 180.0), 0.01));

    final index = StopSpatialIndex._(
      cellSizeMeters: cellSizeMeters,
      latCellSizeDegrees: latCellSizeDegrees,
      lonCellSizeDegrees: lonCellSizeDegrees,
    );
    for (final stop in stopList) {
      final key = index._cellKeyFor(stop.stopLat, stop.stopLon);
      index._cells.putIfAbsent(key, () => []).add(stop);
    }
    return index;
  }

  _CellKey _cellKeyFor(double lat, double lon) =>
      _CellKey((lat / _latCellSizeDegrees).floor(), (lon / _lonCellSizeDegrees).floor());

  /// Every indexed stop that could possibly be within [cellSizeMeters]
  /// of ([lat], [lon]) — the 3x3 grid-cell neighborhood centered on the
  /// query point's own cell.
  ///
  /// PROOF SKETCH for why 3x3 (one cell of "slack" in each direction)
  /// is always sufficient when cell size C >= query radius R: consider
  /// one axis. The query point sits at some offset `x` (0 <= x < C)
  /// within its own cell. A point at the maximum relevant distance
  /// (R <= C) from the query, in the direction away from the query's
  /// cell origin, lands at local offset `x + R < C + C = 2C`, i.e. at
  /// most ONE cell index higher than the query's — never two. The
  /// symmetric argument holds in the other direction and on the other
  /// axis, so the full 2D neighborhood needed is exactly the 3x3 block
  /// centered on the query's cell. Candidates returned are NOT yet
  /// filtered by exact distance — callers still run their own precise
  /// haversine check (see class doc comment).
  List<GtfsStop> candidatesNear(double lat, double lon) {
    final centerKey = _cellKeyFor(lat, lon);
    final results = <GtfsStop>[];
    for (int dLat = -1; dLat <= 1; dLat++) {
      for (int dLon = -1; dLon <= 1; dLon++) {
        final neighbor = _cells[_CellKey(centerKey.latIndex + dLat, centerKey.lonIndex + dLon)];
        if (neighbor != null) results.addAll(neighbor);
      }
    }
    return results;
  }
}

class _CellKey {
  final int latIndex;
  final int lonIndex;
  const _CellKey(this.latIndex, this.lonIndex);

  @override
  bool operator ==(Object other) => other is _CellKey && other.latIndex == latIndex && other.lonIndex == lonIndex;

  @override
  int get hashCode => Object.hash(latIndex, lonIndex);
}
