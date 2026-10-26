import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/gtfs/stop.dart';
import 'package:vaishnavi/services/journey/raptor/gtfs_pattern.dart';
import 'package:vaishnavi/services/journey/raptor/gtfs_timetable.dart';
import 'package:vaishnavi/services/journey/raptor/raptor_router.dart';

/// Synthetic GTFS fixtures, built directly as in-memory [GtfsTimetable]
/// objects — bypassing GtfsDatabaseService/sqflite/GtfsQueryService
/// entirely, per the explicit "no database/network/Flutter runtime
/// required" constraint. This exercises the exact same RaptorRouter
/// class the real app uses; only the data source is synthetic.
GtfsStop _stop(String id, {double lat = 13.0, double lon = 80.0}) =>
    GtfsStop(stopId: id, stopName: id, stopLat: lat, stopLon: lon);

GtfsPattern _singleTripPattern({
  required String patternId,
  required List<String> stopIds,
  required List<int> departures,
  required List<int> arrivals,
}) {
  return GtfsPattern(
    patternId: patternId,
    routeId: patternId,
    stopIds: stopIds,
    tripArrivalSeconds: [Int32List.fromList(arrivals)],
    tripDepartureSeconds: [Int32List.fromList(departures)],
    tripIds: ['trip_$patternId'],
  );
}

GtfsTimetable _timetableFrom(List<GtfsPattern> patterns, List<GtfsStop> stops) {
  final patternsById = {for (final p in patterns) p.patternId: p};
  final patternRefsByStop = <String, List<PatternStopRef>>{};
  for (final pattern in patterns) {
    for (int i = 0; i < pattern.stopIds.length; i++) {
      patternRefsByStop.putIfAbsent(pattern.stopIds[i], () => []).add(PatternStopRef(pattern, i));
    }
  }
  return GtfsTimetable(
    patternsById: patternsById,
    patternRefsByStop: patternRefsByStop,
    allStopsById: {for (final s in stops) s.stopId: s},
  );
}

void main() {
  group('RaptorRouter — synthetic network', () {
    test('direct one-pattern route: A -> B', () {
      final pattern = _singleTripPattern(
        patternId: 'P1',
        stopIds: ['A', 'B'],
        departures: [28800, 29400], // 08:00, 08:10
        arrivals: [28800, 29400],
      );
      final timetable = _timetableFrom([pattern], [_stop('A'), _stop('B')]);
      final router = RaptorRouter(timetable: timetable, walkingRadiusMeters: 0);

      final result = router.run(originStopSeconds: {'A': 0}, roundCap: 1);

      expect(result.bestArrivalByStop['B'], 29400);
      final leg = result.lastLegByStop['B']!;
      expect(leg.isWalking, isFalse);
      expect(leg.patternId, 'P1');
      expect(leg.fromStopId, 'A');
      expect(leg.toStopId, 'B');
    });

    test('two-pattern journey with a transfer at a shared stop: A -> X -> B', () {
      final leg1 = _singleTripPattern(
        patternId: 'P1',
        stopIds: ['A', 'X'],
        departures: [28800, 29100], // 08:00 -> 08:05
        arrivals: [28800, 29100],
      );
      final leg2 = _singleTripPattern(
        patternId: 'P2',
        stopIds: ['X', 'B'],
        // Departs 08:08:20 at X — 29100 + minTransferSeconds(120) = 29220,
        // and 29300 >= 29220, so this trip is legitimately catchable
        // after the first leg's arrival plus the minimum transfer time.
        departures: [29300, 29700], // 08:08:20 -> 08:15
        arrivals: [29300, 29700],
      );
      // Distinct, non-coincident coordinates: with walkingRadiusMeters
      // set to 0 below (this test wants to isolate vehicle-boarding-
      // only behavior), any two stops at the SAME coordinates would
      // have a haversine distance of exactly 0, and the router's
      // `distance > walkingRadiusMeters` check (0 > 0 is false) would
      // NOT filter that out — producing a spurious zero-second
      // "walking" transfer between them. The default `_stop()` helper
      // uses the same lat/lon for every stop unless overridden, so
      // this must be given explicitly (as the footpath-relaxation
      // test below already does).
      final timetable = _timetableFrom(
        [leg1, leg2],
        [_stop('A', lat: 13.0000, lon: 80.0000), _stop('X', lat: 13.0010, lon: 80.0000), _stop('B', lat: 13.0020, lon: 80.0000)],
      );
      final router = RaptorRouter(timetable: timetable, walkingRadiusMeters: 0);

      final afterOneBoarding = router.run(originStopSeconds: {'A': 0}, roundCap: 1);
      expect(afterOneBoarding.bestArrivalByStop['X'], 29100);
      expect(afterOneBoarding.bestArrivalByStop.containsKey('B'), isFalse); // needs a 2nd boarding

      final afterTransfer = router.run(originStopSeconds: {'A': 0}, roundCap: 2);
      expect(afterTransfer.bestArrivalByStop['B'], 29700);
      expect(afterTransfer.lastLegByStop['B']!.patternId, 'P2');
    });

    test('a trip departing before the minimum transfer buffer is NOT boardable', () {
      final leg1 = _singleTripPattern(
        patternId: 'P1',
        stopIds: ['A', 'X'],
        departures: [28800, 29100],
        arrivals: [28800, 29100],
      );
      // Departs only 60s after arrival at X — below the default
      // 120s minTransferSeconds, so this specific trip must be
      // skipped (the router should find no boardable trip here).
      final tooTight = _singleTripPattern(
        patternId: 'P2',
        stopIds: ['X', 'B'],
        departures: [29160, 29700],
        arrivals: [29160, 29700],
      );
      // Distinct coordinates — see the previous test's comment for why
      // coincident stops would let a spurious 0-distance "walk" defeat
      // the point of this test (isolating the too-tight-transfer
      // rejection).
      final timetable = _timetableFrom(
        [leg1, tooTight],
        [_stop('A', lat: 13.0000, lon: 80.0000), _stop('X', lat: 13.0010, lon: 80.0000), _stop('B', lat: 13.0020, lon: 80.0000)],
      );
      final router = RaptorRouter(timetable: timetable, walkingRadiusMeters: 0);

      final result = router.run(originStopSeconds: {'A': 0}, roundCap: 2);
      expect(result.bestArrivalByStop.containsKey('B'), isFalse);
    });

    test('an isolated stop reachable by no pattern and outside walking radius is never reached', () {
      final pattern = _singleTripPattern(
        patternId: 'P1',
        stopIds: ['A', 'B'],
        departures: [28800, 29400],
        arrivals: [28800, 29400],
      );
      // Far away — well outside any realistic walking radius.
      final stops = [_stop('A'), _stop('B'), _stop('D', lat: 20.0, lon: 90.0)];
      final timetable = _timetableFrom([pattern], stops);
      final router = RaptorRouter(timetable: timetable, walkingRadiusMeters: 500);

      final result = router.run(originStopSeconds: {'A': 0}, roundCap: 4);
      expect(result.bestArrivalByStop.containsKey('D'), isFalse);
    });

    test('footpath relaxation connects two geographically close stops on different patterns', () {
      final leg1 = _singleTripPattern(
        patternId: 'P1',
        stopIds: ['A', 'Y'],
        departures: [28800, 29100],
        arrivals: [28800, 29100],
      );
      final leg2 = _singleTripPattern(
        patternId: 'P2',
        // Z is a DIFFERENT stop from Y — only reachable via a short walk,
        // not a shared-stop transfer.
        stopIds: ['Z', 'B'],
        departures: [29300, 29700],
        arrivals: [29300, 29700],
      );
      final stops = [
        _stop('A', lat: 13.0000, lon: 80.0000),
        _stop('Y', lat: 13.0010, lon: 80.0000), // ~111m from A
        _stop('Z', lat: 13.0011, lon: 80.0000), // ~11m from Y — an easy walk
        _stop('B', lat: 13.0020, lon: 80.0000),
      ];
      final timetable = _timetableFrom([leg1, leg2], stops);
      final router = RaptorRouter(timetable: timetable, walkingRadiusMeters: 200);

      final result = router.run(originStopSeconds: {'A': 0}, roundCap: 2);
      expect(result.bestArrivalByStop.containsKey('B'), isTrue);
      // The Y -> Z hop in the winning chain must be a walking leg.
      final legToZOrLater = result.lastLegByStop['Z'];
      expect(legToZOrLater, isNotNull);
      expect(legToZOrLater!.isWalking, isTrue);
    });
  });
}
