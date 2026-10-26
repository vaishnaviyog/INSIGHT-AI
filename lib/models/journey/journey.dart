import 'journey_segment.dart';

/// One complete, ranked itinerary option returned by
/// `JourneyPlannerService.findJourneys` — everything
/// `NavigationScreen`'s journey-selection cards and the transit guide
/// screen need to display and narrate the trip.
class Journey {
  final List<JourneySegment> segments;
  final DateTime departureTime;
  final DateTime arrivalTime;
  final Duration totalTravelTime;
  final double totalWalkingDistanceMeters;
  final int transferCount;

  const Journey({
    required this.segments,
    required this.departureTime,
    required this.arrivalTime,
    required this.totalTravelTime,
    required this.totalWalkingDistanceMeters,
    required this.transferCount,
  });

  /// Every distinct bus route short name appearing in this journey's
  /// segments, in order — e.g. ["29A"] for a direct trip, ["29A",
  /// "M12"] for a one-transfer trip.
  List<String> get busRouteLabels => segments
      .where((s) => s.type == JourneySegmentType.bus && s.routeShortName != null)
      .map((s) => s.routeShortName!)
      .toList();

  List<String> get metroLineLabels => segments
      .where((s) => s.type == JourneySegmentType.metro && s.routeShortName != null)
      .map((s) => s.routeShortName!)
      .toList();

  /// AUDIT ADD (Southern Railway suburban-rail data merge): kept
  /// separate from [metroLineLabels] — see [JourneySegmentType]'s doc
  /// comment for why train and metro must never be announced/labeled
  /// as the same mode.
  List<String> get trainLineLabels => segments
      .where((s) => s.type == JourneySegmentType.train && s.routeShortName != null)
      .map((s) => s.routeShortName!)
      .toList();

  bool get hasMetroSegment => segments.any((s) => s.type == JourneySegmentType.metro);

  /// AUDIT ADD (real-device validation phase — "Kumaran Kundram"
  /// investigation): true if boarding this journey's very first bus/
  /// metro, or any mid-journey transfer, required less than the
  /// standard 120-second safety buffer `JourneyPlannerService` normally
  /// guarantees. Such a journey can genuinely be faster or involve less
  /// walking than the app's normal answer, but only if the rider makes
  /// a specific, infrequent departure — missing it (a few seconds'
  /// delay walking, a bus leaving slightly early) typically means a
  /// MUCH longer wait for the next one, not a minor inconvenience. A
  /// caller (a journey-options UI, a voice narration) must warn about
  /// this rather than presenting it as equally safe as a journey
  /// without it.
  ///
  /// Deliberately checks `walkingDistanceMeters == null` to isolate
  /// genuine WAIT-for-a-scheduled-departure segments ("Wait at X" /
  /// "Transfer at X") from WALKING-only transfer segments ("Walk to X
  /// to transfer") — a short walk between two nearby stops isn't a
  /// missed-boarding risk the way a short wait for a specific trip is,
  /// even though both are `JourneySegmentType.transfer`.
  bool get hasTightConnection => segments.any((s) =>
      s.type == JourneySegmentType.transfer && s.walkingDistanceMeters == null && s.duration.inSeconds < 120);

  /// One-line explanation of this journey — what Phase 2's checklist
  /// calls "journey explanation": not just numbers, but a sentence a
  /// voice layer can speak or a card can show as its headline. Built
  /// from data already on this object, not a separate template system.
  String get summary {
    final modeParts = <String>[
      for (final label in busRouteLabels) 'Bus $label',
      for (final label in metroLineLabels) 'Metro $label',
      for (final label in trainLineLabels) 'Train $label',
    ];
    final modeText = modeParts.isEmpty ? 'Walking only' : modeParts.join(', then ');
    final transferText = transferCount == 0
        ? 'no transfers'
        : '$transferCount transfer${transferCount == 1 ? '' : 's'}';
    return '$modeText — ${totalTravelTime.inMinutes} minutes, $transferText, '
        '${totalWalkingDistanceMeters.round()}m walking';
  }
}
