import 'behaviour_event.dart';

/// Contract for anything that can feed [BehaviourEvent]s to
/// [BehaviourLearningService] on an ongoing basis.
///
/// THIS IS THE SEAM THAT SATISFIES THE MILESTONE 2 MODULARITY
/// REQUIREMENT: a future IMU, Time-of-Flight, or ultrasonic sensor
/// module becomes usable by implementing this interface and being
/// registered via [BehaviourLearningService.addSignalSource] —
/// nothing inside [BehaviourLearningService] needs to change, exactly
/// mirroring how [IHazardDetector] keeps `HazardDetectionService`
/// independent of any specific detection backend (see Milestone 1).
///
/// Not implemented by anything yet in this milestone — GPS, compass,
/// and hazard events are still fed to [BehaviourLearningService]
/// directly from `navigation_screen.dart` via its plain `recordX()`
/// methods, which is simpler for signals that already live inside the
/// existing screen. This interface exists for the case that doesn't
/// apply yet: a genuinely separate hardware/software module that
/// should NOT require touching `BehaviourLearningService` to add.
abstract class IBehaviourSignalSource {
  /// Human-readable identifier, for logging/telemetry.
  String get name;

  /// A continuous stream of events this source produces. Implementers
  /// should keep producing events for as long as the source is
  /// active; [BehaviourLearningService] manages the subscription
  /// lifecycle.
  Stream<BehaviourEvent> get events;

  /// Release any resources (sensor subscriptions, native handles).
  void dispose();
}
