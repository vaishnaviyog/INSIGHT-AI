/// Explicit navigation session states for a journey that includes a
/// transit (bus/metro) leg. Pure data — no Flutter/camera/GPS
/// dependency, so [TransitSessionStateMachine] built on this is fully
/// unit-testable without hardware. See that class's doc comment for
/// the full transition diagram.
enum NavigationSessionState {
  walkingToBoardingStop,
  boarding,
  inTransit,
  alighting,
  finalWalking,
  arrived,
  nextDestination,
  ended,
}

/// A command the state machine wants issued to the REAL camera/
/// detection pipeline. This is a pure request — the state machine
/// never touches a `CameraController` itself (see
/// `TransitSessionStateMachine`'s class doc comment on why); some
/// other piece of code (at real-device integration time) is
/// responsible for actually starting/stopping camera streaming and
/// YOLO inference when it observes one of these commands.
enum CameraDetectionCommand { startDetection, stopDetection }

enum TransitEventType {
  stateChanged,
  spokenPhrase,
  cameraCommand,
  resetDetectionState,
  locationUnavailable,
  locationRestored,
}

/// One thing that happened as a result of a state-machine transition.
/// A single method call can produce several of these (e.g. a state
/// change AND a camera command AND a spoken phrase) — callers get them
/// as an ordered list so real integration code can act on each one
/// without guessing which fields are relevant for which event.
class TransitEvent {
  final TransitEventType type;
  final DateTime timestamp;

  /// Set for [TransitEventType.stateChanged].
  final NavigationSessionState? previousState;
  final NavigationSessionState? newState;

  /// Set for [TransitEventType.spokenPhrase].
  final String? spokenPhrase;

  /// Set for [TransitEventType.cameraCommand].
  final CameraDetectionCommand? cameraCommand;

  /// Set for [TransitEventType.stateChanged] transitions triggered by
  /// automatic GPS/GTFS progress vs. the manual fallback — research-
  /// logging signal only (see the "manual fallback must be clearly
  /// distinguished" requirement); never used for control flow.
  final bool? triggeredAutomatically;

  TransitEvent._({
    required this.type,
    DateTime? timestamp,
    this.previousState,
    this.newState,
    this.spokenPhrase,
    this.cameraCommand,
    this.triggeredAutomatically,
  }) : timestamp = timestamp ?? DateTime.now();

  factory TransitEvent.stateChanged({
    required NavigationSessionState previousState,
    required NavigationSessionState newState,
    bool? triggeredAutomatically,
  }) =>
      TransitEvent._(
        type: TransitEventType.stateChanged,
        previousState: previousState,
        newState: newState,
        triggeredAutomatically: triggeredAutomatically,
      );

  factory TransitEvent.spokenPhrase(String phrase) =>
      TransitEvent._(type: TransitEventType.spokenPhrase, spokenPhrase: phrase);

  factory TransitEvent.cameraCommand(CameraDetectionCommand command) =>
      TransitEvent._(type: TransitEventType.cameraCommand, cameraCommand: command);

  factory TransitEvent.resetDetectionState() => TransitEvent._(type: TransitEventType.resetDetectionState);

  factory TransitEvent.locationUnavailable() => TransitEvent._(type: TransitEventType.locationUnavailable);

  factory TransitEvent.locationRestored() => TransitEvent._(type: TransitEventType.locationRestored);

  @override
  String toString() {
    switch (type) {
      case TransitEventType.stateChanged:
        return 'TransitEvent(stateChanged: $previousState -> $newState'
            '${triggeredAutomatically != null ? ', auto=$triggeredAutomatically' : ''})';
      case TransitEventType.spokenPhrase:
        return 'TransitEvent(spokenPhrase: "$spokenPhrase")';
      case TransitEventType.cameraCommand:
        return 'TransitEvent(cameraCommand: $cameraCommand)';
      case TransitEventType.resetDetectionState:
        return 'TransitEvent(resetDetectionState)';
      case TransitEventType.locationUnavailable:
        return 'TransitEvent(locationUnavailable)';
      case TransitEventType.locationRestored:
        return 'TransitEvent(locationRestored)';
    }
  }
}
