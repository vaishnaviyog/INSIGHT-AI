import 'package:flutter/material.dart';

import '../models/emergency_contact.dart';
import '../models/user_behaviour_profile.dart';
import '../models/user_profile.dart';
import '../onboarding/emergency_setup_page.dart';
import '../onboarding/frequent_place_resolver.dart';
import '../onboarding/language_page.dart';
import '../onboarding/navigation_preferences_page.dart';
import '../onboarding/places_page.dart';
import '../onboarding/profile_page.dart';
import '../services/behaviour_learning_service.dart';
import '../services/emergency_service.dart';
import '../services/language/translation_provider.dart';
import '../services/language_service.dart';
import '../services/location_service.dart';
import '../services/user_profile_service.dart';

/// "Edit Profile" — reachable from Settings, never shown automatically.
/// Reuses every onboarding page widget UNCHANGED (ProfilePage,
/// LanguagePage, NavigationPreferencesPage, EmergencySetupPage,
/// PlacesPage) inside expandable sections, and — per the requirement
/// that "changing preferences should immediately update the relevant
/// services" — every `on...Changed` callback here saves right away
/// rather than batching into one final "Save" step the way onboarding
/// does. This is the only behavioral difference from
/// [OnboardingScreen]; the actual integration logic (syncContacts,
/// resolveFrequentPlaces, seedFromOnboarding) is identical and shared,
/// not reimplemented.
class ProfileSettingsScreen extends StatefulWidget {
  const ProfileSettingsScreen({super.key});

  @override
  State<ProfileSettingsScreen> createState() => _ProfileSettingsScreenState();
}

class _ProfileSettingsScreenState extends State<ProfileSettingsScreen> {
  final UserProfileService _userProfileService = UserProfileService();
  final LanguageService _languageService = LanguageService();
  final EmergencyService _emergencyService = EmergencyService();
  final BehaviourLearningService _behaviourLearningService = BehaviourLearningService();
  final LocationService _locationService = LocationService();

  bool _ready = false;
  bool _isSavingPlaces = false;
  String? _placesError;

  late UserProfile _profile;
  SupportedLanguage _selectedLanguage = SupportedLanguage.english;
  List<EmergencyContact> _contacts = [];
  Map<FrequentPlaceCategory, String> _placeEntries = {};

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _userProfileService.initialize();
    await _languageService.initialize();
    await _emergencyService.initialize();
    await _behaviourLearningService.initialize();

    _profile = _userProfileService.profile;
    _selectedLanguage = _languageService.currentLanguage;
    _contacts = _emergencyService.contacts;
    _placeEntries = {
      for (final place in _profile.frequentPlaces) place.category: place.label,
    };

    if (mounted) setState(() => _ready = true);
  }

  @override
  void dispose() {
    _behaviourLearningService.dispose();
    _emergencyService.dispose();
    _languageService.dispose();
    _userProfileService.dispose();
    super.dispose();
  }

  Future<void> _saveProfile(UserProfile updated) async {
    setState(() => _profile = updated);
    await _userProfileService.saveProfile(updated);
  }

  Future<void> _onWalkingSpeedChanged(WalkingSpeedPreference value) async {
    await _saveProfile(_profile.copyWith(walkingSpeedPreference: value));
    // Safe to call again here: seedFromOnboarding only overwrites
    // averageWalkingSpeed while speedSampleCount == 0, so this can
    // never overwrite genuinely learned data from real navigation —
    // see that method's own doc comment.
    _behaviourLearningService.seedFromOnboarding(
      preferredWalkingSpeedMetersPerSecond: value.metersPerSecond,
    );
  }

  Future<void> _onContactsChanged(List<EmergencyContact> updated) async {
    setState(() => _contacts = updated);
    await _emergencyService.syncContacts(updated);
  }

  Future<void> _onPlaceEntriesChanged(Map<FrequentPlaceCategory, String> updated) async {
    setState(() {
      _placeEntries = updated;
      _isSavingPlaces = true;
      _placesError = null;
    });
    try {
      final resolved = await resolveFrequentPlaces(_locationService, updated);
      _behaviourLearningService.seedFromOnboarding(
        initialFrequentPlaces: resolved
            .map((p) => VisitedLocation(
                  latitude: p.latitude,
                  longitude: p.longitude,
                  visitCount: 3,
                  lastVisited: DateTime.now(),
                ))
            .toList(),
      );
      await _saveProfile(_profile.copyWith(frequentPlaces: resolved));
    } catch (e) {
      // ignore: avoid_print
      print('ProfileSettingsScreen: saving places failed: $e');
      if (mounted) setState(() => _placesError = 'Could not save places right now.');
    } finally {
      if (mounted) setState(() => _isSavingPlaces = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Profile & Preferences')),
      body: ListView(
        children: [
          _Section(
            title: 'Profile',
            icon: Icons.person,
            initiallyExpanded: true,
            child: SizedBox(
              height: 560,
              child: ProfilePage(
                name: _profile.name,
                ageGroup: _profile.ageGroup,
                visionCondition: _profile.visionCondition,
                mobilityAid: _profile.mobilityAid,
                onNameChanged: (v) => _saveProfile(_profile.copyWith(name: v)),
                onAgeGroupChanged: (v) => _saveProfile(_profile.copyWith(ageGroup: v)),
                onVisionConditionChanged: (v) =>
                    _saveProfile(_profile.copyWith(visionCondition: v)),
                onMobilityAidChanged: (v) => _saveProfile(_profile.copyWith(mobilityAid: v)),
              ),
            ),
          ),
          _Section(
            title: 'Language',
            icon: Icons.language,
            child: SizedBox(
              height: 420,
              child: LanguagePage(
                selected: _selectedLanguage,
                onChanged: (v) async {
                  setState(() => _selectedLanguage = v);
                  await _languageService.setLanguage(v);
                },
              ),
            ),
          ),
          _Section(
            title: 'Navigation Preferences',
            icon: Icons.hiking,
            child: SizedBox(
              height: 480,
              child: NavigationPreferencesPage(
                walkingSpeed: _profile.walkingSpeedPreference,
                warningDistance: _profile.warningDistancePreference,
                routePreference: _profile.routePreference,
                onWalkingSpeedChanged: _onWalkingSpeedChanged,
                onWarningDistanceChanged: (v) =>
                    _saveProfile(_profile.copyWith(warningDistancePreference: v)),
                onRoutePreferenceChanged: (v) =>
                    _saveProfile(_profile.copyWith(routePreference: v)),
              ),
            ),
          ),
          _Section(
            title: 'Emergency Contacts',
            icon: Icons.contact_emergency,
            child: SizedBox(
              height: 520,
              child: EmergencySetupPage(
                contacts: _contacts,
                onContactsChanged: _onContactsChanged,
              ),
            ),
          ),
          _Section(
            title: 'Frequent Places',
            icon: Icons.place,
            trailing: _isSavingPlaces
                ? const SizedBox(
                    width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : null,
            child: Column(
              children: [
                if (_placesError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text(_placesError!, style: const TextStyle(color: Colors.redAccent)),
                  ),
                SizedBox(
                  height: 620,
                  child: PlacesPage(
                    entries: _placeEntries,
                    onEntriesChanged: _onPlaceEntriesChanged,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final bool initiallyExpanded;
  final Widget? trailing;

  const _Section({
    required this.title,
    required this.icon,
    required this.child,
    this.initiallyExpanded = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: trailing ?? const Icon(Icons.expand_more),
        initiallyExpanded: initiallyExpanded,
        children: [child],
      ),
    );
  }
}
