import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/journey/journey.dart';
import '../../models/journey/journey_segment.dart';
import '../../services/audio_service.dart';
import '../../services/language_service.dart';
import '../../services/location_service.dart';
import '../../services/transit/camera_status_effect.dart';
import '../../services/transit/final_walking_route_tracker.dart';
import '../../services/transit/gps_fix_validator.dart';
import '../../services/voice_understanding/voice_confirmation.dart';
import '../../services/transit/transit_session_state.dart';
import '../../services/transit/transit_session_state_machine.dart';

/// What the screen popped with — [NavigationScreen]'s call site uses
/// this to decide what happens next. Popping with a raw [String]
/// (not a member of this enum) means the user spoke a genuine new
/// destination at the "where would you like to go now?" prompt — see
/// [_TransitJourneyGuideScreenState._handleNextDestinationSpeech].
enum TransitJourneyOutcome {
  /// The user said "stop"/"that's all"/"exit" at the
  /// "where would you like to go now?" prompt — nothing further
  /// should happen.
  ended,
}

/// Guides the user through a selected [Journey], segment by segment.
///
/// AUDIT UPDATE (transit state machine production integration):
/// EVERY bus/metro segment with real ordered-stop data (there can be
/// more than one — a journey with a transfer, e.g. WALK -> BUS ->
/// METRO -> WALK, per [_transitSegmentIndices]) is driven by
/// [TransitSessionStateMachine] with AUTOMATIC GPS/GTFS progress as
/// the normal path — boarding, next-stop/stops-remaining
/// announcements, alighting, and (after the LAST transit segment)
/// the final-walking -> arrival -> "where to now?" loop all happen
/// without a manual "Continue" press. Manual confirmation (the
/// pre-existing button) remains as the fallback for boarding/
/// alighting specifically.
///
/// MULTIPLE TRANSIT SEGMENTS: when a transit segment's rider alights
/// and ANOTHER transit segment still remains later in the journey,
/// this does NOT jump to final walking — it advances to the next
/// segment in `journey.segments` (a transfer/walking segment if one
/// exists, otherwise directly the next transit segment), starting a
/// FRESH [TransitSessionStateMachine] for that next leg. Only
/// alighting from the LAST transit segment triggers the real
/// final-walking flow. Camera state naturally stays correct across a
/// transfer without special-casing: alighting from leg 1 already
/// requests the camera ON (for the transfer walk), and boarding leg 2
/// requests it OFF again — [NavigationScreen]'s
/// `_startDetectionCamera`/`_stopDetectionCamera` are idempotent
/// (already-streaming/-stopped is a no-op), so no duplicate
/// start/stop is possible.
///
/// FINAL WALKING: uses [FinalWalkingRouteTracker] — a real route
/// fetched from the SAME existing OSRM integration
/// (`LocationService.getRouteInstructions`) other walking navigation
/// in this app already uses, not a second navigation engine. If the
/// route fetch fails, this explicitly enters a documented fallback
/// (straight-line-distance-only arrival, still with hazard detection
/// active) rather than pretending a route exists.
///
/// Segments BEFORE the first transit leg (typically "walk to the
/// boarding stop") keep the ORIGINAL manual-continue flow unchanged.
///
/// CAMERA: this screen still owns no `CameraController` of its own.
/// [onStartDetectionCamera]/[onStopDetectionCamera] are
/// [NavigationScreen]'s real camera lifecycle (that screen is still
/// alive underneath this pushed route) — see that file's
/// `_startDetectionCamera`/`_stopDetectionCamera` for the actual
/// implementation. This screen only calls them in response to
/// [TransitEventType.cameraCommand] events the state machine emits;
/// it never decides camera state on its own.
class TransitJourneyGuideScreen extends StatefulWidget {
  final Journey journey;
  final LocationService locationService;
  final LanguageService languageService;
  final AudioService audioService;

  /// The ORIGINAL trip's final destination — needed so final-walking
  /// arrival can be detected (route-based when available, straight-
  /// line as the always-on safety net — see [FinalWalkingRouteTracker]).
  /// Supplied by `NavigationScreen`, which already resolved these
  /// coordinates before ever offering a transit option.
  final double destinationLat;
  final double destinationLon;

  final Future<void> Function() onStartDetectionCamera;
  final Future<void> Function() onStopDetectionCamera;
  final void Function() onResetDetectionState;

  /// AUDIT ADD (Phase NEXT — camera visibility): builds the SAME live
  /// camera-preview-plus-hazard-overlay widget `NavigationScreen`
  /// itself renders (same `CameraController`, same
  /// `HazardBoxPainter`) — a builder callback rather than passing the
  /// `CameraController` object directly, so the aspect-ratio/painter
  /// wiring stays defined in exactly one place (`NavigationScreen`)
  /// instead of being duplicated here and risking drifting out of
  /// sync. Only ever called while this screen believes the camera is
  /// active (see `_cameraActive`) — never while it's intentionally
  /// off for boarding.
  final Widget Function() buildCameraPreview;

  const TransitJourneyGuideScreen({
    super.key,
    required this.journey,
    required this.locationService,
    required this.languageService,
    required this.audioService,
    required this.destinationLat,
    required this.destinationLon,
    required this.onStartDetectionCamera,
    required this.onStopDetectionCamera,
    required this.onResetDetectionState,
    required this.buildCameraPreview,
  });

  @override
  State<TransitJourneyGuideScreen> createState() => _TransitJourneyGuideScreenState();
}

class _TransitJourneyGuideScreenState extends State<TransitJourneyGuideScreen> {
  int _segmentIndex = 0;
  StreamSubscription<Position>? _positionSubscription;
  bool _hasAnnouncedCurrentSegment = false;
  bool _isComplete = false;

  TransitSessionStateMachine? _stateMachine;
  bool _awaitingAlightingConfirmation = false;
  bool _awaitingNextDestination = false;

  bool _finalWalkingRouteUnavailable = false;
  /// AUDIT ADD (Fix 1 — fixes a real double-progression risk):
  /// generalizing route-tracking to EVERY walking segment meant the
  /// build() branch below needed a way to know "route-tracking is
  /// currently governing progress for this segment" that isn't tied
  /// to `finalWalking` specifically — without this flag, an
  /// intermediate transfer walk under automatic tracking would still
  /// show the OLD manual "I've arrived" button as pressable, and
  /// pressing it while the automatic arrival ALSO fires could advance
  /// the journey twice.
  bool _isAutoWalkTrackingActive = false;

  /// AUDIT ADD (Phase NEXT — camera visibility/status honesty): tracks
  /// the REAL current camera/hazard-detection state so `build()` can
  /// show a truthful preview-or-paused indicator instead of nothing at
  /// all. Starts `true` because `TransitSessionStateMachine`'s own
  /// constructor emits `startDetection` immediately (see that class's
  /// "CAMERA CONTRACT" doc comment) — the camera is already active by
  /// the time this screen's first frame builds.
  bool _cameraActive = true;

  JourneySegment get _currentSegment => widget.journey.segments[_segmentIndex];

  /// AUDIT FIX (multiple transit segments): every bus/metro segment
  /// with real ordered-stop data, in journey order — was previously a
  /// single index via `indexWhere`, which silently only ever handled
  /// the FIRST transit leg of a journey with a transfer.
  List<int> get _transitSegmentIndices => [
        for (int i = 0; i < widget.journey.segments.length; i++)
          if ((widget.journey.segments[i].type == JourneySegmentType.bus ||
                  widget.journey.segments[i].type == JourneySegmentType.metro ||
                  widget.journey.segments[i].type == JourneySegmentType.train) &&
              widget.journey.segments[i].orderedStops.isNotEmpty)
            i,
      ];

  bool _isLastTransitSegment(int index) {
    final indices = _transitSegmentIndices;
    return indices.isNotEmpty && indices.last == index;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterSegment(0));
  }

  @override
  void dispose() {
    _positionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _enterSegment(int index) async {
    _positionSubscription?.cancel();
    _isAutoWalkTrackingActive = false;

    if (index >= widget.journey.segments.length) {
      // No more segments at all (shouldn't normally happen — the
      // journey always ends with a final walking segment per
      // JourneyPlannerService — but handled rather than crashing).
      setState(() => _isComplete = true);
      return;
    }

    if (_transitSegmentIndices.contains(index)) {
      await _enterTransitSegment(index);
      return;
    }

    setState(() {
      _segmentIndex = index;
      _hasAnnouncedCurrentSegment = false;
    });
    final segment = widget.journey.segments[index];
    await widget.languageService.speak(widget.audioService, segment.description);
    if (mounted) setState(() => _hasAnnouncedCurrentSegment = true);

    // AUDIT ADD (Fix 1 — intermediate transfer walking): a segment
    // with a real distance AND a real target (toLat/toLon — see
    // JourneySegment's doc comment on where these come from) now gets
    // the SAME automatic OSRM-route-tracking treatment as final
    // walking, not just manual "Continue". A "Wait at X" transfer
    // segment (same stop, time-based gap, no walkingDistanceMeters —
    // see JourneyPlannerService's construction of it) has nothing to
    // route to, so it correctly falls through to the manual flow
    // below instead — there's no fabricated route to track there.
    if (segment.walkingDistanceMeters != null && segment.toLat != null && segment.toLon != null) {
      await _startWalkingRouteTracking(
        destinationLat: segment.toLat!,
        destinationLon: segment.toLon!,
        onArrival: () => _enterSegment(index + 1),
      );
    }
    // Else: stays on the manual "Continue"/"I've arrived" UI path
    // (see build()) — the pre-existing behavior, unchanged, for the
    // "Wait at X" case specifically.
  }

  Future<void> _advanceToNextOrFinish() async {
    if (_segmentIndex + 1 < widget.journey.segments.length) {
      await _enterSegment(_segmentIndex + 1);
    } else {
      _positionSubscription?.cancel();
      setState(() => _isComplete = true);
      await widget.languageService.speak(widget.audioService, 'You have arrived at your destination.');
    }
  }

  // -------------------------------------------------------------
  // Transit segment — state-machine-driven automatic flow
  // -------------------------------------------------------------

  Future<void> _enterTransitSegment(int index) async {
    setState(() {
      _segmentIndex = index;
      _hasAnnouncedCurrentSegment = false;
    });
    final machine = TransitSessionStateMachine(transitSegment: _currentSegment);
    _stateMachine = machine;
    // Construction already logged a startDetection command — camera
    // is already known-on from the preceding walking/transfer segment
    // in every real case, so nothing further to process here; see
    // this class's "MULTIPLE TRANSIT SEGMENTS" doc note on why a
    // redundant start is always safe (idempotent) regardless.
    await _processTransitEvents(machine.reachedBoardingStop());
    if (mounted) setState(() => _hasAnnouncedCurrentSegment = true);
  }

  /// AUDIT ADD (Phase E3 — wrong-bus safety): previously this was a
  /// single, unverified `confirmBoarding()` call — pressing this
  /// button was trusted completely, with no cross-check against the
  /// actual planned route. GPS cannot identify which physical vehicle
  /// a user is standing next to or has boarded, so this asks the user
  /// directly instead: speaks the expected route + direction, then
  /// requires an explicit affirmative answer (or a spoken route number
  /// that matches — see voice_confirmation.dart) before boarding is
  /// confirmed. A "wrong bus"/mismatch/ambiguous response NEVER
  /// silently continues as though verification succeeded — the state
  /// machine simply stays in `boarding`, unchanged, and this button
  /// remains pressable again for a retry.
  static const int _maxBoardingVerificationAttempts = 2;

  Future<void> _confirmBoardingManually() async {
    final machine = _stateMachine;
    if (machine == null) return;
    final verified = await _verifyBoardingWithUser(_currentSegment);
    if (!verified) return;
    await _processTransitEvents(machine.confirmBoarding(triggeredAutomatically: false));
    _startTransitProgressTracking();
  }

  /// Returns true only on an explicit, unambiguous confirmation that
  /// this is the correct bus/metro. Every non-confirmed outcome
  /// (rejected, ambiguous, timeout) speaks a clear explanation and
  /// returns false — the caller must not proceed on anything less than
  /// [BoardingVerificationOutcome.confirmed].
  Future<bool> _verifyBoardingWithUser(JourneySegment segment) async {
    final expectedRoute = segment.routeShortName ?? segment.routeLongName;
    final towards = segment.routeLongName ?? segment.toStopName ?? 'your destination';
    final routePhrase =
        expectedRoute != null ? '${segment.type.name} $expectedRoute towards $towards' : '${segment.type.name} towards $towards';

    for (int attempt = 1; attempt <= _maxBoardingVerificationAttempts; attempt++) {
      await widget.languageService.speak(
        widget.audioService,
        'You should be boarding $routePhrase. Say yes to confirm, or say wrong bus if this is not your bus.',
      );
      final completer = Completer<String?>();
      await widget.audioService.listen(
        (text) {
          if (!completer.isCompleted) completer.complete(text);
        },
        onError: (_) {
          if (!completer.isCompleted) completer.complete(null);
        },
      );
      final answer = await completer.future.timeout(const Duration(seconds: 15), onTimeout: () => null);
      final outcome = interpretBoardingVerificationAnswer(answer, expectedRouteShortName: expectedRoute);

      switch (outcome) {
        case BoardingVerificationOutcome.confirmed:
          return true;
        case BoardingVerificationOutcome.rejected:
          await widget.languageService.speak(
            widget.audioService,
            "Okay, please wait for the correct bus. Try again once you've boarded $routePhrase.",
          );
          return false;
        case BoardingVerificationOutcome.ambiguous:
          if (attempt < _maxBoardingVerificationAttempts) {
            await widget.languageService.speak(widget.audioService, 'Sorry, I didn\'t understand. Please say yes or wrong bus.');
            continue;
          }
      }
    }

    await widget.languageService.speak(
      widget.audioService,
      "I couldn't confirm your bus. Please double-check the route number yourself before boarding, then try again.",
    );
    return false;
  }

  void _startTransitProgressTracking() {
    _positionSubscription?.cancel();
    // AUDIT ADD (Phase E2 — GPS safety hardening): a fresh validator
    // per tracking session (see gps_fix_validator.dart's own doc
    // comment) — pre-filters stale/low-accuracy/implausible-jump fixes
    // BEFORE they ever reach TransitProgressTracker's proven
    // two-consecutive-reading hysteresis, which is untouched below.
    final gpsFixValidator = GpsFixValidator();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10),
    ).listen(
      (position) async {
        final machine = _stateMachine;
        if (machine == null || machine.state != NavigationSessionState.inTransit) return;
        final validation = gpsFixValidator.validate(
          latitude: position.latitude,
          longitude: position.longitude,
          now: DateTime.now(),
          timestamp: position.timestamp,
          accuracyMeters: position.accuracy,
        );
        if (!validation.accepted) return;
        await _processTransitEvents(machine.updateLocation(position.latitude, position.longitude));
      },
      onError: (Object error) async {
        final machine = _stateMachine;
        if (machine == null) return;
        await _processTransitEvents(machine.markLocationUnavailable());
      },
    );
  }

  /// Manual fallback for alighting.
  Future<void> _confirmAlightingManually() async {
    final machine = _stateMachine;
    if (machine == null) return;
    _positionSubscription?.cancel();
    setState(() => _awaitingAlightingConfirmation = false);
    await _processTransitEvents(machine.confirmAlighting(triggeredAutomatically: false));
    await _handlePostAlighting();
  }

  /// AUDIT ADD (multiple transit segments): called once
  /// [TransitSessionStateMachine.confirmAlighting] has fired — decides
  /// whether this was the LAST transit leg (real final walking begins)
  /// or an intermediate one (advance to the next journey segment,
  /// which starts a fresh state machine if it's another transit leg,
  /// or route-tracked walking if it's a transfer walk — see
  /// [_enterSegment]).
  Future<void> _handlePostAlighting() async {
    final justAlightedIndex = _segmentIndex;
    if (_isLastTransitSegment(justAlightedIndex)) {
      await _startFinalWalkingRouteTracking();
    } else {
      await _enterSegment(justAlightedIndex + 1);
    }
  }

  // -------------------------------------------------------------
  // AUDIT UPDATE (Fix 1 — intermediate transfer walking): this is now
  // a GENERIC walking-route-tracking helper, used for EVERY real
  // walking segment (the initial walk to the boarding stop, any
  // transfer walk between two transit legs, AND the final walk) — not
  // only the final one. Reuses the existing OSRM integration
  // (LocationService.getRouteInstructions) already used elsewhere in
  // this app; straight-line distance remains ONLY the arrival safety
  // net (see FinalWalkingRouteTracker's doc comment). [onArrival] is
  // what differs per call site: continue to the next journey segment
  // for an intermediate walk, or the real arrival/next-destination
  // flow for the final one.
  // -------------------------------------------------------------

  Future<void> _startWalkingRouteTracking({
    required double destinationLat,
    required double destinationLon,
    required Future<void> Function() onArrival,
  }) async {
    _isAutoWalkTrackingActive = true;
    final currentPosition = await widget.locationService.getCurrentLocation();
    List<FinalWalkingWaypoint> waypoints = const [];
    if (currentPosition != null) {
      final route = await widget.locationService.getRouteInstructions(
        currentPosition,
        destinationLat,
        destinationLon,
      );
      if (route != null && route.steps.isNotEmpty) {
        waypoints = [
          for (final step in route.steps)
            FinalWalkingWaypoint(instruction: step.instruction, lat: step.location.latitude, lon: step.location.longitude),
        ];
      }
    }

    final routeUnavailable = waypoints.isEmpty;
    final tracker = FinalWalkingRouteTracker(
      waypoints: waypoints,
      destinationLat: destinationLat,
      destinationLon: destinationLon,
    );
    _finalWalkingRouteUnavailable = routeUnavailable;
    if (mounted) setState(() {});

    if (routeUnavailable) {
      // Explicit, honest fallback — never pretend a route exists.
      // Hazard detection is unaffected either way (it only depends on
      // the camera command contract, not on route availability).
      await widget.languageService.speak(
        widget.audioService,
        "I couldn't get turn-by-turn directions right now. I'll let you know when you arrive.",
      );
    }

    _positionSubscription?.cancel();
    // AUDIT ADD (Phase E2 — GPS safety hardening): see the matching
    // comment in _startTransitProgressTracking — same pre-filter,
    // FinalWalkingRouteTracker's own hysteresis is untouched.
    final gpsFixValidator = GpsFixValidator();
    _positionSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 5),
    ).listen((position) async {
      final validation = gpsFixValidator.validate(
        latitude: position.latitude,
        longitude: position.longitude,
        now: DateTime.now(),
        timestamp: position.timestamp,
        accuracyMeters: position.accuracy,
      );
      if (!validation.accepted) return;
      final events = tracker.onLocationUpdate(position.latitude, position.longitude);
      for (final event in events) {
        if (event.type == FinalWalkingEventType.stepInstruction) {
          await widget.languageService.speak(widget.audioService, event.instruction!);
        } else if (event.type == FinalWalkingEventType.destinationReached) {
          _positionSubscription?.cancel();
          _isAutoWalkTrackingActive = false;
          await onArrival();
        }
      }
    });
  }

  Future<void> _startFinalWalkingRouteTracking() => _startWalkingRouteTracking(
        destinationLat: widget.destinationLat,
        destinationLon: widget.destinationLon,
        onArrival: _handleFinalArrival,
      );

  Future<void> _handleFinalArrival() async {
    final machine = _stateMachine;
    if (machine == null) return;
    await _processTransitEvents(machine.reachedFinalDestination());
    await _processTransitEvents(machine.promptForNextDestination());
    _listenForNextDestination();
  }

  void _listenForNextDestination() {
    if (!mounted) return;
    setState(() => _awaitingNextDestination = true);
    widget.audioService.listen(
      (text) => _handleNextDestinationSpeech(text),
      onError: (_) {}, // silence — user can use the manual fallback button shown in build()
    );
  }

  Future<void> _handleNextDestinationSpeech(String text) async {
    final machine = _stateMachine;
    if (machine == null) return;
    if (!mounted) return;
    setState(() => _awaitingNextDestination = false);
    final events = machine.provideNextDestination(text);
    await _processTransitEvents(events);

    if (machine.state == NavigationSessionState.ended) {
      if (mounted) Navigator.of(context).pop(TransitJourneyOutcome.ended);
      return;
    }
    if (machine.state == NavigationSessionState.walkingToBoardingStop) {
      // A real destination was resolved by voice — NavigationScreen's
      // OWN generic destination resolver/route planner (the SAME one
      // used for every other destination in this app — see that
      // file's `_fetchRoute`) is what actually looks it up; this
      // screen only hands back the raw spoken text, never resolving
      // any destination itself.
      if (mounted) Navigator.of(context).pop(text);
    }
  }

  /// Translates each [TransitEvent] into a real side effect — the
  /// camera contract, spoken phrases, and hazard-state reset. This is
  /// the ONLY place in this screen that consumes [TransitEvent]s.
  Future<void> _processTransitEvents(List<TransitEvent> events) async {
    for (final event in events) {
      switch (event.type) {
        case TransitEventType.stateChanged:
          if (mounted) setState(() {});
          if (event.newState == NavigationSessionState.alighting) {
            setState(() => _awaitingAlightingConfirmation = true);
          }
          break;
        case TransitEventType.spokenPhrase:
          await widget.languageService.speak(widget.audioService, event.spokenPhrase!);
          break;
        case TransitEventType.cameraCommand:
          // AUDIT ADD (Phase NEXT — camera visibility/status honesty):
          // the underlying camera/YOLO pipeline was ALREADY continuing
          // to run correctly through this screen the whole time
          // (confirmed by reading `NavigationScreen._processCameraImage`
          // — nothing there gates on route visibility, only on
          // `_isDisposed`/`_enableObjectDetection`/re-entrancy). The
          // real gap was that NOTHING here ever told the user hazard
          // detection had turned off for boarding, or showed it was
          // back on — a silent downgrade in exactly the sense the
          // "never silently downgrade... without telling the user"
          // principle warns against, even though the underlying
          // capability itself was never broken.
          final effect = cameraStatusEffectFor(event.cameraCommand!);
          if (effect.cameraActive) {
            await widget.onStartDetectionCamera();
          } else {
            await widget.onStopDetectionCamera();
          }
          if (mounted) setState(() => _cameraActive = effect.cameraActive);
          // Spoken ONCE, at the moment protection actually turns off —
          // not repeated on every frame/rebuild. Deliberately calm, not
          // alarming: this is the expected, intentional state while
          // genuinely riding a vehicle, not a failure.
          if (effect.spokenPhrase != null) {
            await widget.languageService.speak(widget.audioService, effect.spokenPhrase!);
          }
          break;
        case TransitEventType.resetDetectionState:
          widget.onResetDetectionState();
          break;
        case TransitEventType.locationUnavailable:
        case TransitEventType.locationRestored:
          if (mounted) setState(() {});
          break;
      }
    }
  }

  /// AUDIT ADD (Phase NEXT — camera visibility/status honesty): the
  /// single place this screen decides what to show for hazard-
  /// protection state — driven by `_cameraActive`, the SAME flag kept
  /// in lockstep with the real camera commands the state machine
  /// emits (see `_processTransitEvents`), so this can never show
  /// "protected" while the camera is actually off, or vice versa.
  /// When active: a real, live, bounded-height camera preview (the
  /// exact same feed `NavigationScreen` shows, not a second camera).
  /// When paused: a calm, explicit, honest status line — never blank,
  /// never implying protection that isn't there.
  Widget _buildHazardStatusArea() {
    if (_cameraActive) {
      return Container(
        height: 220,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.deepPurpleAccent)),
        child: Semantics(
          label: 'Hazard detection camera preview, active',
          child: widget.buildCameraPreview(),
        ),
      );
    }
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.grey.shade900),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off, color: Colors.grey),
            SizedBox(width: 10),
            Flexible(
              child: Text(
                'Hazard detection paused — you are on board',
                style: TextStyle(color: Colors.grey, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(JourneySegmentType type) {
    switch (type) {
      case JourneySegmentType.walking:
        return Icons.directions_walk;
      case JourneySegmentType.bus:
        return Icons.directions_bus;
      case JourneySegmentType.metro:
        return Icons.subway;
      case JourneySegmentType.train:
        return Icons.train;
      case JourneySegmentType.transfer:
        return Icons.swap_horiz;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isComplete) {
      return Scaffold(
        appBar: AppBar(title: const Text('Journey Complete')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text('You have arrived at your destination.', style: TextStyle(fontSize: 20), textAlign: TextAlign.center),
          ),
        ),
      );
    }

    final segment = _currentSegment;
    final machine = _stateMachine;

    if (machine != null && _transitSegmentIndices.contains(_segmentIndex)) {
      return Scaffold(
        appBar: AppBar(title: Text(_transitStatusLabel(machine.state))),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildHazardStatusArea(),
              const SizedBox(height: 20),
              Icon(_iconFor(segment.type), size: 72, color: Colors.deepPurpleAccent),
              const SizedBox(height: 24),
              Semantics(
                liveRegion: true,
                child: Text(_transitStatusLabel(machine.state), style: const TextStyle(fontSize: 22), textAlign: TextAlign.center),
              ),
              if (!machine.isLocationAvailable) ...[
                const SizedBox(height: 12),
                const Text('Location signal is temporarily unavailable.', style: TextStyle(color: Colors.orange)),
              ],
              const SizedBox(height: 40),
              if (machine.state == NavigationSessionState.boarding)
                ElevatedButton(
                  onPressed: _confirmBoardingManually,
                  child: const Text("I've boarded (manual fallback)"),
                ),
              if (_awaitingAlightingConfirmation && machine.state == NavigationSessionState.alighting)
                ElevatedButton(
                  onPressed: _confirmAlightingManually,
                  child: const Text("I've gotten off (manual fallback)"),
                ),
              if (_awaitingNextDestination) ...[
                const SizedBox(height: 12),
                const Text('Listening for your next destination...'),
                TextButton(
                  onPressed: () => _handleNextDestinationSpeech('stop'),
                  child: const Text('End session'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    // AUDIT FIX (Fix 1): this view now covers ANY walking segment
    // under automatic route-tracking — not just true final walking —
    // gated on `_isAutoWalkTrackingActive` specifically so the OLD
    // manual "Continue"/"I've arrived" branch below can never be
    // reachable (and therefore never double-advance the journey)
    // while automatic tracking is governing progress.
    if (_isAutoWalkTrackingActive) {
      return Scaffold(
        appBar: AppBar(title: const Text('Walking')),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // AUDIT ADD (Phase NEXT): every walking segment under
              // automatic tracking — the walk to a transfer stop AND
              // the final walk to the destination — is exactly when
              // hazard protection matters most, so it gets the same
              // honest visibility as the transit-segment branch above.
              _buildHazardStatusArea(),
              const SizedBox(height: 20),
              const Icon(Icons.directions_walk, size: 72, color: Colors.deepPurpleAccent),
              const SizedBox(height: 24),
              Text(
                _finalWalkingRouteUnavailable
                    ? 'Walking toward your destination (turn-by-turn directions unavailable).'
                    : 'Following walking directions to your destination.',
                style: const TextStyle(fontSize: 20),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    final isLast = _segmentIndex == widget.journey.segments.length - 1;
    return Scaffold(
      appBar: AppBar(title: Text('Step ${_segmentIndex + 1} of ${widget.journey.segments.length}')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // AUDIT ADD (Phase NEXT): this fallback branch is reached
            // for a segment with no real route to auto-track (e.g. a
            // time-based "Wait at X" transfer gap) — the user is still
            // not boarded, so hazard protection is still on and still
            // deserves the same honest visibility as every other
            // walking-adjacent state.
            _buildHazardStatusArea(),
            const SizedBox(height: 20),
            Icon(_iconFor(segment.type), size: 72, color: Colors.deepPurpleAccent),
            const SizedBox(height: 24),
            Semantics(
              liveRegion: true,
              child: Text(segment.description, style: const TextStyle(fontSize: 22), textAlign: TextAlign.center),
            ),
            if (segment.walkingDistanceMeters != null) ...[
              const SizedBox(height: 12),
              Text('${segment.walkingDistanceMeters!.round()} m', style: const TextStyle(color: Colors.grey)),
            ],
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _hasAnnouncedCurrentSegment ? _advanceToNextOrFinish : null,
              child: Text(segment.type == JourneySegmentType.walking ? "I've arrived" : (isLast ? 'Finish' : 'Continue')),
            ),
          ],
        ),
      ),
    );
  }

  String _transitStatusLabel(NavigationSessionState state) {
    switch (state) {
      case NavigationSessionState.boarding:
        return 'Waiting to board';
      case NavigationSessionState.inTransit:
        return 'On board — tracking your journey';
      case NavigationSessionState.alighting:
        return 'Please get down';
      case NavigationSessionState.finalWalking:
        return 'Walking to your destination';
      case NavigationSessionState.arrived:
        return 'You have arrived';
      case NavigationSessionState.nextDestination:
        return 'Where would you like to go now?';
      case NavigationSessionState.ended:
        return 'Session ended';
      case NavigationSessionState.walkingToBoardingStop:
        return 'Walking to boarding stop';
    }
  }
}
