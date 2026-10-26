import 'dart:async';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

class RouteStep {
  final String instruction;
  final LatLng location;

  RouteStep(this.instruction, this.location);
}

class RouteData {
  final List<RouteStep> steps;
  final List<LatLng> polylinePoints;

  /// AUDIT ADD (transit-journey walking-leg accuracy fix): the real
  /// routed distance from the provider's own route summary (OSRM
  /// `route.distance`, ORS `route.summary.distance`) — NOT derived
  /// from [polylinePoints] or [steps], which exist for turn-by-turn
  /// display, not distance accounting. Null only if a provider's
  /// response omitted it (defensive; neither OSRM nor ORS normally do).
  final double? totalDistanceMeters;

  RouteData(this.steps, this.polylinePoints, {this.totalDistanceMeters});
}

class LocationService {
  /// The exact instruction text spoken when an OSRM route step's
  /// maneuver type is 'arrive' — used by NavigationMetricsTracker (via
  /// navigation_screen.dart) to detect that a session actually reached
  /// its destination, without duplicating this string as a second
  /// magic-string literal elsewhere.
  static const String arrivalInstruction = 'You have arrived at your destination.';

  /// PERF/HANG FIX (route-search-latency investigation, P0 device
  /// report — app stuck indefinitely on "Locating destination..."):
  /// [getCurrentLocation] previously called `Geolocator.getCurrentPosition`
  /// with NO `timeLimit`, and `NavigationScreen._fetchRoute` awaits this
  /// as the very FIRST step, before any destination text is even
  /// looked at — so a slow/unavailable GPS fix (weak signal indoors,
  /// a cold GPS start, battery-saver location throttling, ...) hung
  /// the ENTIRE route search regardless of which destination was
  /// given, which is exactly why the report wasn't reproducible as
  /// "destination X is slow" — every destination passes through this
  /// same unbounded wait first. Bounded here the same way
  /// [_osrmRequestTimeout]/the geocoding call already are (see their
  /// own doc comments) — on timeout, [getCurrentLocation] returns null,
  /// the EXACT SAME contract already used for "location service
  /// disabled"/"permission denied," so the existing caller-side
  /// null-handling (a clear status message, never a fabricated
  /// position) covers this case with no new branch needed.
  static const Duration _gpsFixTimeout = Duration(seconds: 20);

  Future<Position?> getCurrentLocation() async {
    bool serviceEnabled;
    LocationPermission permission;

    // TEMPORARY TRACE (P0 device report — still stuck on "Locating
    // destination..." for 1+ minute even with the GPS timeout in
    // place): one print immediately before and after every await in
    // this method, so if the log stream stops after a "BEFORE" line
    // with no matching "AFTER", that line identifies the exact call
    // that never returned. Delete once the real stuck point is found.
    print('[TRACE] BEFORE Geolocator.isLocationServiceEnabled()');
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    print('[TRACE] AFTER Geolocator.isLocationServiceEnabled() -> $serviceEnabled');
    if (!serviceEnabled) {
      return null;
    }

    print('[TRACE] BEFORE Geolocator.checkPermission()');
    permission = await Geolocator.checkPermission();
    print('[TRACE] AFTER Geolocator.checkPermission() -> $permission');
    if (permission == LocationPermission.denied) {
      print('[TRACE] BEFORE Geolocator.requestPermission()');
      permission = await Geolocator.requestPermission();
      print('[TRACE] AFTER Geolocator.requestPermission() -> $permission');
      if (permission == LocationPermission.denied) {
        return null;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      return null;
    }

    try {
      print('[TRACE] BEFORE Geolocator.getCurrentPosition() (timeLimit=${_gpsFixTimeout.inSeconds}s)');
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: _gpsFixTimeout),
      );
      print('[TRACE] AFTER Geolocator.getCurrentPosition() -> (${position.latitude}, ${position.longitude})');
      return position;
    } on TimeoutException {
      print('[TRACE] AFTER Geolocator.getCurrentPosition() -> TIMED OUT after ${_gpsFixTimeout.inSeconds}s');
      return null;
    } catch (e) {
      print('[TRACE] AFTER Geolocator.getCurrentPosition() -> THREW: $e');
      return null;
    }
  }

  Future<Map<String, double>?> getCoordinatesFromAddress(String address, Position pos) async {
    // FIX (Issue 1 — "Could not find destination on map" for valid,
    // correctly-resolved destinations like Marina Beach/Tambaram):
    // `bounded=1` previously made Nominatim REJECT any result outside
    // the box below — a hard filter, not a preference. For a
    // city-wide navigation app that's wrong: a destination 15-25km
    // from the user's current position (routine for a city the size
    // of Chennai) would return zero results even though the address
    // itself is perfectly valid. `bounded` is no longer sent at all,
    // so `viewbox` now only INFLUENCES ranking toward nearby matches
    // (Nominatim's own documented behavior when `bounded` is absent)
    // instead of excluding everything else. The box is also widened
    // from ±0.1° to ±0.5° (roughly metro-area scale) so that bias is
    // still meaningful for nearby-name disambiguation without acting
    // like a hard boundary.
    double minLon = pos.longitude - 0.5;
    double maxLon = pos.longitude + 0.5;
    double minLat = pos.latitude - 0.5;
    double maxLat = pos.latitude + 0.5;

    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(address)}&format=json&limit=1&viewbox=$minLon,$minLat,$maxLon,$maxLat');

    // FIX (Issue 1, requirement 5): HTTP failure, parsing failure, and
    // "no results" are now distinguished via distinct log messages —
    // previously all three fell through to the exact same bare
    // `return null` with a single generic "Geocoding error" catch-all,
    // making this failure mode undiagnosable from logs alone. The
    // return value for every case is still `null` (unchanged):
    // NavigationScreen's `if (coords == null)` check and every other
    // caller's behavior is exactly as before.
    http.Response response;
    try {
      // FIX (3-minute hang regression): this call previously had no
      // timeout at all — the ONLY thing bounding the wait was the
      // platform's default socket timeout, which can legitimately run
      // into minutes on a slow/throttled connection. A single 8-second
      // timeout is added here; nothing else about the request changes
      // (still one request, no retry, no fallback search).
      response = await http
          .get(url, headers: {'User-Agent': 'VaishnaviBlindAssistApp'}).timeout(const Duration(seconds: 8));
    } catch (e) {
      print('Geocoding HTTP request failed for "$address": $e');
      return null;
    }

    if (response.statusCode != 200) {
      print('Geocoding request for "$address" returned HTTP ${response.statusCode}.');
      return null;
    }

    List data;
    try {
      data = json.decode(response.body);
    } catch (e) {
      print('Geocoding response for "$address" could not be parsed as JSON: $e');
      return null;
    }

    if (data.isEmpty) {
      print('Geocoding found no results for "$address".');
      return null;
    }

    try {
      return {
        'lat': double.parse(data[0]['lat']),
        'lon': double.parse(data[0]['lon']),
      };
    } catch (e) {
      print('Geocoding result for "$address" was missing/malformed lat-lon fields: $e');
      return null;
    }
  }

  /// AUDIT FIX (P0-3): OSRM requests over encrypted HTTPS, with an
  /// explicit timeout (previously neither `getRouteInstructions` nor
  /// `getRouteAlternatives` had ANY timeout on this call, so a stalled
  /// connection could hang navigation indefinitely rather than
  /// falling through to whatever the caller does on failure).
  /// Android's default network security config already blocks plain
  /// HTTP for exactly this kind of request — switching to HTTPS,
  /// rather than opting the app INTO cleartext traffic, is the fix
  /// that keeps that protection intact.
  static const Duration _osrmRequestTimeout = Duration(seconds: 10);

  /// AUDIT ADD (map-provider switch): OpenRouteService free-tier API
  /// key. Get one at https://openrouteservice.org/dev/#/signup (free,
  /// no billing/credit-card required — 2000 requests/day on the free
  /// plan as of signup). Paste it here once obtained. Left blank by
  /// default: every ORS call below checks this first and transparently
  /// falls back to the OSRM public demo server (unchanged behavior)
  /// if it's empty, so the app keeps working before the key is added
  /// — this is a one-line config change, not a hard migration.
  static const String _orsApiKey = String.fromEnvironment('ORS_API_KEY');

  static const Duration _orsRequestTimeout = Duration(seconds: 10);

  bool get _useOrs => _orsApiKey.isNotEmpty;

  /// AUDIT FIX (walking-leg enrichment integration check — real bug
  /// caught live): ORS's free tier allows 40 requests/minute (confirmed
  /// against their published plan limits), which sounds generous but is
  /// a BURST limit, not just an average — a journey-enrichment pass
  /// that calls this for several walking legs back-to-back (and
  /// `NavigationScreen` enriches every returned journey option, not
  /// just one) blew through it in seconds flat. Reproduced live: every
  /// single call in a 7-scenario, ~20-call integration run returned
  /// HTTP 400 with an empty body — no error detail at all, which is
  /// how this gateway reports a burst-limit violation rather than the
  /// more informative 429. A per-instance timestamp is enough here
  /// (one `LocationService` instance serves the whole app) — paces
  /// every ORS call, not just the enrichment path, since any future
  /// caller hits the exact same shared limit.
  static DateTime? _lastOrsCallTime;
  static const Duration _orsMinIntervalBetweenCalls = Duration(milliseconds: 1600); // 60s / 40 requests, plus margin

  Future<void> _throttleOrsCall() async {
    final lastCall = _lastOrsCallTime;
    if (lastCall != null) {
      final elapsed = DateTime.now().difference(lastCall);
      if (elapsed < _orsMinIntervalBetweenCalls) {
        await Future.delayed(_orsMinIntervalBetweenCalls - elapsed);
      }
    }
    _lastOrsCallTime = DateTime.now();
  }

  Future<RouteData?> getRouteInstructions(Position start, double endLat, double endLon) async {
    if (_useOrs) {
      final orsResult = await _getOrsRoute(start, endLat, endLon, alternatives: false);
      if (orsResult.isNotEmpty) return orsResult.first;
      // Falls through to OSRM below on any ORS failure (network error,
      // rate limit, bad key) — never silently returns no route when a
      // working fallback exists.
    }
    // AUDIT FIX (real-device validation phase — map/route accuracy):
    // was `overview=simplified`, which returns a heavily
    // point-reduced polyline from OSRM — visibly cuts corners and
    // drifts from the real street path on curves/intersections.
    // `getRouteAlternatives` below already correctly uses
    // `overview=full` for the exact same OSRM endpoint; this was an
    // inconsistency, not an intentional choice. No new dependency,
    // no behavior change beyond more accurate polyline geometry.
    final url = Uri.parse('https://router.project-osrm.org/route/v1/walking/${start.longitude},${start.latitude};$endLon,$endLat?steps=true&overview=full');

    try {
      final response = await http.get(url).timeout(_osrmRequestTimeout);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data['routes'] != null && data['routes'].isNotEmpty) {
          return _parseRoute(data['routes'][0]);
        }
      }
    } catch (e) {
      print('Routing error: $e');
    }
    return null;
  }

  /// Feature 2 (Safe Path Optimization): fetches MULTIPLE candidate
  /// routes from the same OSRM endpoint (via `alternatives=true`)
  /// instead of just the first one, so SafeRouteService has more than
  /// one option to score. Purely additive — [getRouteInstructions]
  /// above is unchanged and still used wherever it already was;
  /// `_parseRoute` is shared between both so the parsing logic itself
  /// isn't duplicated.
  ///
  /// Returns an empty list (not null) on any failure, so a caller can
  /// treat "no alternatives" as "fall back to getRouteInstructions"
  /// without a separate null-check branch.
  Future<List<RouteData>> getRouteAlternatives(Position start, double endLat, double endLon) async {
    if (_useOrs) {
      final orsResult = await _getOrsRoute(start, endLat, endLon, alternatives: true);
      if (orsResult.isNotEmpty) return orsResult;
    }
    final url = Uri.parse(
        'https://router.project-osrm.org/route/v1/walking/${start.longitude},${start.latitude};$endLon,$endLat?steps=true&overview=full&alternatives=true');

    try {
      final response = await http.get(url).timeout(_osrmRequestTimeout);
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final routesJson = data['routes'];
        if (routesJson != null && routesJson.isNotEmpty) {
          return (routesJson as List)
              .map((r) => _parseRoute(r as Map<String, dynamic>))
              .whereType<RouteData>()
              .toList();
        }
      }
    } catch (e) {
      print('Route-alternatives routing error: $e');
    }
    return [];
  }

  /// AUDIT ADD (map-provider switch — OpenRouteService): same
  /// walking-directions job as the OSRM methods above, against ORS's
  /// `/v2/directions/foot-walking` endpoint. ORS's free tier is far
  /// more reliable than the OSRM public demo server for this project's
  /// actual usage pattern — the OSRM demo's rate limit was hit live,
  /// confirmed via real HTTP 429 responses during on-device testing.
  ///
  /// Deliberately uses each step's own pre-built `instruction` text
  /// rather than reconstructing one from ORS's numeric maneuver `type`
  /// codes: that table could not be fully/confidently verified against
  /// official documentation in this environment, and ORS's own
  /// instruction generator is already correct and tested — for a
  /// safety-critical spoken-instruction feature, using the data the
  /// API already computed correctly is the lower-risk choice over
  /// reimplementing a lookup table from partial/uncertain reference
  /// material.
  Future<List<RouteData>> _getOrsRoute(Position start, double endLat, double endLon,
      {required bool alternatives}) async {
    await _throttleOrsCall();
    final url = Uri.parse('https://api.openrouteservice.org/v2/directions/foot-walking').replace(
      queryParameters: {
        'api_key': _orsApiKey,
        'start': '${start.longitude},${start.latitude}',
        'end': '$endLon,$endLat',
        if (alternatives) 'alternative_routes': jsonEncode({'target_count': 3}),
      },
    );
    try {
      final response = await http.get(url).timeout(_orsRequestTimeout);
      if (response.statusCode != 200) {
        print('ORS routing error: HTTP ${response.statusCode} — url=$url — body="${response.body}" — headers=${response.headers}');
        return [];
      }
      final data = json.decode(response.body);
      // AUDIT FIX (verified against a real, live request with the real
      // API key — NOT assumed from documentation alone): a GET request
      // to this endpoint returns a GeoJSON FeatureCollection, not the
      // `{routes:[...]}` shape OSRM uses. There is no `/json`-suffixed
      // GET variant — that path exists but only accepts POST (confirmed
      // live: returns HTTP 405 on GET). Each result is a GeoJSON
      // Feature under `features[]`, with the actual route data nested
      // under `feature.properties` and `feature.geometry` — see
      // `_parseOrsFeature`'s doc comment for the full shape.
      final featuresJson = data['features'];
      if (featuresJson == null || featuresJson.isEmpty) return [];
      return (featuresJson as List)
          .map((f) => _parseOrsFeature(f as Map<String, dynamic>))
          .whereType<RouteData>()
          .toList();
    } catch (e) {
      print('ORS routing error: $e');
      return [];
    }
  }

  /// Parses one GeoJSON Feature from ORS's directions response:
  /// ```
  /// { "geometry": { "type": "LineString", "coordinates": [[lon,lat], ...] },
  ///   "properties": { "segments": [{ "distance", "duration", "steps": [...] }],
  ///                    "summary": { "distance", "duration" } } }
  /// ```
  /// `geometry.coordinates` is a raw `[lon, lat]` pair array — NOT an
  /// encoded polyline string like OSRM's `geometry` field, so this does
  /// NOT go through [_decodePolyline] (that would silently produce
  /// garbage coordinates if fed GeoJSON's plain numbers as if they were
  /// an encoded string).
  RouteData? _parseOrsFeature(Map<String, dynamic> feature) {
    final geometry = feature['geometry'] as Map<String, dynamic>?;
    final coordinates = geometry?['coordinates'] as List?;
    if (coordinates == null || coordinates.isEmpty) return null;
    final polylinePoints = <LatLng>[
      for (final coord in coordinates) LatLng((coord[1] as num).toDouble(), (coord[0] as num).toDouble()),
    ];

    final properties = feature['properties'] as Map<String, dynamic>?;
    final routeSteps = <RouteStep>[];
    final segments = properties?['segments'] as List?;
    if (segments != null) {
      // Flattened so "is this the very last step of the whole route"
      // (used below to apply the app's own standard arrival phrase,
      // the same way the OSRM parser does for its 'arrive' type) is a
      // simple last-element check, not a nested segments/steps index
      // comparison.
      final allSteps = <Map<String, dynamic>>[
        for (final segment in segments) ...((segment['steps'] as List?) ?? []).cast<Map<String, dynamic>>(),
      ];
      for (int i = 0; i < allSteps.length; i++) {
        final step = allSteps[i];
        final wayPoints = step['way_points'] as List?;
        if (wayPoints == null || wayPoints.isEmpty) continue;
        final pointIndex = (wayPoints.first as num).toInt();
        if (pointIndex < 0 || pointIndex >= polylinePoints.length) continue;

        final isLastStep = i == allSteps.length - 1;
        final distance = (step['distance'] as num?)?.toDouble() ?? 0.0;
        String instruction;
        if (isLastStep) {
          instruction = arrivalInstruction;
        } else {
          final baseInstruction = (step['instruction'] as String?) ?? '';
          if (baseInstruction.isEmpty) continue;
          final dist = distance.round();
          instruction = dist > 0 ? '$baseInstruction for $dist meters.' : '$baseInstruction.';
        }
        routeSteps.add(RouteStep(instruction, polylinePoints[pointIndex]));
      }
    }
    final summary = properties?['summary'] as Map<String, dynamic>?;
    return RouteData(routeSteps, polylinePoints, totalDistanceMeters: (summary?['distance'] as num?)?.toDouble());
  }

  /// Shared by [getRouteInstructions] and [getRouteAlternatives] —
  /// extracted so adding alternatives support didn't require a second
  /// copy of the same maneuver/polyline parsing logic. Behavior for
  /// [getRouteInstructions]'s existing callers is unchanged: this is
  /// the exact same parsing it always did, just factored out.
  RouteData? _parseRoute(Map<String, dynamic> route) {
    List<LatLng> polylinePoints = [];
    if (route['geometry'] != null) {
      polylinePoints = _decodePolyline(route['geometry']);
    }

    List<RouteStep> routeSteps = [];
    final legs = route['legs'];
    if (legs != null && legs.isNotEmpty) {
      final steps = legs[0]['steps'];
      for (var step in steps) {
        if (step['maneuver'] != null && step['maneuver']['location'] != null) {
          String type = step['maneuver']['type'] ?? '';
          String modifier = step['maneuver']['modifier'] ?? '';
          String name = step['name'] ?? '';
          double distance = (step['distance'] as num).toDouble();

          var loc = step['maneuver']['location'];
          LatLng coordinate = LatLng(loc[1].toDouble(), loc[0].toDouble());

          String instruction = _constructInstruction(type, modifier, distance, name);
          if (instruction.isNotEmpty) {
            routeSteps.add(RouteStep(instruction, coordinate));
          }
        }
      }
    }

    return RouteData(routeSteps, polylinePoints, totalDistanceMeters: (route['distance'] as num?)?.toDouble());
  }

  String _constructInstruction(String type, String modifier, double distance, String name) {
    String action = 'Walk';
    if (type == 'turn') {
      action = 'Turn';
    } else if (type == 'arrive') {
      return arrivalInstruction;
    } else if (type == 'depart') {
      action = 'Head';
    }

    String direction = modifier.replaceAll('-', ' ');
    if (direction.isEmpty && type == 'turn') direction = 'straight';
    
    String streetInfo = name.isNotEmpty ? ' onto $name' : '';

    int dist = distance.round();

    direction = direction.isNotEmpty ? ' $direction' : '';
    
    if (dist > 0) {
      return '$action$direction$streetInfo for $dist meters.';
    } else {
      return '$action$direction$streetInfo.';
    }
  }

  List<LatLng> _decodePolyline(String encoded) {
    List<LatLng> polyline = [];
    int index = 0, len = encoded.length;
    int lat = 0, lng = 0;

    while (index < len) {
      int b, shift = 0, result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = encoded.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      polyline.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return polyline;
  }
}
