import 'dart:async';

import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'repositories/gtfs_repository.dart';
import 'services/location_service.dart';
import 'ui/home_screen.dart';
import 'ui/permission_gate_screen.dart';
import 'onboarding/onboarding_screen.dart';
import 'services/user_profile_service.dart';

List<CameraDescription> cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Added for Milestone 2 (User Behaviour Learning): required once,
  // before BehaviourLearningService can open its Hive box.
  await Hive.initFlutter();

  try {
    cameras = await availableCameras();
  } catch (e) {
    print('Error getting cameras: $e');
  }

  // First-launch check: a plain Hive-box read via UserProfileService,
  // done once here (not inside a widget) so the app opens directly
  // into the correct screen rather than flashing a loading spinner at
  // the root. This is the ONLY thing that decides onboarding vs. the
  // existing home screen — everything else about startup (camera
  // enumeration, Hive init) is unchanged.
  final userProfileService = UserProfileService();
  await userProfileService.initialize();
  final showOnboarding = !userProfileService.isOnboardingCompleted;
  await userProfileService.dispose();

  runApp(VaishnaviApp(showOnboarding: showOnboarding));

  // AUDIT FIX (route-search-latency investigation — GTFS-during-
  // onboarding fix): starts GTFS preparation (the bundled feed's
  // one-time import on a fresh install — measured ~574s on a real
  // device for its ~1.36M `stop_times` rows — or a fast no-op once
  // already prepared, see GtfsRepository's own doc comment) as early
  // as possible in the app's lifetime, in the background — NOT
  // awaited here, so it can never delay the first frame or block
  // onboarding/HomeScreen either way. GtfsRepository.instance is the
  // SAME shared instance NavigationScreen and onboarding's
  // preparation-status check both use, so whichever of them reaches
  // it first wins and every later caller (including this one, on a
  // later app launch) just awaits the same memoized result — see
  // GtfsRepository.initialize's doc comment for why that's safe to
  // call unconditionally on every launch, cold or warm.
  unawaited(GtfsRepository.instance.initialize(
    locationService: LocationService(),
    autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
  ).then((_) {
    // PHASE NEXT (safe timetable-loading caching investigation): a real
    // device measurement found the FIRST route search of a session
    // paying ~6.78s just to load today's timetable via SQL — see
    // JourneyPlannerService.prewarmTimetableCache's doc comment. Doing
    // that load here, in the background, while the user is still going
    // through voice onboarding/permissions, means it's very likely
    // already warm by the time they ask for their first route instead
    // of blocking that request. Errors are deliberately swallowed —
    // this is a pure best-effort speed optimization; if it fails,
    // findJourneys() falls back to loading it itself exactly as it
    // already does today, just without the head start.
    return GtfsRepository.instance.prewarmTimetableCache().catchError((e) {
      // ignore: avoid_print
      print('[GTFS-DIAG] prewarmTimetableCache failed (non-fatal, will load lazily instead): $e');
    });
  }));
}

class VaishnaviApp extends StatelessWidget {
  final bool showOnboarding;
  const VaishnaviApp({super.key, required this.showOnboarding});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: "Vaishnavi's Blind Assist",
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.deepPurple,
        useMaterial3: true,
      ),
      // First launch → OnboardingScreen, which hands off to the exact
      // same PermissionGateScreen(child: HomeScreen()) below once it
      // finishes. Every later launch skips straight past it — this is
      // the only branch point; nothing else in the existing startup/
      // navigation architecture changes.
      //
      // Fix 4 (Permission Handling): previously this went straight to
      // HomeScreen after a blind, unchecked permission request in
      // main() — camera/location/microphone denial was never
      // detected, so a denied permission would surface as a runtime
      // crash later inside NavigationScreen instead of a clear
      // message here. PermissionGateScreen checks status, offers
      // retry, and only proceeds to HomeScreen once the required
      // permissions are actually granted.
      home: showOnboarding
          ? const OnboardingScreen()
          : const PermissionGateScreen(child: HomeScreen()),
      debugShowCheckedModeBanner: false,
    );
  }
}
