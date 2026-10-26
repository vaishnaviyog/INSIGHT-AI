import 'dart:async';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/emergency_contact.dart';
import '../models/emergency_event.dart';
import 'emergency/emergency_signal_source.dart';

/// A snapshot of current GPS coordinates, supplied by the caller at
/// the moment a signal-triggered emergency fires — see
/// [EmergencyService.addSignalSource].
typedef CurrentLocationCallback = ({double? latitude, double? longitude}) Function();

/// Manages emergency contacts, a cancellable SOS countdown, and
/// emergency event logging. Also the registration point for
/// IoT-triggered emergencies (see [IEmergencySignalSource]).
///
/// SOS button, contact management, countdown, cancellation, and event
/// logging are REAL and functional (no hardware required for any of
/// them). Hardware-triggered emergencies are ALSO REAL as of
/// [FallDetectionSignalSource] — a working accelerometer-based fall
/// detector that registers through this same [addSignalSource] path,
/// with no change to any code in this class. The
/// [IEmergencySignalSource] contract remains open for additional
/// future sources (ultrasonic/ToF proximity, a smart cane, a
/// wearable's panic button) on the same terms.
///
/// Persistence follows the same pattern as [BehaviourLearningService]:
/// plain Hive boxes storing Map<String, dynamic>, no code generation.
class EmergencyService {
  static const Duration countdownDuration = Duration(seconds: 10);
  static const String _contactsBoxName = 'emergency_contacts_box';
  static const String _eventsBoxName = 'emergency_events_box';

  late Box _contactsBox;
  late Box _eventsBox;
  bool _initialized = false;

  Timer? _countdownTimer;
  EmergencyEvent? _pendingEvent;
  int _secondsRemaining = 0;

  /// Emits the remaining seconds once per tick while a countdown is
  /// active, so a caller (navigation_screen.dart) can give voice
  /// feedback without EmergencyService itself depending on
  /// AudioService — the same separation-of-concerns already used
  /// everywhere else in this codebase (e.g. RiskAssessmentService
  /// never calls AudioService directly either).
  final _countdownTickController = StreamController<int>.broadcast();
  Stream<int> get countdownTicks => _countdownTickController.stream;

  /// AUDIT FIX (real-device validation phase — emergency-system
  /// honesty check): before this fix, the countdown was announced
  /// ("S O S will be sent in N seconds...") but its OUTCOME never was —
  /// a blind user heard the countdown finish, then silence, with no way
  /// to know whether the SMS app actually opened. Emits once [_sendSos]
  /// reaches a terminal outcome, so a caller can speak it — deliberately
  /// carrying only [EmergencyEventStatus.sent]/[.failed], which per
  /// [EmergencyEventStatus]'s own doc comment means "handed off to the
  /// native SMS app," NOT "delivered." Same separation-of-concerns as
  /// [countdownTicks] above.
  final _sosOutcomeController = StreamController<EmergencyEventStatus>.broadcast();
  Stream<EmergencyEventStatus> get sosOutcomes => _sosOutcomeController.stream;

  final List<StreamSubscription<EmergencyTriggerSignal>> _sourceSubscriptions = [];

  bool get isCountdownActive =>
      _pendingEvent != null && _pendingEvent!.status == EmergencyEventStatus.countdownActive;
  int get secondsRemaining => _secondsRemaining;
  EmergencyEvent? get pendingEvent => _pendingEvent;

  Future<void> initialize() async {
    _contactsBox = await Hive.openBox(_contactsBoxName);
    _eventsBox = await Hive.openBox(_eventsBoxName);
    _initialized = true;
  }

  /// Registers a future IoT trigger source. Any signal it emits
  /// starts the same countdown a manual SOS press does — see class
  /// doc comment.
  ///
  /// [currentLocation], if provided, is called at the moment a signal
  /// fires to attach a GPS fix to the resulting event — without it, a
  /// hardware-triggered SOS (e.g. a detected fall) would send no
  /// location, which is exactly the information a real emergency
  /// message most needs. This mirrors how the manual SOS button
  /// already passes `_lastPosition` in navigation_screen.dart.
  void addSignalSource(
    IEmergencySignalSource source, {
    CurrentLocationCallback? currentLocation,
  }) {
    _sourceSubscriptions.add(source.triggers.listen((signal) {
      final location = currentLocation?.call();
      startCountdown(
        type: signal.type,
        sourceDevice: signal.sourceDevice,
        latitude: location?.latitude,
        longitude: location?.longitude,
      );
    }));
  }

  List<EmergencyContact> get contacts {
    if (!_initialized) return [];
    return _contactsBox.values
        .map((v) => EmergencyContact.fromMap(Map<dynamic, dynamic>.from(v as Map)))
        .toList();
  }

  Future<void> addContact(EmergencyContact contact) async {
    if (!_initialized) return;
    await _contactsBox.put(contact.id, contact.toMap());
  }

  Future<void> removeContact(String id) async {
    if (!_initialized) return;
    await _contactsBox.delete(id);
  }

  /// Makes stored contacts match [desired] exactly — adds any contact
  /// in [desired] not already stored, removes any stored contact not
  /// in [desired]. Used by both the onboarding Emergency Setup step
  /// and the Settings "Edit Profile" screen so neither has to
  /// duplicate this diff logic; matching is by [EmergencyContact.id],
  /// so an unchanged contact is never touched.
  Future<void> syncContacts(List<EmergencyContact> desired) async {
    if (!_initialized) return;
    final existingIds = contacts.map((c) => c.id).toSet();
    for (final contact in desired) {
      if (!existingIds.contains(contact.id)) {
        await addContact(contact);
      }
    }
    final keepIds = desired.map((c) => c.id).toSet();
    for (final existing in contacts) {
      if (!keepIds.contains(existing.id)) {
        await removeContact(existing.id);
      }
    }
  }

  /// Most-recent-first log of every emergency event, including
  /// cancelled ones — useful for both debugging and, later, a
  /// dissertation evaluation of false-trigger rates.
  List<EmergencyEvent> get eventLog {
    if (!_initialized) return [];
    final events = _eventsBox.values
        .map((v) => EmergencyEvent.fromMap(Map<dynamic, dynamic>.from(v as Map)))
        .toList();
    events.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return events;
  }

  /// Starts a cancellable countdown before sending an SOS. Safe to
  /// call even if a countdown is already active (restarts it).
  void startCountdown({
    required EmergencyTriggerType type,
    double? latitude,
    double? longitude,
    String sourceDevice = 'manual_button',
  }) {
    if (!_initialized) return;
    _countdownTimer?.cancel();

    final event = EmergencyEvent(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      triggerType: type,
      timestamp: DateTime.now(),
      status: EmergencyEventStatus.countdownActive,
      sourceDevice: sourceDevice,
      latitude: latitude,
      longitude: longitude,
    );
    _pendingEvent = event;
    _logEvent(event);
    _secondsRemaining = countdownDuration.inSeconds;

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _secondsRemaining--;
      if (_secondsRemaining <= 0) {
        timer.cancel();
        _sendSos();
      } else {
        _countdownTickController.add(_secondsRemaining);
      }
    });
  }

  /// Cancels an active countdown. Safe to call even if none is
  /// active (no-op in that case).
  void cancelCountdown() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    if (_pendingEvent != null) {
      _logEvent(_pendingEvent!.copyWith(status: EmergencyEventStatus.cancelled));
    }
    _pendingEvent = null;
    _secondsRemaining = 0;
  }

  Future<void> _sendSos() async {
    final event = _pendingEvent;
    _pendingEvent = null;
    if (event == null) return;

    bool smsLaunched = false;
    bool callLaunched = false;

    try {
      final locationText = (event.latitude != null && event.longitude != null)
          ? 'https://maps.google.com/?q=${event.latitude},${event.longitude}'
          : 'location unavailable';
      final message = Uri.encodeComponent(
        'Emergency: I may need help. My last known location: $locationText',
      );

      final numbers = contacts.map((c) => c.phoneNumber).join(',');
      if (numbers.isEmpty) {
        // Nothing to send to — logged as failed rather than silently
        // dropped, so this is visible in the event log/dashboard.
        await _logEvent(event.copyWith(status: EmergencyEventStatus.failed));
        return;
      }

      try {
        final smsUri = Uri.parse('sms:$numbers?body=$message');
        smsLaunched = await launchUrl(smsUri);
      } catch (e) {
        // ignore: avoid_print
        print('EmergencyService: SMS send failed (non-fatal, call still attempted): $e');
      }

      // Phone call / dialer: uses the `tel:` URI scheme, which opens
      // the device's native phone dialer pre-filled with the first
      // contact's number. This deliberately does NOT attempt a
      // silent/direct call (which would require the CALL_PHONE
      // permission and a native calling plugin) — `tel:` requires no
      // extra permission beyond what url_launcher already needs, so
      // it can never fail due to a missing permission, only if no
      // dialer app exists at all (handled by the try/catch below).
      // This satisfies "initiate a call, or open the dialer if direct
      // calling isn't permitted" by always taking the permission-safe
      // path.
      try {
        final firstNumber = contacts.first.phoneNumber;
        final telUri = Uri.parse('tel:$firstNumber');
        callLaunched = await launchUrl(telUri);
      } catch (e) {
        // ignore: avoid_print
        print('EmergencyService: dialer launch failed (non-fatal): $e');
      }

      await _logEvent(
        event.copyWith(
          status: smsLaunched ? EmergencyEventStatus.sent : EmergencyEventStatus.failed,
          callLaunched: callLaunched,
        ),
      );
    } catch (e) {
      // ignore: avoid_print
      print('EmergencyService: SOS send failed: $e');
      await _logEvent(event.copyWith(status: EmergencyEventStatus.failed, callLaunched: callLaunched));
    }
  }

  Future<void> _logEvent(EmergencyEvent event) async {
    if (!_initialized) return;
    await _eventsBox.put(event.id, event.toMap());
    // Only the actual send attempt's terminal outcomes are announced —
    // NOT countdownActive (already covered by countdownTicks) or
    // cancelled (already spoken directly by the caller on cancel), to
    // avoid a redundant/conflicting second announcement.
    if (event.status == EmergencyEventStatus.sent || event.status == EmergencyEventStatus.failed) {
      _sosOutcomeController.add(event.status);
    }
  }

  Future<void> dispose() async {
    _countdownTimer?.cancel();
    for (final sub in _sourceSubscriptions) {
      await sub.cancel();
    }
    await _countdownTickController.close();
    await _sosOutcomeController.close();
    if (_initialized) {
      await _contactsBox.close();
      await _eventsBox.close();
    }
  }
}
