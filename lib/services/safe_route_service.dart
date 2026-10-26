import 'package:latlong2/latlong.dart';

import '../models/evaluation_record.dart';
import '../models/navigation_intent.dart';
import '../models/risk_assessment.dart';
import '../models/route_safety_cell.dart';
import '../models/user_behaviour_profile.dart';
import '../models/user_profile.dart';
import 'behaviour_learning_service.dart';
import 'location_service.dart';
import 'road_attributes_provider.dart';
import 'route_safety_service.dart';

/// One candidate route, scored for safety alongside its raw distance
/// and a human-readable explanation of the score — mirrors
/// RiskAssessment's own "score + explanation, never just the former"
/// pattern.
class RankedRoute {
  final RouteData route;

  /// 0 (safest observed among the candidates) .. 1 (riskiest) —
  /// same convention as RiskAssessment.overallRiskScore, so the two
  /// remain conceptually comparable.
  final double safetyScore;
  final double distanceMeters;
  final String explanation;

  const RankedRoute({
    required this.route,
    required this.safetyScore,
    required this.distanceMeters,
    required this.explanation,
  });
}

/// Replaces pure distance-optimized routing with risk-aware route
/// selection, per Feature 2. Scores every candidate route using
/// REAL, already-available signals:
///
///  - historical hazard risk, by reusing [RouteSafetyService] (built
///    in Phase 7) against the app's own [EvaluationRecord] history —
///    no new hazard-tracking logic, just a new consumer of it.
///  - crossing/intersection density, inferred from the same
///    instruction text OSRM already returns (a text-heuristic, the
///    same kind already used by navigation_screen.dart's own
///    `_recordTurnFromInstruction`).
///  - user familiarity, by reusing [UserBehaviourProfile]'s frequently
///    -visited-location grid (Milestone 2) — no new location tracking.
///  - environmental risk, by reusing [EnvironmentContext.fromCurrentTime]
///    (Milestone 3) as a global (not per-segment) risk nudge, since
///    per-segment lighting data isn't available from OSRM.
///
/// Signals this project genuinely has NO data source for yet — road
/// width, live traffic intensity, per-segment pedestrian availability
/// and lighting — are NOT fabricated. They're gated behind the
/// optional [RoadAttributesProvider] hook: if none is supplied (the
/// default, today), those terms are simply excluded from the weighted
/// average rather than filled with a guessed neutral value.
///
/// STATELESS, mirroring RiskAssessmentService/AdaptiveGuidanceService:
/// every input is passed explicitly into [selectSafestRoute].
class SafeRouteService {
  /// Below this many points' difference in safety score, two routes
  /// are considered "similarly safe" and the shorter one wins — this
  /// is the "if multiple routes have similar safety, prefer the
  /// shorter one" requirement.
  static const double _similarSafetyThreshold = 0.05;

  final RouteSafetyService _routeSafetyService;

  SafeRouteService({RouteSafetyService? routeSafetyService})
      : _routeSafetyService = routeSafetyService ?? RouteSafetyService();

  /// Scores every candidate in [candidates] and returns the safest —
  /// or, among similarly-safe routes, the shortest. Returns `null`
  /// only if [candidates] is empty (never fabricates a route).
  ///
  /// [routePreference] (onboarding Step 4) changes the SELECTION RULE
  /// applied to the same computed scores, not the scoring itself:
  ///  - `balanced` (default): existing behavior — safest route wins,
  ///    with a same-safety-band tie-break toward the shorter route.
  ///  - `safest`: the single lowest-scored route always wins, with no
  ///    distance tie-break at all, even if a slightly-less-safe route
  ///    is much shorter.
  ///  - `fastest`: the shortest-distance candidate always wins,
  ///    regardless of its safety score (safety is still computed and
  ///    included in [RankedRoute.explanation] for transparency, just
  ///    not used to choose).
  Future<RankedRoute?> selectSafestRoute({
    required List<RouteData> candidates,
    required List<EvaluationRecord> historicalRecords,
    UserBehaviourProfile? profile,
    NavigationIntent? intent,
    RoadAttributesProvider? roadAttributesProvider,
    RoutePreference routePreference = RoutePreference.balanced,
    DateTime? time,
  }) async {
    if (candidates.isEmpty) return null;

    final historicalCells = _routeSafetyService.buildSafetyMap(historicalRecords);
    final environment = EnvironmentContext.fromCurrentTime(time);

    final ranked = <RankedRoute>[];
    for (final route in candidates) {
      ranked.add(await _score(
        route,
        historicalCells,
        profile,
        intent,
        roadAttributesProvider,
        environment,
      ));
    }

    ranked.sort((a, b) => a.safetyScore.compareTo(b.safetyScore));

    switch (routePreference) {
      case RoutePreference.fastest:
        return ranked.reduce((a, b) => a.distanceMeters <= b.distanceMeters ? a : b);

      case RoutePreference.safest:
        // Strictly the lowest safety score — no distance tie-break at
        // all, unlike `balanced` below.
        return ranked.first;

      case RoutePreference.balanced:
        var best = ranked.first;
        for (final candidate in ranked.skip(1)) {
          final withinSimilarSafety =
              (candidate.safetyScore - best.safetyScore).abs() <= _similarSafetyThreshold;
          if (withinSimilarSafety && candidate.distanceMeters < best.distanceMeters) {
            best = candidate;
          }
        }
        return best;
    }
  }

  Future<RankedRoute> _score(
    RouteData route,
    List<RouteSafetyCell> historicalCells,
    UserBehaviourProfile? profile,
    NavigationIntent? intent,
    RoadAttributesProvider? roadAttributesProvider,
    EnvironmentContext environment,
  ) async {
    final distanceMeters = _routeDistanceMeters(route.polylinePoints);
    final distanceKm = distanceMeters / 1000.0;
    final explanationParts = <String>[];

    // --- Historical hazard risk (real data, reused) -----------------
    final hazardRisk = _historicalHazardRisk(route, historicalCells);
    if (hazardRisk != null) {
      explanationParts.add(hazardRisk == 0.0
          ? 'no historically detected hazards along this path'
          : 'historically detected hazards along this path (risk ${hazardRisk.toStringAsFixed(2)})');
    }

    // --- Crossing/intersection density (real, text-heuristic) ------
    final crossingCount =
        route.steps.where((s) => s.instruction.toLowerCase().contains('turn')).length;
    final crossingsPerKm = distanceKm > 0 ? crossingCount / distanceKm : 0.0;
    // Normalized: 0 crossings/km → 0 risk; 6+ crossings/km (a busy,
    // intersection-dense stretch) → capped at 1.0. The 6/km reference
    // point is a documented, hand-picked normalization constant, not a
    // measured threshold.
    final crossingRisk = (crossingsPerKm / 6.0).clamp(0.0, 1.0);
    explanationParts.add('${crossingCount} turn${crossingCount == 1 ? '' : 's'}/intersections '
        '(${crossingsPerKm.toStringAsFixed(1)} per km)');

    // --- Familiarity (real, reused from BehaviourLearningService) --
    final familiarityDiscount = _familiarityDiscount(route, profile);
    if (familiarityDiscount > 0) {
      explanationParts.add('passes through locations you have visited before');
    }

    // --- Environment (real, reused from RiskAssessmentService) -----
    final environmentRisk = environment.isDaylight == false ? 0.6 : 0.2;
    explanationParts.add(environment.isDaylight == false ? 'currently night-time' : 'currently daylight');

    // --- Optional road-attributes provider (real only if supplied) -
    double? providerRisk;
    if (roadAttributesProvider != null && route.polylinePoints.isNotEmpty) {
      final midpoint = route.polylinePoints[route.polylinePoints.length ~/ 2];
      providerRisk = await roadAttributesProvider.riskContributionNear(
        midpoint.latitude,
        midpoint.longitude,
      );
      if (providerRisk != null) {
        explanationParts.add('road-attributes data available for this path');
      }
    }

    // --- Intent-aware weighting (optional, additive) ----------------
    // An "urgent" intent slightly discounts the weight given to
    // crossing density (a hospital trip may reasonably accept a
    // busier but faster street); every other weight is unaffected.
    final urgentIntent = intent != null &&
        intent.confidence >= 0.4 &&
        intent.category == NavigationIntentCategory.urgent;

    // Weighted average over only the signals actually available —
    // unavailable signals (historical data with zero records nearby,
    // or no road-attributes provider) are excluded from BOTH the
    // numerator and the denominator, so they never silently pull the
    // score toward a fabricated "neutral" value.
    double weightedSum = 0.0;
    double totalWeight = 0.0;

    const hazardWeight = 0.40;
    const crossingWeightNormal = 0.20;
    const crossingWeightUrgent = 0.10;
    const familiarityWeight = 0.15;
    const environmentWeight = 0.10;
    const providerWeight = 0.15;

    if (hazardRisk != null) {
      weightedSum += hazardWeight * hazardRisk;
      totalWeight += hazardWeight;
    }
    final crossingWeight = urgentIntent ? crossingWeightUrgent : crossingWeightNormal;
    weightedSum += crossingWeight * crossingRisk;
    totalWeight += crossingWeight;

    // Familiarity REDUCES risk, so it's subtracted (bounded at 0)
    // rather than added.
    weightedSum += familiarityWeight * (1.0 - familiarityDiscount).clamp(0.0, 1.0) - familiarityWeight;
    totalWeight += familiarityWeight;

    weightedSum += environmentWeight * environmentRisk;
    totalWeight += environmentWeight;

    if (providerRisk != null) {
      weightedSum += providerWeight * providerRisk;
      totalWeight += providerWeight;
    }

    final safetyScore = totalWeight > 0 ? (weightedSum / totalWeight).clamp(0.0, 1.0) : 0.5;

    return RankedRoute(
      route: route,
      safetyScore: safetyScore,
      distanceMeters: distanceMeters,
      explanation:
          'Safety score ${safetyScore.toStringAsFixed(2)} (${distanceMeters.round()}m route): '
          '${explanationParts.join('; ')}.',
    );
  }

  /// Average historical risk score across grid cells the route's
  /// polyline actually passes near (within ~25m, using the same
  /// coarse-but-real proximity concept already used elsewhere in this
  /// codebase). Returns `null` (not 0.0) when there is no historical
  /// data anywhere near this route — "no data" and "confirmed zero
  /// risk" are different things, and only the latter should read as
  /// 0.0 in the weighted score.
  double? _historicalHazardRisk(RouteData route, List<RouteSafetyCell> cells) {
    if (cells.isEmpty || route.polylinePoints.isEmpty) return null;

    const proximityMeters = 25.0;
    final distanceCalculator = const Distance();
    final matchedRisks = <double>[];

    for (final cell in cells) {
      final cellPoint = LatLng(cell.latitude, cell.longitude);
      for (final point in route.polylinePoints) {
        if (distanceCalculator.as(LengthUnit.Meter, point, cellPoint) <= proximityMeters) {
          matchedRisks.add(cell.averageRiskScore);
          break;
        }
      }
    }

    if (matchedRisks.isEmpty) return null;
    return matchedRisks.reduce((a, b) => a + b) / matchedRisks.length;
  }

  /// Fraction of the route's polyline that falls within a grid cell
  /// the user has visited before, per [UserBehaviourProfile] — reuses
  /// the exact same grid precision BehaviourLearningService already
  /// uses, so "familiar" here means the same thing it means there.
  double _familiarityDiscount(RouteData route, UserBehaviourProfile? profile) {
    if (profile == null ||
        profile.frequentlyVisitedLocations.isEmpty ||
        route.polylinePoints.isEmpty) {
      return 0.0;
    }

    final visitedKeys = profile.frequentlyVisitedLocations
        .map((l) =>
            '${l.latitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)},'
            '${l.longitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)}')
        .toSet();

    int matched = 0;
    for (final point in route.polylinePoints) {
      final key = '${point.latitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)},'
          '${point.longitude.toStringAsFixed(BehaviourLearningService.locationGridPrecision)}';
      if (visitedKeys.contains(key)) matched++;
    }

    return (matched / route.polylinePoints.length).clamp(0.0, 1.0);
  }

  double _routeDistanceMeters(List<LatLng> points) {
    if (points.length < 2) return 0.0;
    final distanceCalculator = const Distance();
    double total = 0.0;
    for (int i = 1; i < points.length; i++) {
      total += distanceCalculator.as(LengthUnit.Meter, points[i - 1], points[i]);
    }
    return total;
  }
}
