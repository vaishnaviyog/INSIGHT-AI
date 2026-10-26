import 'package:vaishnavi/models/journey/journey_segment.dart';

/// Real Chennai GTFS data, extracted directly from this app's own
/// bundled/prepared feed (`assets/gtfs/chennai-unified-gtfs.zip`) for
/// use as REALISTIC test fixtures — every stop_id, name, lat/lon,
/// route, and trip_id below is a real row from that feed, not
/// fabricated, per the explicit "use real route/segment structures"
/// requirement. Extraction method: a one-off script queried the real
/// prepared database for (a) a trip with 6-10 stops, (b) a real stop
/// pair ~800m apart, (c) two real stops within 150m of each other —
/// see this comprehensive-simulation pass's final report for the
/// exact queries.
class RealChennaiRoute153A {
  /// K.K.Nagar -> M.G.R.Koyambedu Bus Terminus, trip_id=100593,
  /// route_id=20253, route_short_name="153A", service_id="Regular".
  static const stops = [
    TransitStopWaypoint(stopId: '4', stopName: 'K.K.Nagar', stopLat: 13.03586, stopLon: 80.20545, sequenceIndex: 0),
    TransitStopWaypoint(
        stopId: '48', stopName: 'K.K.Nagar E.S.I Hospital', stopLat: 13.0355, stopLon: 80.20838, sequenceIndex: 1),
    TransitStopWaypoint(stopId: '25', stopName: 'Ashok Pillar', stopLat: 13.03513, stopLon: 80.21088, sequenceIndex: 2),
    TransitStopWaypoint(
        stopId: '9341', stopName: 'Ashok Nagar Canara Bank', stopLat: 13.03986, stopLon: 80.21209, sequenceIndex: 3),
    TransitStopWaypoint(stopId: '9398', stopName: 'Vadapalani', stopLat: 13.04703, stopLon: 80.21218, sequenceIndex: 4),
    TransitStopWaypoint(
        stopId: '4711', stopName: 'Vadapalani Thiru Nagar', stopLat: 13.05742, stopLon: 80.2113, sequenceIndex: 5),
    TransitStopWaypoint(
        stopId: '2819', stopName: 'Mmda Colony Road Junction', stopLat: 13.06514, stopLon: 80.21101, sequenceIndex: 6),
    TransitStopWaypoint(
        stopId: '5822', stopName: 'M.G.R.Koyambedu Bus Terminus', stopLat: 13.0688, stopLon: 80.2052, sequenceIndex: 7),
  ];

  static JourneySegment segment() => JourneySegment(
        type: JourneySegmentType.bus,
        description: 'Board Bus 153A towards M.G.R.Koyambedu Bus Terminus',
        duration: const Duration(minutes: 16),
        fromStopName: stops.first.stopName,
        toStopName: stops.last.stopName,
        routeShortName: '153A',
        routeLongName: 'CT2',
        tripId: '100593',
        routeId: '20253',
        boardingStopId: stops.first.stopId,
        alightingStopId: stops.last.stopId,
        orderedStops: stops,
        departureTime: DateTime(2026, 1, 1, 5, 10),
        arrivalTime: DateTime(2026, 1, 1, 5, 26),
      );
}

/// A SECOND real route/pattern (route_id=20133, route_short_name="M70",
/// trip_id=100082, service_id="Regular") — the SAME physical corridor
/// as [RealChennaiRoute153A] but in the reverse direction and a
/// slightly different stop set, used for multi-segment/transfer
/// fixtures so those tests aren't built from only one route.
class RealChennaiRouteM70 {
  static const stops = [
    TransitStopWaypoint(
        stopId: '5822', stopName: 'M.G.R.Koyambedu Bus Terminus', stopLat: 13.0688, stopLon: 80.2052, sequenceIndex: 0),
    TransitStopWaypoint(
        stopId: '2820', stopName: 'Mmda Colony Road Junction', stopLat: 13.06518, stopLon: 80.21125, sequenceIndex: 1),
    TransitStopWaypoint(
        stopId: '4712', stopName: 'Vadapalani Thiru Nagar', stopLat: 13.05791, stopLon: 80.21166, sequenceIndex: 2),
    TransitStopWaypoint(stopId: '4940', stopName: 'Vadapalani', stopLat: 13.04634, stopLon: 80.21242, sequenceIndex: 3),
    TransitStopWaypoint(stopId: '26', stopName: 'Ashok Pillar', stopLat: 13.03354, stopLon: 80.21209, sequenceIndex: 4),
    TransitStopWaypoint(
        stopId: '49', stopName: 'K.K.Nagar E.S.I Hospital', stopLat: 13.03522, stopLon: 80.20863, sequenceIndex: 5),
    TransitStopWaypoint(stopId: '1', stopName: 'K.K.Nagar', stopLat: 13.03563, stopLon: 80.2057, sequenceIndex: 6),
  ];

  static JourneySegment segment() => JourneySegment(
        type: JourneySegmentType.bus,
        description: 'Board Bus M70 towards K.K.Nagar',
        duration: const Duration(minutes: 16),
        fromStopName: stops.first.stopName,
        toStopName: stops.last.stopName,
        routeShortName: 'M70',
        routeLongName: 'CT9',
        tripId: '100082',
        routeId: '20133',
        boardingStopId: stops.first.stopId,
        alightingStopId: stops.last.stopId,
        orderedStops: stops,
        departureTime: DateTime(2026, 1, 1, 19, 20),
        arrivalTime: DateTime(2026, 1, 1, 19, 36),
      );
}

/// Real 840.8m stop-to-stop distance for the explicit "800 metre walk"
/// requirement — Nessammal Nagar (a plausible user starting point) to
/// TAISHA COMPLEX (stop_id 11169), a real boarding stop.
class RealChennai800mWalk {
  static const originLat = 13.06049;
  static const originLon = 80.18131; // "Nessammal Nagar" stop, used as a starting point
  static const boardingStopId = '11169';
  static const boardingStopName = 'TAISHA COMPLEX';
  static const boardingStopLat = 13.05688;
  static const boardingStopLon = 80.18813;
}

/// Real nearby-but-DIFFERENT stops (35.8m apart, sharing the exact
/// same name "Poonjeri Koot Road") for the explicit "two bus stops
/// are very close together" / wrong-stop-scenario requirement.
class RealChennaiCompetingStops {
  static const name = 'Poonjeri Koot Road';
  static const correctStopId = '5934';
  static const correctLat = 12.6148;
  static const correctLon = 80.1721;
  static const wrongStopId = '5935';
  static const wrongLat = 12.6148;
  static const wrongLon = 80.17177;
}
