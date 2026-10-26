import 'package:hive_flutter/hive_flutter.dart';

import '../models/user_profile.dart';

/// Loads, saves, and updates the local [UserProfile], and tracks
/// whether onboarding has ever been completed — the ONLY thing that
/// decides whether `main.dart` shows [OnboardingScreen] or goes
/// straight to [HomeScreen].
///
/// NOT AN AUTHENTICATION SERVICE: there is no account, no password, no
/// server round-trip. This is local personalization storage only, same
/// Hive-box-of-Maps pattern as every other service in this codebase
/// (BehaviourLearningService, EmergencyService, LanguageService) — no
/// code generation, no new persistence mechanism introduced.
class UserProfileService {
  static const String _boxName = 'user_profile_box';
  static const String _profileKey = 'profile';
  static const String _onboardingCompletedKey = 'onboardingCompleted';

  late Box _box;
  bool _initialized = false;
  UserProfile _profile = const UserProfile();

  // AUDIT FIX (same bug class as the live-reproduced
  // BehaviourLearningService crash, Oct 2026): FOUR independent
  // UserProfileService instances exist across this app (main.dart,
  // ProfileSettingsScreen, NavigationScreen, VoiceOnboardingController),
  // all calling `Hive.openBox('user_profile_box')` — Hive caches boxes
  // by name, so they all share the SAME underlying box even though
  // they are separate Dart objects. Previously, any ONE instance's
  // dispose() closing that shared box left every OTHER instance's
  // `_initialized` still true, so its next saveProfile()/
  // completeOnboarding() call would reach `_box.put` on an
  // already-closed box and throw `HiveError: Box has already been
  // closed.` — exactly the bug confirmed on-device in
  // BehaviourLearningService. `_disposed` here only protects THIS
  // instance's own double-dispose; the cross-instance shared-box risk
  // is a deeper architectural issue (multiple owners of one box) worth
  // addressing properly later, not fully solved by this guard alone —
  // but this guard does stop the exact crash this project hit.
  bool _disposed = false;

  bool get isInitialized => _initialized;

  /// Read-only snapshot of the current profile. Never null — defaults
  /// to an all-`unspecified`/all-default [UserProfile] before
  /// onboarding has ever run or before [initialize] completes, so
  /// callers never need a null check just to read, say, the current
  /// language-relevant fields.
  UserProfile get profile => _profile;

  /// True only after [completeOnboarding] has been called at least
  /// once. This — not "does a profile exist" — is the definitive
  /// first-launch signal, since a partially-filled profile from an
  /// abandoned onboarding attempt should not count as "done".
  bool get isOnboardingCompleted =>
      _initialized && !_disposed && (_box.get(_onboardingCompletedKey) as bool? ?? false);

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    final stored = _box.get(_profileKey);
    if (stored != null) {
      _profile = UserProfile.fromMap(Map<dynamic, dynamic>.from(stored as Map));
    }
    _initialized = true;
  }

  /// Persists [profile] as the new current profile. Used both by the
  /// onboarding flow (writing once per step, so nothing is lost if the
  /// user backgrounds the app mid-onboarding) and by the Settings /
  /// Edit Profile screen (writing on every field change).
  Future<void> saveProfile(UserProfile profile) async {
    _profile = profile;
    if (_initialized && !_disposed) {
      await _box.put(_profileKey, profile.toMap());
    }
  }

  /// Marks onboarding as done. Called exactly once, from the Finish
  /// step — never called again by "Edit Profile", which only calls
  /// [saveProfile].
  Future<void> completeOnboarding() async {
    if (_initialized && !_disposed) {
      await _box.put(_onboardingCompletedKey, true);
    }
  }

  Future<void> dispose() async {
    if (_disposed || !_initialized) return;
    _disposed = true;
    await _box.close();
  }
}
