/// How an emergency event was triggered.
enum EmergencyTriggerType {
  manual,
  fallDetected,
  panicButton,
  proximityCritical,
  other,
}

/// Lifecycle status of a single SOS event.
///
/// AUDIT NOTE (engineering-hardening phase — emergency-system honesty
/// check): [sent] means ONLY that `EmergencyService._sendSos()`
/// successfully launched the native SMS app via a `sms:` URI
/// (`launchUrl` returned true) — it is NOT a delivery confirmation.
/// Whether that message is actually transmitted depends on the native
/// SMS app, carrier connectivity, and (on many Android builds) the
/// user/OS still needing to tap "send" in that app's own UI. This
/// value's NAME is not renamed here despite that risk of
/// misinterpretation — `EmergencyEvent.fromMap`/`toMap` persist it via
/// `.name`, so renaming it would break deserializing any
/// already-logged event on a real device. Treat every read of `sent`
/// as "handed off to the native SMS app," never as "confirmed
/// delivered" — true delivery confirmation would require a backend
/// relay, which this phase deliberately does not introduce (see
/// EmergencyService's own doc comment).
enum EmergencyEventStatus { countdownActive, cancelled, sent, failed }

/// A single logged emergency event — created the moment a trigger
/// fires (even if later cancelled), so the log reflects everything
/// that happened, not just successful sends.
class EmergencyEvent {
  final String id;
  final EmergencyTriggerType triggerType;
  final DateTime timestamp;
  final double? latitude;
  final double? longitude;
  final EmergencyEventStatus status;

  /// Which source produced this (e.g. 'manual_button', 'imu', in the
  /// future 'smart_cane') — mirrors DetectedHazard.sourceDetector's
  /// role for the hazard-detection pipeline.
  final String sourceDevice;

  /// Whether the device's phone dialer was successfully launched
  /// (via a `tel:` URI) for this event. Null for events logged before
  /// this field existed, or when the event never reached the send
  /// step (e.g. cancelled) — never fabricated as false/true when the
  /// call step never ran.
  final bool? callLaunched;

  const EmergencyEvent({
    required this.id,
    required this.triggerType,
    required this.timestamp,
    required this.status,
    required this.sourceDevice,
    this.latitude,
    this.longitude,
    this.callLaunched,
  });

  EmergencyEvent copyWith({EmergencyEventStatus? status, bool? callLaunched}) => EmergencyEvent(
        id: id,
        triggerType: triggerType,
        timestamp: timestamp,
        status: status ?? this.status,
        sourceDevice: sourceDevice,
        latitude: latitude,
        longitude: longitude,
        callLaunched: callLaunched ?? this.callLaunched,
      );

  Map<String, dynamic> toMap() => {
        'id': id,
        'triggerType': triggerType.name,
        'timestamp': timestamp.toIso8601String(),
        'latitude': latitude,
        'longitude': longitude,
        'status': status.name,
        'sourceDevice': sourceDevice,
        'callLaunched': callLaunched,
      };

  factory EmergencyEvent.fromMap(Map<dynamic, dynamic> map) => EmergencyEvent(
        id: map['id'] as String,
        triggerType: EmergencyTriggerType.values.byName(map['triggerType'] as String),
        timestamp: DateTime.parse(map['timestamp'] as String),
        latitude: (map['latitude'] as num?)?.toDouble(),
        longitude: (map['longitude'] as num?)?.toDouble(),
        status: EmergencyEventStatus.values.byName(map['status'] as String),
        sourceDevice: map['sourceDevice'] as String,
        callLaunched: map['callLaunched'] as bool?,
      );
}
