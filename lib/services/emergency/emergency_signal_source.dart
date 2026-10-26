import '../../models/emergency_event.dart';

/// A raw trigger signal — the event a future device driver emits;
/// [EmergencyService] turns this into a full [EmergencyEvent] (adding
/// an id, location, and status).
class EmergencyTriggerSignal {
  final EmergencyTriggerType type;
  final String sourceDevice;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  EmergencyTriggerSignal({
    required this.type,
    required this.sourceDevice,
    DateTime? timestamp,
    this.metadata,
  }) : timestamp = timestamp ?? DateTime.now();
}

/// Contract for any future device that can trigger an emergency —
/// an IMU (fall detection), an ultrasonic/ToF sensor (imminent
/// collision), a smart cane, or a wearable's panic button.
///
/// NO HARDWARE IS IMPLEMENTED IN THIS MILESTONE — this interface is
/// the architecture requested ("prepare the architecture, do not
/// implement hardware yet"). It mirrors [IHazardDetector] and
/// [IBehaviourSignalSource] from earlier milestones deliberately: a
/// future sensor module becomes usable by implementing this interface
/// and being registered via [EmergencyService.addSignalSource] —
/// nothing inside [EmergencyService] needs to change.
abstract class IEmergencySignalSource {
  String get name;
  Stream<EmergencyTriggerSignal> get triggers;
  void dispose();
}
