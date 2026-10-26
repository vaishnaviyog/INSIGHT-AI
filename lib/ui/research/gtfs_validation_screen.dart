import 'package:flutter/material.dart';

import '../../models/gtfs/stop.dart';
import '../../repositories/gtfs_repository.dart';
import '../../services/location_service.dart';

/// Runs the bundled Chennai GTFS import and every read-API method
/// against it, displaying a validation report — the Stage 2
/// deliverable's "verify GTFS imports correctly / tables populate /
/// nearby stop lookup works / route lookup works / trip lookup
/// works" requirement, made actually runnable rather than only
/// described. Reachable from Research Menu -> "GTFS Import &
/// Validation". Debug/research tooling only — no route guidance, OCR,
/// or camera integration here, per this stage's explicit scope.
class GtfsValidationScreen extends StatefulWidget {
  const GtfsValidationScreen({super.key});

  @override
  State<GtfsValidationScreen> createState() => _GtfsValidationScreenState();
}

class _GtfsValidationScreenState extends State<GtfsValidationScreen> {
  final GtfsRepository _repository = GtfsRepository();
  bool _isRunning = false;
  String _log = '';

  @override
  void dispose() {
    _repository.dispose();
    super.dispose();
  }

  void _append(String line) {
    setState(() => _log += '$line\n');
  }

  Future<void> _runFullValidation() async {
    setState(() {
      _isRunning = true;
      _log = '';
    });
    try {
      _append('Initializing GTFS repository...');
      await _repository.initialize(locationService: LocationService());

      _append('Importing bundled Chennai GTFS feed (assets/gtfs/chennai-unified-gtfs.zip)...');
      final report = await _repository.importFromAsset('assets/gtfs/chennai-unified-gtfs.zip');
      _append('');
      _append(report.toReadableSummary());

      if (!report.succeeded) {
        _append('Import failed — stopping validation here.');
        setState(() => _isRunning = false);
        return;
      }

      _append('--- Query validation ---');

      // getStopById / searchStops
      final searchResults = await _repository.searchStops('Anna');
      _append('searchStops("Anna"): ${searchResults.length} result(s)'
          '${searchResults.isNotEmpty ? ' — e.g. "${searchResults.first.stopName}" (${searchResults.first.stopId})' : ''}');

      GtfsStop? sampleStop;
      if (searchResults.isNotEmpty) {
        sampleStop = await _repository.getStopById(searchResults.first.stopId);
        _append('getStopById("${searchResults.first.stopId}"): '
            '${sampleStop != null ? 'found "${sampleStop.stopName}"' : 'NOT FOUND (unexpected)'}');
      }

      // searchRoutes
      final routeResults = await _repository.searchRoutes('29A');
      _append('searchRoutes("29A"): ${routeResults.length} result(s)'
          '${routeResults.isNotEmpty ? ' — e.g. route ${routeResults.first.routeShortName}' : ''}');

      // getRoutesForStop / getTripsForRoute
      if (sampleStop != null) {
        final routesForStop = await _repository.getRoutesForStop(sampleStop.stopId);
        _append('getRoutesForStop("${sampleStop.stopId}"): ${routesForStop.length} route(s) serve this stop');
        if (routesForStop.isNotEmpty) {
          final trips = await _repository.getTripsForRoute(routesForStop.first.routeId);
          _append('getTripsForRoute("${routesForStop.first.routeId}"): ${trips.length} trip(s)');
          if (trips.isNotEmpty) {
            final upcoming = await _repository.getUpcomingTrips(
              stopId: sampleStop.stopId,
              afterTimeHHMMSS: '00:00:00',
            );
            _append('getUpcomingTrips("${sampleStop.stopId}", after 00:00:00): ${upcoming.length} stop_time row(s)');
          }
        }
      }

      // Nearby/nearest — Chennai Central approx coordinates, since GPS
      // may be unavailable/unrealistic on an emulator running this
      // screen.
      const chennaiCentralLat = 13.0827;
      const chennaiCentralLon = 80.2707;
      final nearby = await _repository.getNearbyStops(
        latitude: chennaiCentralLat,
        longitude: chennaiCentralLon,
        radiusMeters: 2000,
      );
      _append('getNearbyStops(near Chennai Central, 2km): ${nearby.length} stop(s)');

      final nearest = await _repository.getNearestStop(latitude: chennaiCentralLat, longitude: chennaiCentralLon);
      _append('getNearestStop(near Chennai Central): '
          '${nearest != null ? '"${nearest.stopName}" (${nearest.stopId})' : 'none found'}');

      final nearestMetro = await _repository.nearestMetroStation();
      _append('nearestMetroStation() [via device GPS]: '
          '${nearestMetro != null ? '"${nearestMetro.stopName}" (${nearestMetro.stopId})' : 'none found'}'
          '${nearestMetro == null ? ' — expected: see known data-quality note above, routes.txt\'s 3 CMRL '
              'rows fail import validation, so no metro route currently exists in the imported data' : ''}');

      _append('');
      _append('Validation complete.');
    } catch (e, stackTrace) {
      _append('VALIDATION FAILED WITH AN EXCEPTION: $e');
      _append(stackTrace.toString());
    } finally {
      setState(() => _isRunning = false);
    }
  }

  /// Approximate public-landmark coordinates, for routing tests only
  /// — NOT part of the GTFS feed itself. Real destination resolution
  /// in the app goes through `LocationService.getCoordinatesFromAddress`
  /// (Nominatim geocoding); these are hardcoded here purely so this
  /// debug screen can exercise the routing engine against named
  /// places without a geocoder round-trip.
  static const Map<String, (double, double)> _testLandmarks = {
    'Guindy': (13.0067, 80.2206),
    'Chennai Central': (13.0827, 80.2707),
    'Tambaram': (12.9249, 80.1000),
    'Egmore': (13.0732, 80.2609),
    'Airport': (12.9941, 80.1707),
    'Marina Beach': (13.0500, 80.2824),
    'CMBT / Koyambedu': (13.0694, 80.1948),
    'T Nagar': (13.0418, 80.2341),
    'Velachery': (12.9750, 80.2200),
    'Adyar': (13.0012, 80.2565),
    'Saidapet': (13.0212, 80.2226),
    'Anna Nagar': (13.0850, 80.2101),
    'VIT Chennai': (12.8406, 80.1534),
  };

  static const List<(String, String)> _testPairs = [
    ('VIT Chennai', 'Tambaram'),
    ('VIT Chennai', 'Guindy'),
    ('VIT Chennai', 'Chennai Central'),
    ('Tambaram', 'Airport'),
    ('Tambaram', 'Marina Beach'),
    ('Chennai Central', 'Guindy'),
    ('Chennai Central', 'Airport'),
    ('Airport', 'Velachery'),
    ('Airport', 'Tambaram'),
    ('Guindy', 'Anna Nagar'),
  ];

  /// Runs the RAPTOR engine (with debugMode on, so every stage prints
  /// to console) across the specific origin/destination pairs
  /// requested for this phase's testing, reporting a pass/fail summary
  /// with the actual reason for every failure — never a bare "no
  /// journey," per this phase's error-handling requirement.
  Future<void> _runRoutingTests() async {
    setState(() {
      _isRunning = true;
      _log = '';
    });
    try {
      _append('Initializing GTFS repository...');
      await _repository.initialize(locationService: LocationService());
      _repository.journeyPlannerDebugMode = true;

      final hasData = (await _repository.searchStops('a', limit: 1)).isNotEmpty;
      if (!hasData) {
        _append('No GTFS data imported yet — importing bundled feed first...');
        final report = await _repository.importFromAsset('assets/gtfs/chennai-unified-gtfs.zip');
        _append(report.succeeded ? 'Import succeeded.' : 'Import FAILED: ${report.failureReason}');
      }

      _append('');
      _append('--- Routing tests (see console/adb logcat for full [JourneyPlannerService] trace) ---');
      int passed = 0;
      for (final (originName, destName) in _testPairs) {
        final origin = _testLandmarks[originName]!;
        final dest = _testLandmarks[destName]!;
        final stopwatch = Stopwatch()..start();
        final journeys = await _repository.findJourneys(
          originLat: origin.$1,
          originLon: origin.$2,
          destinationLat: dest.$1,
          destinationLon: dest.$2,
        );
        stopwatch.stop();
        if (journeys.isNotEmpty) {
          passed++;
          final best = journeys.first;
          _append('✔ $originName -> $destName: ${journeys.length} journey(s), best '
              '${best.totalTravelTime.inMinutes}min/${best.transferCount} transfer(s) '
              '(${stopwatch.elapsedMilliseconds}ms)');
        } else {
          _append('✘ $originName -> $destName: NO JOURNEY — '
              '${_repository.lastJourneyPlanningFailureReason ?? "no reason recorded (unexpected)"} '
              '(${stopwatch.elapsedMilliseconds}ms)');
        }
      }
      _append('');
      _append('Routing test summary: $passed / ${_testPairs.length} pairs found a journey.');
    } catch (e, stackTrace) {
      _append('ROUTING TEST FAILED WITH AN EXCEPTION: $e');
      _append(stackTrace.toString());
    } finally {
      setState(() => _isRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GTFS Import & Validation')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton(
              onPressed: _isRunning ? null : _runFullValidation,
              child: Text(_isRunning ? 'Running...' : 'Run full GTFS import + validation'),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _isRunning ? null : _runRoutingTests,
              child: const Text('Run RAPTOR routing tests (Chennai landmark pairs)'),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade700)),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _log.isEmpty ? 'Press a button to run validation or routing tests.' : _log,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
