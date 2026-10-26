import 'package:hive_flutter/hive_flutter.dart';

/// Lightweight persistence for the ONE piece of navigation state that
/// actually matters for surviving an Android/ColorOS background
/// process kill: WHICH DESTINATION the user was navigating to.
///
/// AUDIT ADD (real-device validation phase — CRITICAL background
/// state persistence fix): confirmed live on this exact device (OPPO
/// CPH2421, ColorOS) that backgrounding [NavigationScreen] for as
/// little as ~20-30 seconds can cause the OS to kill the Activity,
/// after which the app cold-starts back to [HomeScreen] with the
/// in-progress destination/route completely gone — a real safety gap
/// for a blind user relying on this app mid-walk.
///
/// DELIBERATELY DOES NOT persist route polylines, step lists, current
/// step index, or any live service/controller/sensor object — those
/// are either non-serializable, or would risk silently resuming a
/// STALE route against a position the user may have moved from during
/// the gap (exactly what this fix must NOT do — see [NavigationScreen]
/// doc comment on `isRestoredSession`). Restoration instead re-runs
/// the SAME real destination-search/route-fetch path a fresh voice
/// destination already uses, so GPS/route are always freshly
/// (re)computed, never assumed valid from before the gap.
///
/// Uses Hive — already the persistence mechanism this project uses
/// for [EmergencyService]/[BehaviourLearningService]'s equally simple
/// key-value needs, so this adds no new dependency.
class NavigationSessionPersistenceService {
  static const String _boxName = 'navigation_session_box';
  static const String _destinationKey = 'destinationText';
  static const String _savedAtKey = 'savedAtIso8601';

  /// A saved session older than this is treated as stale and ignored
  /// (and proactively cleared) rather than restored — resuming a
  /// destination the user asked for half an hour ago without them
  /// re-confirming it is its own kind of unsafe surprise.
  static const Duration maxSessionAge = Duration(minutes: 30);

  Box? _box;

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
  }

  /// Call once a destination has been geocoded AND a route (walking or
  /// transit) has actually been found for it — never on a bare
  /// spoken/typed destination that hasn't been validated yet, so a
  /// misheard/nonsense destination (see the real on-device
  /// "Guduvanchery" -> "good" misrecognition observed this session)
  /// can never be what gets restored later.
  Future<void> saveActiveSession(String destinationText) async {
    final box = _box;
    if (box == null || destinationText.trim().isEmpty) return;
    await box.put(_destinationKey, destinationText);
    await box.put(_savedAtKey, DateTime.now().toIso8601String());
  }

  Future<void> clearActiveSession() async {
    final box = _box;
    if (box == null) return;
    await box.delete(_destinationKey);
    await box.delete(_savedAtKey);
  }

  /// Returns the saved destination text if a session exists and is
  /// still fresh (within [maxSessionAge]) — null otherwise, including
  /// when nothing was ever saved, or the saved data is incomplete/
  /// corrupt, or it's stale (in which case it's proactively cleared
  /// here so a later save isn't confused by leftover data).
  Future<String?> loadFreshActiveDestination() async {
    final box = _box;
    if (box == null) return null;
    final destination = box.get(_destinationKey) as String?;
    final savedAtRaw = box.get(_savedAtKey) as String?;
    if (destination == null || destination.trim().isEmpty || savedAtRaw == null) {
      return null;
    }
    final savedAt = DateTime.tryParse(savedAtRaw);
    if (savedAt == null) {
      await clearActiveSession();
      return null;
    }
    if (DateTime.now().difference(savedAt) > maxSessionAge) {
      await clearActiveSession();
      return null;
    }
    return destination;
  }

  /// Genuinely awaits the close (unlike an earlier version of this
  /// method, which called `_box?.close()` without awaiting it — a real
  /// bug the regression test in
  /// navigation_session_persistence_service_test.dart caught: a
  /// fire-and-forget close left a race where a box reopened
  /// immediately afterward could see a still-closing/closed box).
  /// Callers in this codebase's `State.dispose()` overrides (which
  /// cannot themselves be `async`) call this unawaited — the exact
  /// same accepted pattern already used for
  /// `EmergencyService.dispose()`.
  Future<void> dispose() async {
    await _box?.close();
  }
}
