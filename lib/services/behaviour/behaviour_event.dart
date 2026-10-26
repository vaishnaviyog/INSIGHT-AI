/// Sensor-agnostic signal types that [BehaviourLearningService] knows
/// how to fold into a [UserBehaviourProfile].
///
/// WHY THIS EXISTS: today, every one of these events is produced
/// directly by `navigation_screen.dart` (from GPS, the compass, and
/// the hazard-detection pipeline). In a future milestone, dedicated
/// IoT sensors (an IMU, a Time-of-Flight or ultrasonic proximity
/// sensor) can produce these SAME event types and feed them to
/// [BehaviourLearningService] via [IBehaviourSignalSource] — the
/// service itself never needs to know whether an event came from the
/// phone's built-in sensors or an external device.
library behaviour_event;

/// Base type for every behaviour signal. Deliberately minimal — just
/// a timestamp — so new event types are cheap to add later.
abstract class BehaviourEvent {
  final DateTime timestamp;
  BehaviourEvent({DateTime? timestamp}) : timestamp = timestamp ?? DateTime.now();
}

/// A single position/speed sample. Today this comes from
/// `Geolocator`'s GPS stream; a future IMU-fused positioning module
/// could produce the same event with a more accurate speed estimate.
class PositionSampleEvent extends BehaviourEvent {
  final double latitude;
  final double longitude;

  /// Meters/second, if known. Null if the source can't estimate speed
  /// directly (e.g. a single GPS fix with no recent history) — the
  /// consumer is expected to derive speed from consecutive samples in
  /// that case.
  final double? speedMetersPerSecond;

  PositionSampleEvent({
    required this.latitude,
    required this.longitude,
    this.speedMetersPerSecond,
    super.timestamp,
  });
}

/// Emitted when a hazard warning is spoken to the user.
class ObstacleWarningIssuedEvent extends BehaviourEvent {
  final String hazardLabel;

  /// Coarse proximity at the moment the warning was issued (from
  /// [DetectedHazard.distanceBand]), stored as a plain string here to
  /// keep this event model independent of the hazard-detection
  /// module's types.
  final String distanceBand;

  ObstacleWarningIssuedEvent({
    required this.hazardLabel,
    required this.distanceBand,
    super.timestamp,
  });
}

/// Emitted when a previously-warned-about obstacle is no longer
/// detected in front of the user — the proxy signal
/// [BehaviourLearningService] currently uses to estimate reaction
/// time and infer a "successful avoidance". A future proximity sensor
/// (ToF/ultrasonic) could instead emit this event based on a real
/// measured clearance, without changing the consuming logic.
class ObstacleClearedEvent extends BehaviourEvent {
  ObstacleClearedEvent({super.timestamp});
}

/// Emitted when the app speaks a turn instruction containing a clear
/// left/right direction.
class TurnTakenEvent extends BehaviourEvent {
  /// 'left' or 'right'.
  final String direction;
  TurnTakenEvent({required this.direction, super.timestamp});
}

/// Emitted once when a navigation session begins (a route is found
/// and turn-by-turn guidance starts).
class NavigationSessionStartedEvent extends BehaviourEvent {
  NavigationSessionStartedEvent({super.timestamp});
}

/// Emitted once when a navigation session ends (the navigation screen
/// is disposed).
class NavigationSessionEndedEvent extends BehaviourEvent {
  NavigationSessionEndedEvent({super.timestamp});
}
