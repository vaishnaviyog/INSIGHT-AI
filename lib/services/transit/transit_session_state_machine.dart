import '../../models/journey/journey_segment.dart';
import 'transit_progress_tracker.dart';
import 'transit_session_state.dart';

/// Explicit state machine for a journey that includes a transit leg —
/// implements the exact flow:
///
/// ```
/// walkingToBoardingStop -> boarding -> inTransit -> alighting
///   -> finalWalking -> arrived -> nextDestination -> (new route | ended)
/// ```
///
/// PURE / NO HARDWARE DEPENDENCY: this class never touches a
/// `CameraController`, GPS plugin, or TTS engine directly. It only
/// EMITS [TransitEvent]s describing what should happen — a camera
/// start/stop command, a phrase to speak, a state change — via each
/// method's return value. Real integration (at device-test time)
/// means a widget/service calls these methods when the corresponding
/// real-world condition is observed (GPS proximity, a "board"
/// button, STT recognizing a destination) and reacts to the returned
/// events by actually calling into `HazardDetectionService`,
/// `AudioService.speak`, etc. This separation is exactly what makes
/// the state machine itself testable without any of those — see
/// `test/unit/transit_session_state_machine_test.dart`.
///
/// CAMERA CONTRACT: [CameraDetectionCommand.startDetection] is
/// emitted entering [NavigationSessionState.walkingToBoardingStop]
/// (construction) and [NavigationSessionState.finalWalking].
/// [CameraDetectionCommand.stopDetection] is emitted entering
/// [NavigationSessionState.inTransit]. No other transition touches
/// the camera. [TransitEvent.resetDetectionState] is emitted
/// alongside the [NavigationSessionState.finalWalking] restart — the
/// real integration must call `HazardTemporalFilter.reset()` and
/// `CollisionTimeEstimator.reset()` there so no stale hazard/TTC state
/// from before the bus ride leaks into fresh detection.
///
/// INVALID TRANSITIONS ARE REJECTED, NOT SILENTLY FUDGED: every
/// method checks the current state and returns an EMPTY event list
/// (no state change, nothing spoken) if called from a state where
/// that transition doesn't apply — e.g. calling [confirmBoarding] a
/// second time after it already succeeded does nothing the second
/// time, rather than emitting a duplicate camera-stop command.
class TransitSessionStateMachine {
  NavigationSessionState _state;
  final JourneySegment transitSegment;
  final String? finalDestinationDescription;

  TransitProgressTracker? _progressTracker;
  bool _locationAvailable = true;
  bool _destinationApproachingAnnounced = false;

  final List<TransitEvent> _eventLog = [];

  /// [transitSegment] must be the bus/metro [JourneySegment] this
  /// session is tracking — its [JourneySegment.orderedStops] (real
  /// GTFS data — see that field's doc comment) drives automatic
  /// progress once [confirmBoarding] is called. If it's empty (no
  /// pattern data was available when the segment was built), progress
  /// updates simply produce no events — the manual-confirmation
  /// fallback remains the only way to advance, exactly as intended
  /// for "automatic progress is unavailable."
  TransitSessionStateMachine({required this.transitSegment, this.finalDestinationDescription})
      : _state = NavigationSessionState.walkingToBoardingStop {
    _log(TransitEvent.cameraCommand(CameraDetectionCommand.startDetection));
  }

  NavigationSessionState get state => _state;
  bool get isLocationAvailable => _locationAvailable;

  /// Every event emitted this session, in order — the basis for
  /// research logging (state changes, camera on/off, announcements,
  /// alighting, arrival, next-destination) per the explicit
  /// requirement. A real integration should persist/export this, not
  /// re-derive it.
  List<TransitEvent> get eventLog => List.unmodifiable(_eventLog);

  /// The ONLY method that appends to [_eventLog] — every transition
  /// method below builds its return list purely by collecting the
  /// (single-event) lists this returns, so there is exactly one
  /// logging path and no risk of an event being counted twice.
  List<TransitEvent> _log(TransitEvent event) {
    _eventLog.add(event);
    return [event];
  }

  List<TransitEvent> _transitionTo(NavigationSessionState newState, {bool? triggeredAutomatically}) {
    final previous = _state;
    _state = newState;
    return _log(TransitEvent.stateChanged(
      previousState: previous,
      newState: newState,
      triggeredAutomatically: triggeredAutomatically,
    ));
  }

  // -------------------------------------------------------------
  // WALKING_TO_BOARDING_STOP -> BOARDING
  // -------------------------------------------------------------

  /// Call when the user reaches the selected boarding stop (GPS
  /// proximity in real integration, or a manual confirmation as
  /// fallback — [triggeredAutomatically] is a logging signal only,
  /// both paths call this same method).
  List<TransitEvent> reachedBoardingStop({bool triggeredAutomatically = true}) {
    if (_state != NavigationSessionState.walkingToBoardingStop) return const [];
    final events = <TransitEvent>[];
    events.addAll(_transitionTo(NavigationSessionState.boarding, triggeredAutomatically: triggeredAutomatically));
    final routeLabel = transitSegment.routeShortName ?? transitSegment.routeLongName ?? 'your bus';
    final towards = transitSegment.routeLongName ?? transitSegment.toStopName ?? 'your destination';
    events.addAll(_log(TransitEvent.spokenPhrase(
      'Your ${transitSegment.type.name} is ready. Board $routeLabel towards $towards.',
    )));
    return events;
  }

  // -------------------------------------------------------------
  // BOARDING -> IN_TRANSIT
  // -------------------------------------------------------------

  /// Call once boarding is confirmed. Starts automatic stop-progress
  /// tracking (from [transitSegment.orderedStops]) and stops the
  /// detection camera — see this class's "CAMERA CONTRACT" doc
  /// comment.
  List<TransitEvent> confirmBoarding({bool triggeredAutomatically = false}) {
    if (_state != NavigationSessionState.boarding) return const [];
    _progressTracker = TransitProgressTracker(orderedStops: transitSegment.orderedStops);
    final events = <TransitEvent>[];
    events.addAll(_transitionTo(NavigationSessionState.inTransit, triggeredAutomatically: triggeredAutomatically));
    events.addAll(_log(TransitEvent.cameraCommand(CameraDetectionCommand.stopDetection)));
    return events;
  }

  // -------------------------------------------------------------
  // IN_TRANSIT — automatic progress
  // -------------------------------------------------------------

  /// Feeds one location fix through the internal
  /// [TransitProgressTracker] and translates its (already debounced —
  /// see that class) output into spoken announcements, advancing to
  /// [NavigationSessionState.alighting] automatically once the
  /// destination stop is confirmed reached. A no-op outside
  /// [NavigationSessionState.inTransit], or if [confirmBoarding] was
  /// never called (no tracker exists yet), or if location is
  /// currently marked unavailable (see [markLocationUnavailable]) —
  /// in all three cases this returns an empty list rather than
  /// fabricating progress.
  List<TransitEvent> updateLocation(double latitude, double longitude) {
    if (_state != NavigationSessionState.inTransit) return const [];
    if (_progressTracker == null || !_locationAvailable) return const [];

    final progressEvents = _progressTracker!.onLocationUpdate(latitude, longitude);
    if (progressEvents.isEmpty) return const [];

    final events = <TransitEvent>[];
    for (final progress in progressEvents) {
      switch (progress.type) {
        case TransitProgressEventType.nextStop:
          events.addAll(_log(TransitEvent.spokenPhrase('Next stop: ${progress.stop!.stopName}.')));
          break;
        case TransitProgressEventType.stopsRemaining:
          final remaining = progress.stopsRemaining!;
          if (remaining >= 2) {
            events.addAll(_log(TransitEvent.spokenPhrase('You have $remaining stops remaining.')));
          }
          break;
        case TransitProgressEventType.destinationApproaching:
          if (!_destinationApproachingAnnounced) {
            _destinationApproachingAnnounced = true;
            events.addAll(_log(TransitEvent.spokenPhrase(
              'Next stop is your destination. Please prepare to get down.',
            )));
          }
          break;
        case TransitProgressEventType.destinationReached:
          events.addAll(reachedDestinationStop(triggeredAutomatically: true, stopName: progress.stop?.stopName));
          break;
      }
    }
    return events;
  }

  // -------------------------------------------------------------
  // IN_TRANSIT -> ALIGHTING
  // -------------------------------------------------------------

  /// Call when the destination stop is reached — normally invoked
  /// automatically from [updateLocation], but also callable directly
  /// as the manual fallback when automatic tracking isn't available
  /// (empty [transitSegment.orderedStops], or [markLocationUnavailable]
  /// is in effect).
  List<TransitEvent> reachedDestinationStop({bool triggeredAutomatically = true, String? stopName}) {
    if (_state != NavigationSessionState.inTransit) return const [];
    final events = <TransitEvent>[];
    events.addAll(_transitionTo(NavigationSessionState.alighting, triggeredAutomatically: triggeredAutomatically));
    final destination = stopName ?? transitSegment.toStopName ?? 'your stop';
    events.addAll(_log(TransitEvent.spokenPhrase('Please get down at $destination.')));
    return events;
  }

  // -------------------------------------------------------------
  // ALIGHTING -> FINAL_WALKING
  // -------------------------------------------------------------

  /// Call once the user confirms they've actually gotten off — this
  /// is ALWAYS a user-confirmed step (there's no GPS signal for "the
  /// user physically stepped off the vehicle"), so
  /// [triggeredAutomatically] defaults to false. Restarts the
  /// detection camera and resets stale hazard/TTC state — see this
  /// class's "CAMERA CONTRACT" doc comment.
  List<TransitEvent> confirmAlighting({bool triggeredAutomatically = false}) {
    if (_state != NavigationSessionState.alighting) return const [];
    final events = <TransitEvent>[];
    events.addAll(_transitionTo(NavigationSessionState.finalWalking, triggeredAutomatically: triggeredAutomatically));
    events.addAll(_log(TransitEvent.cameraCommand(CameraDetectionCommand.startDetection)));
    events.addAll(_log(TransitEvent.resetDetectionState()));
    events.addAll(_log(TransitEvent.spokenPhrase('Please walk toward your destination.')));
    return events;
  }

  // -------------------------------------------------------------
  // FINAL_WALKING -> ARRIVED
  // -------------------------------------------------------------

  List<TransitEvent> reachedFinalDestination({bool triggeredAutomatically = true}) {
    if (_state != NavigationSessionState.finalWalking) return const [];
    final events = <TransitEvent>[];
    events.addAll(_transitionTo(NavigationSessionState.arrived, triggeredAutomatically: triggeredAutomatically));
    events.addAll(_log(TransitEvent.spokenPhrase('You have arrived at your destination.')));
    return events;
  }

  // -------------------------------------------------------------
  // ARRIVED -> NEXT_DESTINATION
  // -------------------------------------------------------------

  List<TransitEvent> promptForNextDestination() {
    if (_state != NavigationSessionState.arrived) return const [];
    final events = <TransitEvent>[];
    events.addAll(_transitionTo(NavigationSessionState.nextDestination));
    events.addAll(_log(TransitEvent.spokenPhrase('Where would you like to go now?')));
    return events;
  }

  // -------------------------------------------------------------
  // NEXT_DESTINATION -> ENDED, or a new route
  // -------------------------------------------------------------

  static const _endSessionPhrases = ['stop', "that's all", 'thats all', 'exit'];

  /// [spokenText] is whatever the STT/resolver pipeline produced —
  /// this method ONLY decides "end session" vs. "not end session"; a
  /// real destination name is the caller's responsibility to resolve
  /// via the SAME generic Chennai resolver already implemented
  /// (`GtfsLocalityResolver`, `lib/services/gtfs/gtfs_locality_resolver.dart`)
  /// — this state machine never special-cases any specific destination name.
  List<TransitEvent> provideNextDestination(String spokenText) {
    if (_state != NavigationSessionState.nextDestination) return const [];
    final normalized = spokenText.trim().toLowerCase();
    if (_endSessionPhrases.any((p) => normalized == p || normalized.contains(p))) {
      return endSession();
    }
    // A real destination was given — the caller now runs it through
    // the destination resolver/route planner and, on success, starts
    // a NEW TransitSessionStateMachine (or the walking-only
    // equivalent) for that route; this state machine's job ends here.
    return _transitionTo(NavigationSessionState.walkingToBoardingStop);
  }

  List<TransitEvent> endSession() {
    if (_state == NavigationSessionState.ended) return const [];
    return _transitionTo(NavigationSessionState.ended);
  }

  // -------------------------------------------------------------
  // GPS failure handling
  // -------------------------------------------------------------

  /// Call when GPS becomes unavailable during [inTransit] tracking.
  /// Does NOT change [state] — only suppresses [updateLocation] and
  /// emits a spoken notice, once, until [markLocationRestored] is
  /// called. Calling this again while already unavailable is a no-op
  /// (no repeated "location unavailable" announcements).
  List<TransitEvent> markLocationUnavailable() {
    if (!_locationAvailable) return const [];
    _locationAvailable = false;
    final events = <TransitEvent>[];
    events.addAll(_log(TransitEvent.locationUnavailable()));
    events.addAll(_log(TransitEvent.spokenPhrase('Location signal is temporarily unavailable.')));
    return events;
  }

  /// Call when GPS resumes — [updateLocation] calls process normally
  /// again after this. No spoken confirmation by default (avoids
  /// narrating routine GPS flicker); the resumed progress
  /// announcements speak for themselves.
  List<TransitEvent> markLocationRestored() {
    if (_locationAvailable) return const [];
    _locationAvailable = true;
    return _log(TransitEvent.locationRestored());
  }
}
