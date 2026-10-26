import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import '../config/research_tools_config.dart';
import 'package:flutter/services.dart';
import 'package:camera/camera.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../services/audio_service.dart';
import '../services/hazard_detection_service.dart';
import '../services/behaviour_learning_service.dart';
import '../services/risk_assessment_service.dart';
import '../services/adaptive_guidance_service.dart';
import '../services/emergency_service.dart';
import '../services/emergency/fall_detection_signal_source.dart';
import '../services/language_service.dart';
import '../services/explainable_ai_service.dart';
import '../services/evaluation_service.dart';
import '../models/detected_hazard.dart';
import '../models/risk_assessment.dart';
import '../models/emergency_event.dart';
import '../services/location_service.dart';
import '../services/navigation_session_persistence_service.dart';
import '../services/scene_description_service.dart';
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'package:flutter_compass/flutter_compass.dart';
import 'home_screen.dart';
import 'emergency_contacts_screen.dart';
import 'research/research_menu_screen.dart';
import 'debug_dashboard_screen.dart';
import 'hazard_box_painter.dart';
import '../services/metrics/navigation_metrics_tracker.dart';
import '../services/metrics/runtime_metrics_collector.dart';
import '../services/metrics/metrics_report_service.dart';
import '../services/intent_inference_service.dart';
import '../models/navigation_intent.dart';
import '../services/safe_route_service.dart';
import '../services/user_profile_service.dart';
import '../models/user_profile.dart';
import '../repositories/gtfs_repository.dart';
import '../models/journey/journey.dart';
import '../services/journey/journey_walking_enrichment.dart';
import '../models/voice_understanding/destination_resolution.dart';
import '../services/voice_understanding/voice_understanding_layer.dart';
import '../services/voice_understanding/voice_confirmation.dart';
import '../services/async/delayed_progress_announcement.dart';
import '../services/gtfs/gtfs_locality_resolver.dart';
import '../models/gtfs/stop.dart';
import '../models/adaptive_risk/adaptive_risk_input.dart';
import '../models/adaptive_risk/navigation_decision.dart';
import '../services/adaptive_risk/adaptive_risk_engine.dart';
import '../services/adaptive_risk/warning_prioritizer.dart';
import '../services/adaptive_risk/navigation_decision_engine.dart';
import 'journey/journey_options_sheet.dart';
import 'journey/transit_journey_guide_screen.dart';

/// Supplied at build/run time via `--dart-define=GEMINI_API_KEY=...` —
/// never hardcoded in source. Empty string if not provided (e.g. a
/// debug build run without the flag); `SceneDescriptionService`
/// itself is unchanged and will simply receive an empty key in that
/// case, causing Gemini requests to fail (visible in
/// `describeScene`'s existing error handling) rather than silently
/// using a real, committed secret.
///
/// Run/build with, for example:
///   flutter run --dart-define=GEMINI_API_KEY=your_key_here
const String geminiApiKey = String.fromEnvironment('GEMINI_API_KEY');

class NavigationScreen extends StatefulWidget {
  final String destination;
  final CameraDescription camera;
  final bool enableObjectDetection;

  /// AUDIT ADD (CRITICAL background state persistence fix): true only
  /// when [HomeScreen] is reconstructing this screen from a saved
  /// session after a cold start (see
  /// NavigationSessionPersistenceService's doc comment for why that
  /// can happen after just ~20-30s backgrounded on this device's
  /// OEM Android build) — NEVER true for a normal fresh voice
  /// destination. Does not change what is fetched (the exact same
  /// [_fetchRoute] real GPS+route search a fresh destination uses,
  /// so nothing stale from before the gap is ever assumed valid) —
  /// only adds the "Restoring your previous navigation."/"could not
  /// be restored" spoken messages a blind user needs to know what's
  /// happening, per this fix's explicit safety requirement.
  final bool isRestoredSession;

  const NavigationScreen({
    super.key,
    required this.destination,
    required this.camera,
    this.enableObjectDetection = true,
    this.isRestoredSession = false,
  });

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late CameraController _cameraController;

  /// AUDIT ADD (real-device validation phase — crash investigation):
  /// `_cameraController` is `late` and assigned only partway through
  /// `_initializeEverything()`'s async chain (several `await`s deep),
  /// but `_buildCameraFeedWidget()` — which touches it — is also handed
  /// to `TransitJourneyGuideScreen` as a callback (`buildCameraPreview`)
  /// that screen invokes from ITS OWN `build()`. If that screen builds
  /// before `_cameraController`'s assignment (or during the
  /// dispose-then-reacquire window in `_releaseCameraForExternalScreen`/
  /// `_reacquireCameraAfterExternalScreen`), touching the late field at
  /// all throws `LateInitializationError` — reproduced live, on a real
  /// device, as a full-screen crash. This flag is the ONLY thing
  /// `_buildCameraFeedWidget()` checks before touching the field at
  /// all, so `&&`'s short-circuit guarantees the field is never touched
  /// while this is false.
  bool _cameraControllerReady = false;
  final HazardDetectionService _hazardDetectionService =
      HazardDetectionService();
  final BehaviourLearningService _behaviourLearningService =
      BehaviourLearningService();

  /// AUDIT ADD (Fix 4 — next-destination stale context): the
  /// destination text ACTUALLY IN EFFECT for the current/most recent
  /// `_fetchRoute()` call — `widget.destination` alone is only ever
  /// the ORIGINAL destination this screen was constructed with, and
  /// stays wrong for the rest of the session once a transit
  /// "where would you like to go now?" prompt resolves a NEW one (see
  /// `_fetchRoute`'s `overrideDestinationText` parameter). Every
  /// destination-dependent operation in this class — resolution,
  /// intent inference, session logging, UI display text — reads THIS
  /// field, never `widget.destination` directly, so a new destination
  /// takes effect everywhere consistently rather than in just the
  /// one place it was first threaded through.
  late String _effectiveDestinationText;

  /// Stateless — see RiskAssessmentService's own doc comment for why
  /// it takes no constructor arguments and holds no service refs.
  final RiskAssessmentService _riskAssessmentService = RiskAssessmentService();

  // Phase 1 (INSIGHT Adaptive Risk Intelligence Engine) — extends,
  // does not replace, RiskAssessmentService/AdaptiveGuidanceService
  // above. See adaptive_risk_engine.dart's doc comment for exactly
  // how these compose with the existing engine.
  final AdaptiveRiskEngine _adaptiveRiskEngine = AdaptiveRiskEngine();
  final WarningPrioritizer _warningPrioritizer = WarningPrioritizer();
  final NavigationDecisionEngine _navigationDecisionEngine = NavigationDecisionEngine();

  /// Stateless — see AdaptiveGuidanceService's own doc comment. Does
  /// not touch AudioService in any way; only decides what/when to
  /// tell it to speak.
  final AdaptiveGuidanceService _adaptiveGuidanceService =
      AdaptiveGuidanceService();

  /// Milestone 5: manages contacts, SOS countdown, and event logging.
  /// Stateful (unlike Risk/AdaptiveGuidance) because a countdown timer
  /// and persisted contacts/events genuinely need to persist across
  /// frames — see EmergencyService's own doc comment.
  final EmergencyService _emergencyService = EmergencyService();

  /// REAL accelerometer-based fall detector, registered with
  /// [_emergencyService] the same way any future
  /// IEmergencySignalSource would be — see its own doc comment for
  /// the detection algorithm and known limitations.
  final FallDetectionSignalSource _fallDetectionSignalSource =
      FallDetectionSignalSource();

  /// Milestone 6: defaults to English, which is behavior-preserving
  /// by construction (see LanguageService's doc comment).
  final LanguageService _languageService = LanguageService();

  /// Phase 1 (Evaluation Framework, research-only). Never read by any
  /// navigation/UI decision — only written to and exported.
  final EvaluationService _evaluationService = EvaluationService();

  /// Phase 3 (Explainable AI Engine). Stateless — takes exactly
  /// hazard/risk/behaviour/environment, holds no other references.
  final ExplainableAIService _explainableAIService = ExplainableAIService();

  /// Most recent explanation, kept only so the AI Learning Dashboard
  /// (Phase 2) has something real to display. Not used in any
  /// navigation/speech decision.
  ExplanationResult? _lastExplanation;

  /// Milestone 3: read-only, for logging + the debug dashboard only.
  /// Does not affect any spoken warning or navigation decision — that
  /// integration is Milestone 4's responsibility.
  RiskAssessment? _lastRiskAssessment;

  /// Milestone 1/1.5: tracks the most recent detection purely for the
  /// developer debug dashboard's "current detected hazard" display
  /// (and now also as an input to Milestone 3's risk assessment
  /// logging). Not read by any existing feature — the actual
  /// obstacle-warning logic has its own local `topHazard` variable.
  DetectedHazard? _lastHazard;

  /// Milestone requirement: drives `HazardBoxPainter`'s bounding-box
  /// overlay. Deliberately fed from `HazardDetectionService.lastRawDetections`
  /// (every real-time detection), NOT from the temporally-confirmed
  /// list used for voice/risk/evaluation below — so the visual overlay
  /// (a sighted-developer/demo aid) shows detection activity
  /// immediately, while spoken warnings still wait for 3-frame
  /// confirmation. See HazardDetectionService's own doc comment.
  List<DetectedHazard> _currentFrameHazards = [];
  final AudioService _audioService = AudioService();
  final LocationService _locationService = LocationService();

  /// AUDIT ADD (CRITICAL background state persistence fix) — see
  /// NavigationSessionPersistenceService's doc comment. Set true only
  /// at the two real "a route was actually found" points inside
  /// [_fetchRoute] (never on a bare confirmed destination that hasn't
  /// resolved to a route yet), reset false at the top of every
  /// [_fetchRoute] call — the caller reads it right after `await
  /// _fetchRoute()` to know whether to speak the restoration-failure
  /// message when `widget.isRestoredSession` is true.
  final NavigationSessionPersistenceService _sessionPersistenceService =
      NavigationSessionPersistenceService();
  bool _lastFetchRouteSucceeded = false;

  // Stage 2B (Public Transport Journey Planning) — reuses
  // GtfsRepository/GtfsQueryService/GtfsLocationService exactly as
  // built in Stage 2A, nothing duplicated. Initialized lazily, on the
  // first destination resolution (see _offerTransitJourneys), not
  // eagerly in initState — this app can be opened without a pending
  // GTFS query ever being needed, and initialize() also auto-imports
  // the bundled feed on first-ever use (see
  // GtfsRepository.initialize's autoImportAssetPathIfEmpty param).
  //
  // AUDIT FIX (route-search-latency investigation — P0 device report):
  // uses the APP-LIFETIME shared instance, not a fresh
  // `GtfsRepository()`, specifically so that first-ever import (a
  // measured ~574s on a real device for the bundled feed's ~1.36M
  // `stop_times` rows) and the warm in-memory RAPTOR timetable cache
  // both survive this SCREEN being recreated (e.g. leaving and
  // re-entering navigation) — see GtfsRepository's own doc comment.
  // `initialize()` is now safe to call unconditionally/repeatedly (see
  // its memoization doc comment), so the old `_gtfsInitialized` guard
  // flag this screen used to track for itself is gone — the
  // repository tracks that for real now, correctly, across every
  // caller and every screen instance, not just this one.
  final GtfsRepository _gtfsRepository = GtfsRepository.instance;

  // AUDIT ADD (destination-resolution correctness phase): see
  // GtfsLocalityResolver's own doc comment — wraps _gtfsRepository
  // with the substring/fuzzy-index stop-matching logic that used to
  // live inline in this class, plus the new city-qualifier-stripping
  // fix.
  late final GtfsLocalityResolver _gtfsLocalityResolver = GtfsLocalityResolver(_gtfsRepository);

  // Phase 1 (Voice Understanding Layer) — see
  // voice_understanding_layer.dart. Stateless/cheap; no init/dispose
  // needed.
  final VoiceUnderstandingLayer _voiceUnderstandingLayer = VoiceUnderstandingLayer();
  double? _lastDestinationConfidence;
  final SceneDescriptionService _sceneDescriptionService =
      SceneDescriptionService(geminiApiKey);
  final MapController _mapController = MapController();

  /// Evaluation-metrics-only: persists one record per navigation
  /// session (success, duration, deviations, completion %). Never
  /// read by any navigation/speech/routing decision — see its own
  /// doc comment for the exact scope boundary.
  final NavigationMetricsTracker _navigationMetricsTracker =
      NavigationMetricsTracker();

  /// Feature 3 (Contextual Intent Inference): stateless, mirrors
  /// RiskAssessmentService/AdaptiveGuidanceService's own pattern.
  final IntentInferenceService _intentInferenceService =
      IntentInferenceService();
  NavigationIntent _currentIntent = NavigationIntent.unknown;

  /// Feature 2 (Safe Path Optimization): stateless route scorer,
  /// reuses RouteSafetyService/EvaluationService/BehaviourLearningService
  /// data rather than tracking anything of its own.
  final SafeRouteService _safeRouteService = SafeRouteService();

  /// Onboarding integration: read-only here — this screen never
  /// writes to it (all writes happen in OnboardingScreen /
  /// ProfileSettingsScreen). Supplies warningDistancePreference to
  /// AdaptiveGuidanceService, routePreference to SafeRouteService, and
  /// visionCondition to gate the on-screen obstacle-text overlay.
  final UserProfileService _userProfileService = UserProfileService();

  List<RouteStep> _routeSteps = [];
  List<LatLng> _routePoints = [];
  LatLng? _startPoint;
  LatLng? _endPoint;

  int _currentStepIndex = 0;
  String _statusText = "Getting your location.";
  String _obstacleText = "";

  /// Fix 3 (Per-Hazard Warning Debounce): previously a single
  /// DateTime shared across every hazard type, which meant a warning
  /// about one hazard could suppress a warning about a genuinely
  /// different, newly-appeared hazard for up to the debounce
  /// interval. Keyed by hazard label so each hazard type has its own
  /// independent timer. See _timeSinceLastWarningFor() and
  /// _mostRecentWarningTime below for how this is read.
  final Map<String, DateTime> _lastWarningTimeByHazard = {};

  /// Convenience accessor: most recent warning across ANY hazard type
  /// — used only for the UI obstacle-text clearing grace period
  /// (line ~342 originally), which was never meant to be hazard-
  /// specific in the first place; it just needs "was anything spoken
  /// recently".
  DateTime get _mostRecentWarningTime => _lastWarningTimeByHazard.values.isEmpty
      ? DateTime.now().subtract(const Duration(days: 1))
      : _lastWarningTimeByHazard.values.reduce((a, b) => a.isAfter(b) ? a : b);
  DateTime _lastNavigationInstructionTime = DateTime.now().subtract(
    const Duration(seconds: 10),
  );
  StreamSubscription<Position>? _positionStream;

  bool _hasOffRoadStart = false;
  double _lastSpokenDistanceToRoad = 0.0;
  StreamSubscription<CompassEvent>? _compassSubscription;
  double? _currentCompassHeading;
  String _lastSpokenRelativeDirection = "";
  Position? _lastPosition;
  bool _isDescribingScene = false;
  String _savedStatusText = "";
  late AnimationController _scannerAnimationController;
  late bool _enableObjectDetection;

  /// Fix 1 (Camera Processing Race Condition): the camera plugin
  /// invokes _processCameraImage() as a fire-and-forget callback per
  /// frame — it does NOT wait for the previous call's async chain to
  /// finish. Without this guard, overlapping invocations could both
  /// pass the warning-debounce check before either updates the
  /// debounce timestamp (see Fix 3), and could both call into speech
  /// concurrently. Reset in a finally block (see _processCameraImage)
  /// so a thrown exception can never leave frame processing
  /// permanently stuck.
  bool _isProcessingFrame = false;

  /// AUDIT ADD (Phase E4 — camera/interpreter lifecycle safety): set
  /// TRUE as the very first line of [dispose] (synchronous — a
  /// `StatefulWidget.dispose()` cannot be `async`, so this cannot
  /// literally await `stopImageStream()` finishing before tearing
  /// resources down). Checked as the very first line of
  /// [_processCameraImage] — a frame callback that fires after
  /// `dispose()` has begun (a real possibility: the `camera` plugin's
  /// native teardown is not necessarily instantaneous with the Dart
  /// `dispose()` call returning) now bails out immediately instead of
  /// calling into `_hazardDetectionService`/`_cameraController` while
  /// they may already be torn down. Previously the only protection was
  /// incidental: `YoloTfliteHazardDetector.dispose()` sets its own
  /// `_isAvailable = false` before closing the interpreter, and
  /// `detect()` checks that flag — this adds an EXPLICIT guard at the
  /// call site itself rather than relying on that as the only line of
  /// defense.
  bool _isDisposed = false;

  /// Feature 1 (Real Emergency SOS): voice feedback during the
  /// countdown. Subscribes to EmergencyService's tick stream rather
  /// than EmergencyService calling AudioService directly, keeping the
  /// same separation this codebase already uses everywhere else.
  StreamSubscription<int>? _sosCountdownTickSubscription;
  StreamSubscription<EmergencyEventStatus>? _sosOutcomeSubscription;

  @override
  void initState() {
    super.initState();
    // AUDIT ADD (Phase E5 — app lifecycle handling): registers this
    // State to receive didChangeAppLifecycleState callbacks — see that
    // method's doc comment for what was missing before this.
    WidgetsBinding.instance.addObserver(this);
    _effectiveDestinationText = widget.destination;
    _enableObjectDetection = widget.enableObjectDetection;
    _scannerAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    // AUDIT FIX (Phase E10 — failure-handling audit): previously
    // fire-and-forget with no error handling at all — _initializeEverything
    // awaits ~9 sequential service-initialize() calls (Hive-backed
    // BehaviourLearningService/UserProfileService/EvaluationService,
    // camera controller init, TFLite interpreter init, ...). If ANY of
    // them threw (a corrupted Hive box on disk is a real, not
    // theoretical, failure mode), the whole chain aborted silently —
    // an unhandled Future rejection swallowed by Dart's zone handler —
    // leaving a blind user on a screen with no camera, no audio ready,
    // and no spoken indication anything went wrong at all. This
    // doesn't fix the underlying failure (there's no safe way to
    // "recover" a corrupted Hive box from here), but it ensures the
    // user is TOLD, via whichever of speech/status-text is still
    // reachable, rather than left in silence.
    _initializeEverything().catchError((Object e, StackTrace st) {
      // ignore: avoid_print
      print('NavigationScreen._initializeEverything failed: $e\n$st');
      if (mounted) {
        setState(() => _statusText = 'Something went wrong while starting navigation.');
      }
      // Best-effort — AudioService initializes its own TTS engine
      // independently of everything else in _initializeEverything, so
      // this can still succeed even when an earlier step (e.g. Hive)
      // failed. If TTS itself is what failed, this call fails too and
      // is swallowed here deliberately — there is no remaining channel
      // left to tell the user anything through.
      _languageService.speak(_audioService, 'Something went wrong while starting navigation. Please restart the app.').catchError((Object _) {});
    });
  }

  /// AUDIT ADD (Phase E5 — app lifecycle handling): previously this
  /// screen had NO `AppLifecycleState` handling at all (confirmed
  /// absent during the read-only audit — zero matches for
  /// `WidgetsBindingObserver` anywhere in the app) — the camera stream
  /// and GPS position stream kept running indefinitely while the app
  /// was backgrounded (screen off, another app in front), a real
  /// battery drain and privacy exposure (camera active while the phone
  /// is in a pocket) with nothing else in the app pausing them either.
  ///
  /// Deliberately only reacts to `paused` (fully backgrounded) and
  /// `resumed`, not `inactive` — `inactive` fires for brief, normal
  /// transitions (a system permission dialog, the app-switcher
  /// preview) even while the app stays effectively foregrounded;
  /// treating it the same as `paused` would cause needless camera/GPS
  /// stop-start churn on every such transition, including this
  /// screen's own permission/confirmation dialogs.
  ///
  /// Remembers whether detection/GPS were ACTUALLY active before
  /// pausing so `resumed` only restarts what was genuinely running —
  /// e.g. camera detection that was already off because the rider is
  /// mid-transit (see `TransitSessionStateMachine`'s camera contract)
  /// must stay off after a resume, not be silently turned back on.
  bool _isAppBackgrounded = false;
  bool _detectionWasActiveBeforeBackground = false;
  bool _gpsLoopWasActiveBeforeBackground = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _handleAppBackgrounded();
    } else if (state == AppLifecycleState.resumed) {
      _handleAppForegrounded();
    }
  }

  void _handleAppBackgrounded() {
    if (_isDisposed || _isAppBackgrounded) return;
    _isAppBackgrounded = true;
    _detectionWasActiveBeforeBackground =
        _cameraController.value.isInitialized && _cameraController.value.isStreamingImages;
    _gpsLoopWasActiveBeforeBackground = _positionStream != null;

    if (_detectionWasActiveBeforeBackground) {
      _stopDetectionCamera();
    }
    _positionStream?.cancel();
    _positionStream = null;
    // AUDIT FIX (real-device validation phase) — see
    // _startCompassSubscription's doc comment for the on-device evidence
    // (a burst of "DeviceOrientationManager: Cannot get display"
    // warnings) that this stream was the one this method's own doc
    // comment already flagged camera/GPS as needing, but compass was
    // missed.
    _compassSubscription?.cancel();
    _compassSubscription = null;
  }

  void _handleAppForegrounded() {
    if (_isDisposed || !_isAppBackgrounded) return;
    _isAppBackgrounded = false;

    if (_detectionWasActiveBeforeBackground) {
      _startDetectionCamera();
    }
    if (_gpsLoopWasActiveBeforeBackground) {
      // Restarting the stream (rather than reusing any previously
      // cached position) guarantees a FRESH fix is acquired on
      // resume — this never assumes GPS data from before the
      // backgrounding period is still valid, regardless of how long
      // the app was away.
      _startNavigationLoop();
    }
    _startCompassSubscription();
  }

  Future<void> _initializeEverything() async {
    await _hazardDetectionService.initialize();
    await _behaviourLearningService.initialize();
    await _userProfileService.initialize();
    await _emergencyService.initialize();
    await _sessionPersistenceService.initialize();
    _sosCountdownTickSubscription = _emergencyService.countdownTicks.listen((
      secondsRemaining,
    ) {
      // Voice feedback during the countdown (Feature 1 requirement).
      // Only the last 5 seconds are announced individually — the
      // countdown's start is already announced once by the existing
      // "S O S will be sent in N seconds..." message at the button
      // press, so repeating every second for the full 10-second
      // window would be noisy rather than helpful.
      if (secondsRemaining <= 5 && secondsRemaining > 0) {
        _audioService.speak(secondsRemaining.toString());
      }
    });

    // AUDIT FIX (real-device validation phase — emergency-system
    // honesty check): before this fix, the countdown was the ONLY
    // spoken feedback for an SOS — a blind user heard "S O S will be
    // sent in N seconds," then nothing, with no way to know whether the
    // message actually reached the SMS app afterward. Deliberately
    // does NOT say "sent" or "delivered" for the success case — per
    // EmergencyEventStatus's own doc comment, only the native SMS app
    // opening is confirmed here, not transmission or delivery, and on
    // many Android builds the user still needs to tap "send" in that
    // app themselves.
    _sosOutcomeSubscription = _emergencyService.sosOutcomes.listen((status) {
      final message = status == EmergencyEventStatus.sent
          ? "Your emergency message has been opened in the messaging app. Please check it sent, or call for help directly."
          : "Could not open the messaging app for your emergency message. Please call for help directly.";
      _languageService.speak(_audioService, message);
    });

    // Real (not architecture-only) hardware-triggered SOS: registers
    // the accelerometer-based fall detector through the exact same
    // addSignalSource path any future IoT source would use. Location
    // is supplied lazily via the callback so a fall-triggered SOS
    // carries a GPS fix, same as the manual button already does.
    _emergencyService.addSignalSource(
      _fallDetectionSignalSource,
      currentLocation: () => (
        latitude: _lastPosition?.latitude,
        longitude: _lastPosition?.longitude,
      ),
    );
    _fallDetectionSignalSource.startListening();

    await _languageService.initialize();
    await _evaluationService.initialize();
    await _navigationMetricsTracker.initialize();

    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid
          // AUDIT FIX (P0-2): was ImageFormatGroup.nv21, but
          // YoloTfliteHazardDetector's converter unconditionally used
          // a 3-plane YUV_420_888-style decode on Android regardless
          // of which format was actually requested — a real
          // format/byte-layout mismatch (and, since nv21 is often
          // delivered on a DIFFERENT plane count than 3, a potential
          // out-of-range crash on `image.planes[2]`, not merely
          // inaccurate colors). `yuv420` is both the more broadly
          // supported option across `camera` plugin versions AND the
          // format the existing 3-plane converter's generic
          // per-plane-stride logic was actually written for. The
          // converter is now also defensive: it branches on
          // `image.format.group` and handles nv21/bgra8888 correctly
          // too, in case format negotiation ever returns something
          // other than what was requested — see
          // YoloTfliteHazardDetector._convertCameraImageToRgb.
          ? ImageFormatGroup.yuv420
          : ImageFormatGroup.bgra8888,
    );
    await _cameraController.initialize();
    _cameraControllerReady = true;

    await _startDetectionCamera();

    if (mounted) setState(() {});

    _startCompassSubscription();

    // AUDIT ADD (CRITICAL background state persistence fix): explicit
    // spoken indication before/after restoring a session from a saved
    // destination — see NavigationSessionPersistenceService's doc
    // comment. `_fetchRoute()` itself is completely unchanged below —
    // this reuses the EXACT same real GPS+route search a fresh voice
    // destination goes through, so a restored session is always
    // freshly (re)computed, never assumed valid from before the gap.
    if (widget.isRestoredSession) {
      await _languageService.speak(_audioService, "Restoring your previous navigation.");
    }

    await _fetchRoute();

    if (widget.isRestoredSession && !_lastFetchRouteSucceeded) {
      await _languageService.speak(_audioService, "Your previous navigation could not be restored.");
      await _sessionPersistenceService.clearActiveSession();
    }

    _startNavigationLoop();
  }

  /// AUDIT FIX (real-device validation phase — measured bottleneck):
  /// factored out of the inline `_initializeEverything()` compass setup
  /// so [_handleAppForegrounded] can restart it after
  /// [_handleAppBackgrounded] cancels it. Before this fix, this was the
  /// ONE stream `didChangeAppLifecycleState`'s doc comment's own
  /// reasoning (camera + GPS "kept running indefinitely while the app
  /// was backgrounded" before that fix) did NOT cover — the compass
  /// subscription was only ever cancelled in `dispose()`, never on a
  /// mere backgrounding. Confirmed live on-device (OPPO CPH2421):
  /// backgrounding this screen produced a burst of dozens-per-second
  /// "DeviceOrientationManager: Cannot get display: Activity may be
  /// null" warnings for several seconds — the native compass listener
  /// still firing and repeatedly failing to resolve the (now backgrounded)
  /// Activity's Display, before Android's own sensor teardown eventually
  /// caught up. Self-resolving, not a permanent leak, but real wasted
  /// CPU/battery during every background transition — the same category
  /// of bug the camera/GPS pause logic already exists to prevent.
  void _startCompassSubscription() {
    _compassSubscription = FlutterCompass.events?.listen((
      CompassEvent event,
    ) async {
      if (!mounted) return;
      final heading = event.heading;
      if (heading == null) return;

      _currentCompassHeading = heading;

      if (_currentStepIndex == 1 &&
          _lastPosition != null &&
          _routeSteps.isNotEmpty) {
        LatLng currentLoc = LatLng(
          _lastPosition!.latitude,
          _lastPosition!.longitude,
        );

        LatLng targetPoint = _routeSteps[_currentStepIndex].location;
        if (!_hasOffRoadStart) {
          if (_routePoints.length > 1) {
            for (int i = 0; i < _routePoints.length; i++) {
              if (const Distance().as(
                    LengthUnit.Meter,
                    currentLoc,
                    _routePoints[i],
                  ) >
                  10.0) {
                targetPoint = _routePoints[i];
                break;
              }
            }
          }
        }

        double distanceToNext = const Distance().as(
          LengthUnit.Meter,
          currentLoc,
          targetPoint,
        );

        if (distanceToNext > 5.0) {
          final bearing = Geolocator.bearingBetween(
            _lastPosition!.latitude,
            _lastPosition!.longitude,
            targetPoint.latitude,
            targetPoint.longitude,
          );

          double relativeAngle = (bearing - heading + 360) % 360;
          String relativeDirection;
          if (relativeAngle >= 315 || relativeAngle < 45) {
            relativeDirection = "straight ahead";
          } else if (relativeAngle >= 45 && relativeAngle < 135) {
            relativeDirection = "to your right";
          } else if (relativeAngle >= 135 && relativeAngle < 225) {
            relativeDirection = "behind you";
          } else {
            relativeDirection = "to your left";
          }

          if (relativeDirection != _lastSpokenRelativeDirection) {
            final now = DateTime.now();
            if (now.difference(_lastNavigationInstructionTime).inSeconds > 4 &&
                !_isDescribingScene) {
              _lastNavigationInstructionTime = now;
              _lastSpokenRelativeDirection = relativeDirection;

              String progressMsg;
              if (_hasOffRoadStart) {
                progressMsg =
                    "The road is $relativeDirection, ${distanceToNext.round()} meters away.";
                _navigationMetricsTracker.recordDeviation();
              } else {
                progressMsg = "The route is now $relativeDirection.";
              }
              setState(() {
                _statusText = progressMsg;
              });
              await _languageService.speak(_audioService, progressMsg);
            }
          }
        }
      }
    });
  }

  /// AUDIT ADD (transit state machine production integration):
  /// factored out of the inline `initState()` camera-setup block so
  /// this exact same "start streaming frames through the detection
  /// pipeline" behavior can be re-triggered later — specifically by
  /// `TransitSessionStateMachine`'s `CameraDetectionCommand.startDetection`
  /// (via the `onStartDetectionCamera` callback passed to
  /// `TransitJourneyGuideScreen`) when a transit leg's rider alights
  /// and final walking resumes. Guards against double-starting an
  /// already-streaming controller — the SAME defensive check already
  /// used elsewhere in this file (see the scene-description
  /// pause/resume code) for exactly this reason.
  Future<void> _startDetectionCamera() async {
    if (!_cameraController.value.isInitialized) return;
    if (_cameraController.value.isStreamingImages) return;
    await _cameraController.startImageStream((CameraImage image) async {
      RuntimeMetricsCollector.instance.recordCameraFrame();
      // PHASE C4 TEMPORARY DIAGNOSTIC (fresh device latency/dropped-
      // frame measurement — additive only, no processing/decision logic
      // changed): every raw frame the camera plugin delivers, BEFORE
      // any re-entrancy/throttle guard — the baseline to compare
      // T0_frameCaptured (passed _isProcessingFrame),
      // DROPPED_BUSY/DROPPED_THROTTLE (HazardDetectionService's own
      // guards), and T6_pipelineComplete counts against.
      logLatency('RAW_FRAME=${DateTime.now().toIso8601String()}');
      _processCameraImage(image);
    });
  }

  /// The other half of [_startDetectionCamera] — stops camera image
  /// streaming AND therefore YOLO inference (there is no frame flow
  /// without `startImageStream`'s callback firing), not merely a UI
  /// visibility change. Triggered by
  /// `CameraDetectionCommand.stopDetection` when a transit leg's rider
  /// boards (via `onStopDetectionCamera`).
  Future<void> _stopDetectionCamera() async {
    if (!_cameraController.value.isInitialized) return;
    if (!_cameraController.value.isStreamingImages) return;
    await _cameraController.stopImageStream();
  }

  /// PHASE C4 (YOLO accuracy + latency investigation) — AUDIT FIX for a
  /// real, reproduced-on-device bug: `ModelBenchmarkScreen` (reachable
  /// via the Research Menu FAB below, pushed ON TOP of this screen —
  /// this screen stays mounted underneath, per normal `Navigator.push`
  /// semantics) opens its OWN separate `CameraController` on the SAME
  /// physical camera this screen's `_cameraController` already holds
  /// open. Android only allows one client to hold a Camera2 device at a
  /// time — the two controllers fighting over the same hardware froze
  /// the whole app (a genuine white/blank-screen hang, confirmed live).
  ///
  /// `_stopDetectionCamera` above is NOT sufficient here — it only
  /// stops the image STREAM; the `CameraController` itself stays open
  /// and still holds the hardware. This fully DISPOSES the controller
  /// (actually releasing the camera device) before a screen that needs
  /// its own gets pushed, and [_reacquireCameraAfterExternalScreen]
  /// recreates + reinitializes it on return — same camera config
  /// `initState` uses, so the live preview/detection resume exactly as
  /// they were.
  bool _detectionWasActiveBeforeExternalCameraUse = false;

  Future<void> _releaseCameraForExternalScreen() async {
    if (_isDisposed) return;
    // Must flip BEFORE dispose() below — `_buildCameraFeedWidget()`
    // (reachable via the `buildCameraPreview` callback handed to a
    // pushed screen) must never touch `_cameraController` once it's
    // been disposed, not just before it's first assigned.
    _cameraControllerReady = false;
    _detectionWasActiveBeforeExternalCameraUse =
        _cameraController.value.isInitialized && _cameraController.value.isStreamingImages;
    if (_cameraController.value.isInitialized) {
      if (_cameraController.value.isStreamingImages) {
        await _cameraController.stopImageStream().catchError((Object e) {
          // ignore: avoid_print
          print('NavigationScreen._releaseCameraForExternalScreen: stopImageStream failed (non-fatal): $e');
        });
      }
      await _cameraController.dispose();
    }
  }

  Future<void> _reacquireCameraAfterExternalScreen() async {
    if (_isDisposed || !mounted) return;
    _cameraController = CameraController(
      widget.camera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
    );
    await _cameraController.initialize();
    _cameraControllerReady = true;
    if (_isDisposed || !mounted) return;
    if (_detectionWasActiveBeforeExternalCameraUse) {
      await _startDetectionCamera();
    }
    if (mounted) setState(() {});
  }

  /// AUDIT ADD (Phase NEXT — camera visibility): the live preview +
  /// hazard-box overlay, extracted out of `build()` so it can also be
  /// handed to `TransitJourneyGuideScreen` via a builder callback (see
  /// that constructor's `buildCameraPreview` doc comment) — ONE
  /// definition of how this is rendered, reused by both screens
  /// against the SAME `_cameraController`/`_currentFrameHazards`,
  /// rather than a second, potentially-drifting copy.
  Widget _buildCameraFeedWidget() {
    // `_cameraControllerReady` MUST be checked first — `&&` short-
    // circuits, so `_cameraController` (a `late` field) is never
    // touched at all while this is false. See that field's doc comment
    // for the real crash this guards against.
    if (!_cameraControllerReady || !_cameraController.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: AspectRatio(
        // `_cameraController.value.aspectRatio` is width/height in the
        // camera's NATIVE (landscape) sensor orientation. This app
        // runs in portrait, so the widget box needs the RECIPROCAL to
        // be the correct portrait shape — otherwise the preview is
        // displayed in a wrong-shaped box and, critically,
        // HazardBoxPainter's fractional (0..1) boxes are scaled
        // against that same wrong shape, so they land in the wrong
        // place relative to the actual detected objects. Stacking
        // CameraPreview and the painter inside this SAME AspectRatio
        // is what keeps them in the same coordinate space.
        aspectRatio: 1 / _cameraController.value.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(_cameraController),
            CustomPaint(
              painter: HazardBoxPainter(_currentFrameHazards),
            ),
          ],
        ),
      ),
    );
  }

  /// Consumes `TransitEvent.resetDetectionState` — clears
  /// `HazardTemporalFilter`/`CollisionTimeEstimator` state via
  /// `HazardDetectionService`'s existing `resetTemporalState()` (not a
  /// new method; that already existed) so no stale hazard/TTC history
  /// from before boarding leaks into fresh detection once final
  /// walking resumes.
  void _resetDetectionState() {
    _hazardDetectionService.resetTemporalState();
  }

  void _processCameraImage(CameraImage image) async {
    // AUDIT ADD (Phase E4 — camera/interpreter lifecycle safety): must
    // be the FIRST check, before even `_enableObjectDetection` — see
    // `_isDisposed`'s own doc comment.
    if (_isDisposed) return;
    if (!_enableObjectDetection) return;

    // Fix 1 (Camera Processing Race Condition): the camera plugin
    // calls this per frame without waiting for the previous call to
    // finish. This guard ensures only one frame is actively being
    // processed at a time. THREAD-SAFETY NOTE: Dart is single-
    // threaded per isolate — there is no true parallel execution here,
    // but `await` points inside this function yield control back to
    // the event loop, and the camera plugin can invoke this callback
    // again during that yield. Checking-and-setting `_isProcessingFrame`
    // happens synchronously (no `await` between the check and the
    // set), so a second invocation arriving during an `await` further
    // down will see the flag already `true` and return immediately —
    // there is no window where two invocations can both pass the
    // check. The `finally` block guarantees the flag is always
    // cleared, including if any awaited call throws, so a single
    // exception can never permanently stall frame processing (frame
    // starvation). This does not reduce detection accuracy: frames
    // that arrive while one is already being processed are simply
    // skipped for hazard detection, identical to how
    // HazardDetectionService's own internal throttle already behaves
    // — this guard adds the same protection to the rest of the
    // pipeline (risk assessment, evaluation logging, speech) that
    // detection alone already had.
    if (_isProcessingFrame) return;
    _isProcessingFrame = true;
    // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T0 =
    // camera frame captured (approximated as "frame accepted for
    // processing," the earliest point this screen's own code sees
    // it — the camera plugin does not expose a frame-capture
    // timestamp through the CameraImage object it hands to this
    // callback). Safe to remove after this phase.
    logLatency('T0_frameCaptured=${DateTime.now().toIso8601String()}');

    // Metrics-only instrumentation (System Performance > Processing
    // Latency): times the ENTIRE per-frame pipeline below (detection +
    // risk assessment + evaluation logging), as opposed to the
    // existing `detectionStopwatch` further down which times only the
    // HazardDetectionService call itself (Object Detection > Average
    // Detection Latency). Recorded in the `finally` block so a frame
    // that throws partway through is still measured and counted.
    final frameStopwatch = Stopwatch()..start();

    try {
      // HazardDetectionService is the ONLY hazard-related class this
      // screen talks to. It has no idea this is COCO SSD MobileNet
      // specifically (or a future custom YOLO model) — that knowledge
      // is fully contained in lib/services/hazard_detectors/. See
      // HazardDetectionService's own doc comment for how to swap the
      // underlying detector later.
      // Phase 5 (Research Dashboard): latency measured here, at the
      // call site, specifically to avoid modifying HazardDetectionService
      // (a completed milestone).
      final detectionStopwatch = Stopwatch()..start();
      final hazards = await _hazardDetectionService.detectHazards(
        image,
        widget.camera.sensorOrientation,
      );
      detectionStopwatch.stop();

      // AUDIT ADD (Phase E4): re-check after the one call in this
      // pipeline that touches the TFLite interpreter directly —
      // `dispose()` could have run WHILE this await was in flight (this
      // check passed at entry, before dispose() began). Everything
      // below this point touches UI state (`setState`) and speaks —
      // none of that should run against a screen that's mid-teardown.
      if (_isDisposed) return;

      if (mounted) {
        setState(() {
          _currentFrameHazards = _hazardDetectionService.lastRawDetections;
        });
      }
      // PHASE B VERIFICATION LOG (temporary): direct, greppable
      // on-device proof that real per-frame detections — with class,
      // confidence, bounding box, timestamp, and source detector — are
      // actually being produced, independent of temporal confirmation.
      // Safe to remove once Phase B is signed off.
      for (final raw in _hazardDetectionService.lastRawDetections) {
        print('[PHASE-B-DETECTION] ${raw.toJson()}');
      }

      if (hazards.isNotEmpty) {
        // Detectors return results already sorted by priority then
        // confidence, so the most urgent hazard is simply the first
        // entry — see HazardDetectionService / DetectedHazard.
        final DetectedHazard topHazard = hazards.first;
        final String objectName = topHazard.label;
        _lastHazard = topHazard; // debug dashboard only

        // Milestone 3: compute and log a risk assessment. Read-only —
        // does not influence what's spoken below. See
        // RiskAssessmentService's doc comment.
        final riskAssessment = _riskAssessmentService.assess(
          hazard: topHazard,
          currentSpeedMetersPerSecond:
              (_lastPosition != null && _lastPosition!.speed >= 0)
              ? _lastPosition!.speed
              : null,
          profile: _behaviourLearningService.profile,
          environment: EnvironmentContext.fromCurrentTime(),
        );
        _lastRiskAssessment = riskAssessment; // debug dashboard only
        // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T6 =
        // risk assessment completed. Safe to remove after this phase.
        logLatency('T6_riskAssessed=${DateTime.now().toIso8601String()}');
        print(
          '[RiskAssessmentService] score=${riskAssessment.overallRiskScore.toStringAsFixed(2)} '
          'level=${riskAssessment.riskLevel.name} reason="${riskAssessment.explanation}"',
        );

        // Phase 1 (INSIGHT Adaptive Risk Intelligence Engine): the
        // central intelligence layer, combining vision, voice/
        // destination confidence, and GPS accuracy.
        //
        // AUDIT FIX (execution-trace audit, "duplicate RiskAssessmentService
        // computation"): `riskAssessment` above is now passed in
        // directly instead of AdaptiveRiskEngine recomputing an
        // identical one internally — removes a real per-frame
        // duplicate call. AUDIT FIX (follow-up): transitPhase/
        // isRoadCrossing are no longer accepted here at all — see
        // adaptive_risk_engine.dart's doc comment for why those two
        // factors were removed rather than left wired to a value that
        // can never vary in the current architecture.
        // NavigationDecisionEngine.decide()'s OWN transitPhase
        // parameter below is separate and unaffected.
        final adaptiveAssessment = _adaptiveRiskEngine.assess(
          AdaptiveRiskInput(
            topHazard: topHazard,
            destinationConfidence: _lastDestinationConfidence,
            gpsAccuracyMeters: _lastPosition?.accuracy,
          ),
          riskAssessment,
        );
        final prioritizedWarning = _warningPrioritizer.prioritize(hazards);
        final navigationDecision = _navigationDecisionEngine.decide(
          risk: adaptiveAssessment,
          warning: prioritizedWarning,
          transitPhase: TransitPhase.walking,
          awaitingVoiceConfirmation: false,
        );
        print(
          '[AdaptiveRiskEngine] score=${adaptiveAssessment.overallRiskScore.toStringAsFixed(2)} '
          'level=${adaptiveAssessment.riskLevel.name} reason="${adaptiveAssessment.explanation}"',
        );
        // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T7 =
        // NavigationDecisionEngine produces warning decision. Safe to
        // remove after this phase.
        logLatency('T7_decisionMade=${DateTime.now().toIso8601String()} decision=${navigationDecision.decision.name}');
        print(
          '[NavigationDecisionEngine] decision=${navigationDecision.decision.name} '
          'urgency=${prioritizedWarning.urgency.name} hazardsConsidered=${prioritizedWarning.includedHazards.length} '
          'reason="${navigationDecision.reason}"',
        );

        // Phase 3 (Explainable AI Engine): independent of the decision
        // flow below — reuses RiskAssessment's own explanation rather
        // than recomputing one. Read-only, feeds the AI Learning
        // Dashboard only.
        _lastExplanation = _explainableAIService.explain(
          hazard: topHazard,
          risk: riskAssessment,
          behaviour: _behaviourLearningService.profile,
          environment: EnvironmentContext.fromCurrentTime(),
        );

        // Fix 2 (Research Layer Independence): deliberately NOT
        // awaited. Previously `await`ing this call meant a slow (or
        // failing) Hive write would delay — or, if it threw, entirely
        // abort — the guidance decision and speech below. Firing it
        // without `await` means the safety path's execution no longer
        // has any causal dependency on this call completing.
        // `.catchError` keeps logging reliable (errors are surfaced,
        // not silently swallowed) without making the safety path wait
        // for or depend on the outcome. EvaluationService's own
        // internal throttled persistence (see its dispose()/endSession()
        // handling) is what keeps records from being lost — this
        // change only removes the artificial ordering dependency, it
        // doesn't change what gets persisted or when it's flushed.
        _evaluationService
            .beginRecord(
              objectType: objectName,
              detectionConfidence: topHazard.confidence,
              detectorSource: topHazard.sourceDetector,
              riskScore: riskAssessment.overallRiskScore,
              riskLevel: riskAssessment.riskLevel.name,
              language: _languageService.currentLanguage.name,
              processingLatencyMs:
                  detectionStopwatch.elapsedMicroseconds / 1000.0,
              boundingBoxLeft: topHazard.boundingBox?.left,
              boundingBoxTop: topHazard.boundingBox?.top,
              boundingBoxWidth: topHazard.boundingBox?.width,
              boundingBoxHeight: topHazard.boundingBox?.height,
              estimatedDistanceMeters: topHazard.estimatedDistanceMeters,
            )
            .catchError((e) {
              // ignore: avoid_print
              print(
                'EvaluationService.beginRecord failed (non-blocking, safety path unaffected): $e',
              );
            });

        // Onboarding integration: a Completely Blind user gets no
        // benefit from this visual overlay text, so skip the
        // setState/rebuild for them; Low Vision / Progressive Vision
        // Loss / unspecified users keep seeing it exactly as before —
        // this changes only whether the overlay updates, never any
        // spoken warning or navigation decision.
        final showsVisualOverlay =
            _userProfileService.profile.visionCondition !=
            VisionCondition.completelyBlind;
        if (showsVisualOverlay &&
            mounted &&
            _obstacleText != "Detected: $objectName") {
          setState(() {
            _obstacleText = "Detected: $objectName";
          });
        }

        // Milestone 4: ask the decision layer whether/how to speak.
        // AudioService itself is untouched — this only decides what to
        // pass it and when.
        final decision = _adaptiveGuidanceService.decideObstacleWarning(
          hazard: topHazard,
          risk: riskAssessment,
          profile: _behaviourLearningService.profile,
          timeSinceLastWarning: _timeSinceLastWarningFor(objectName),
          warningDistancePreference:
              _userProfileService.profile.warningDistancePreference,
          intent: _currentIntent,
        );

        // Fix 3 (Per-Hazard Warning Debounce): per-hazard-type timing
        // above already solves the main failure mode (a different
        // hazard type being suppressed by an unrelated recent
        // warning). This adds a second, stricter guarantee on top: a
        // Critical-risk hazard is NEVER suppressed by debounce timing
        // at all, even if it's the same hazard type warned about a
        // moment ago. AdaptiveGuidanceService's own logic and
        // constants are completely unchanged — this override happens
        // only at this call site.
        //
        // AUDIT FIX (System Stabilization phase): NavigationDecisionEngine's
        // output was being computed and logged every frame but never
        // actually consulted for behavior — a genuine "module exists
        // without being used" gap this phase's audit exists to catch.
        // Its immediate-danger classification now also triggers the
        // critical override, since a prioritized "stop immediately"
        // is at least as strong a signal as the older risk level check
        // it sits alongside (kept, not replaced — either one firing
        // is sufficient).
        final bool isCriticalOverride = !decision.shouldSpeak &&
            (riskAssessment.riskLevel == RiskLevel.critical ||
                navigationDecision.decision == NavigationDecision.stopImmediately);
        final bool effectiveShouldSpeak = decision.shouldSpeak || isCriticalOverride;

        if (effectiveShouldSpeak) {
          _lastWarningTimeByHazard[objectName] = DateTime.now();

          print(decision.message);
          print(
            '[AdaptiveGuidanceService] ${decision.reason}'
            '${isCriticalOverride ? ' [CRITICAL DEBOUNCE OVERRIDE APPLIED]' : ''}',
          );
          print(
            '[HazardDetectionService] source=${topHazard.sourceDetector} '
            'confidence=${topHazard.confidence.toStringAsFixed(2)} '
            'distance=${topHazard.distanceBand.name}',
          );

          // AUDIT FIX: NavigationDecisionEngine.interrupt now actually
          // participates in the interrupt decision, alongside the two
          // existing conditions — previously computed, never read.
          if (decision.interrupt || isCriticalOverride || navigationDecision.interrupt) {
            await _audioService.stopSpeaking();
          }
          // Message precedence, all three now genuinely consulted:
          // 1. NavigationDecisionEngine's message, when it has one —
          //    "every navigation decision should pass through this
          //    engine" means its wording should win when it has
          //    something to say (stop/slow down/confirm/board/transfer).
          // 2. The Warning Prioritizer's merged sentence, when 2+
          //    distinct hazards are worth mentioning and the decision
          //    engine had nothing more specific to add.
          // 3. AdaptiveGuidanceService's original single-hazard
          //    message — the pre-this-phase fallback, unchanged.
          final messageToSpeak = navigationDecision.message.isNotEmpty
              ? navigationDecision.message
              : (prioritizedWarning.includedHazards.length > 1 && prioritizedWarning.mergedMessage.isNotEmpty
                  ? prioritizedWarning.mergedMessage
                  : decision.message);
          // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): T8 =
          // TTS request begins (T9, actual audio start, is logged from
          // AudioService's flutter_tts startHandler). Safe to remove
          // after this phase.
          logLatency('T8_ttsRequestBegin=${DateTime.now().toIso8601String()} message="$messageToSpeak"');
          // AUDIT FIX (Phase C3 — TTS/detection concurrency): previously
          // `await`ed here, which held `_isProcessingFrame` true (see
          // this method's top) for the ENTIRE duration of the spoken
          // utterance — confirmed on-device that this meant NO new
          // camera frame was processed, and therefore no new detection,
          // hazard confirmation, or risk/decision update happened, for
          // as long as speech was playing (up to several seconds per
          // utterance). `AudioService.speak()` now safely queues
          // concurrent callers internally (see its own doc comment) so
          // NOT awaiting it here no longer risks overlapping/garbled
          // native audio — detection can keep running while this
          // utterance plays, and a later urgent warning can still
          // interrupt it via `stopSpeaking()` exactly as before.
          unawaited(
            _languageService.speak(_audioService, messageToSpeak).then((_) {
              // PHASE C3 TEMPORARY DIAGNOSTIC: marks when this specific
              // utterance actually finished, independent of frame
              // processing (which no longer waits for it). Safe to
              // remove after this phase.
              logLatency('T10_ttsComplete=${DateTime.now().toIso8601String()}');
            }),
          );
          _evaluationService.markWarningSpoken(
            adaptiveGuidanceMode: decision.reason,
          );
          _behaviourLearningService.recordObstacleWarningIssued(
            objectName,
            topHazard.distanceBand.name,
          );
        }
      } else {
        // Metrics-only: every frame where HazardDetectionService
        // returned no hazards at all, used as the True-Negatives proxy
        // when no ground-truth annotations are available.
        RuntimeMetricsCollector.instance.recordEmptyDetectionFrame();

        if (mounted &&
            _obstacleText.isNotEmpty &&
            DateTime.now().difference(_mostRecentWarningTime).inSeconds > 2) {
          setState(() {
            _obstacleText = "";
          });
          _behaviourLearningService.recordObstacleCleared();
          // Fix 2: same reasoning as beginRecord above — fire-and-
          // forget with error visibility, no blocking dependency.
          _evaluationService
              .completeRecord(
                walkingSpeedMetersPerSecond:
                    (_lastPosition != null && _lastPosition!.speed >= 0)
                    ? _lastPosition!.speed
                    : null,
                gpsLatitude: _lastPosition?.latitude,
                gpsLongitude: _lastPosition?.longitude,
                profile: _behaviourLearningService.profile,
                emergencyEventCount: _emergencyService.eventLog.length,
              )
              .catchError((e) {
                // ignore: avoid_print
                print(
                  'EvaluationService.completeRecord failed (non-blocking): $e',
                );
              });
          _lastHazard = null; // debug dashboard only
          _lastRiskAssessment = null; // debug dashboard only
        }
      }
    } finally {
      // Metrics-only: whole-pipeline latency, recorded regardless of
      // whether the frame took the hazard or no-hazard branch above,
      // and even if something above threw.
      frameStopwatch.stop();
      RuntimeMetricsCollector.instance.recordProcessingLatencyMs(
        frameStopwatch.elapsedMicroseconds / 1000.0,
      );

      // Metrics-only: memory sampling is throttled to roughly once
      // every 30 processed frames (not every frame) to keep the
      // ProcessInfo syscall from adding measurable overhead of its
      // own to the very pipeline it's measuring.
      if (RuntimeMetricsCollector.instance.cameraFrameCount % 30 == 0) {
        RuntimeMetricsCollector.instance.sampleMemoryUsage();
      }

      // Fix 1: guarantees release even if detectHazards(), speak(),
      // or anything else above throws.
      _isProcessingFrame = false;
    }
  }

  /// Fix 3 helper: per-hazard-type elapsed time since its last
  /// warning, defaulting to "a long time ago" for a hazard type never
  /// warned about yet (so its first warning is never suppressed).
  Duration _timeSinceLastWarningFor(String hazardLabel) {
    final last = _lastWarningTimeByHazard[hazardLabel];
    if (last == null) return const Duration(days: 1);
    return DateTime.now().difference(last);
  }

  String _getCardinalDirection(double bearing) {
    double normalized = (bearing + 360) % 360;
    if (normalized >= 337.5 || normalized < 22.5) return 'North';
    if (normalized >= 22.5 && normalized < 67.5) return 'Northeast';
    if (normalized >= 67.5 && normalized < 112.5) return 'East';
    if (normalized >= 112.5 && normalized < 157.5) return 'Southeast';
    if (normalized >= 157.5 && normalized < 202.5) return 'South';
    if (normalized >= 202.5 && normalized < 247.5) return 'Southwest';
    if (normalized >= 247.5 && normalized < 292.5) return 'West';
    return 'Northwest';
  }

  /// AUDIT MOVE (destination-resolution correctness phase): the
  /// substring-match / fuzzy-index-fallback / best-candidate-ranking
  /// logic that used to live here as three private methods
  /// (`_resolveGtfsStopForQuery`/`_pickBestCandidate`/
  /// `_resolveGtfsStopByFuzzyIndexMatch`) has moved, UNCHANGED except
  /// for one new first step, to `GtfsLocalityResolver`
  /// (`lib/services/gtfs/gtfs_locality_resolver.dart`) — a private
  /// State class's methods are unreachable from any test file, which
  /// made this logic untestable in place. See that class's doc
  /// comment for the full reasoning, including the new
  /// `stripTrailingCityQualifier` step that fixes the "Tambaram,
  /// Chennai"-class destination-resolution bug. `_gtfsLocalityResolver`
  /// (constructed alongside `_gtfsRepository` above) is what this
  /// screen now calls instead.

  Future<bool> _offerTransitJourneys(Position origin, Map<String, double> destinationCoords) async {
    try {
      // Safe to call unconditionally — memoized on the shared instance,
      // see GtfsRepository.initialize's doc comment. A no-op (instant,
      // already-completed Future) on every call after the very first
      // one anywhere in the app's lifetime.
      await _gtfsRepository.initialize(
        locationService: _locationService,
        autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
      );

      // ignore: avoid_print
      print('[NavigationScreen] Requesting journeys: origin=(${origin.latitude}, ${origin.longitude}), '
          'destination="$_effectiveDestinationText" resolved to (${destinationCoords['lat']}, ${destinationCoords['lon']})');
      final journeys = await _gtfsRepository.findJourneys(
        originLat: origin.latitude,
        originLon: origin.longitude,
        destinationLat: destinationCoords['lat']!,
        destinationLon: destinationCoords['lon']!,
        // Phase 2 fix: this was previously always false, regardless of
        // profile — a mobility-aid user (white cane/guide dog/other)
        // finds an extra transfer costlier than someone without one,
        // so the ranking should weight transfer count more heavily for
        // them specifically, not just take the fastest option.
        accessibilityPreferFewerTransfers: _userProfileService.profile.mobilityAid != MobilityAid.none,
      );

      if (journeys.isEmpty) {
        final reason = _gtfsRepository.lastJourneyPlanningFailureReason ??
            'No public transport option was found for this trip.';
        await _languageService.speak(_audioService, '$reason Continuing with walking directions.');
        return false;
      }

      // AUDIT ADD (transit-journey walking-leg accuracy fix): replace
      // each journey's straight-line walking-distance estimates with
      // real routed distances before showing them — see
      // journey_walking_enrichment.dart's doc comment for exactly what
      // this does and does not change (distance only, never the
      // schedule-locked transit timing). Run only on the small number
      // of journeys about to be displayed (never inside RAPTOR/
      // JourneyPlannerService itself, which must stay fast and
      // network-free for its own tests). A per-journey failure (no
      // network, provider error) falls back to that journey's
      // original estimate — enrichment is a best-effort accuracy
      // improvement, never a hard requirement to show a journey.
      final enrichedJourneys = <Journey>[];
      bool anyFirstWalkLikelyExceedsSchedule = false;
      for (final journey in journeys) {
        final result = await enrichJourneyWalkingLegs(
          journey: journey,
          originLat: origin.latitude,
          originLon: origin.longitude,
          locationService: _locationService,
        );
        enrichedJourneys.add(result.journey);
        if (result.firstWalkLikelyExceedsSchedule) anyFirstWalkLikelyExceedsSchedule = true;
      }
      if (anyFirstWalkLikelyExceedsSchedule) {
        await _languageService.speak(_audioService,
            'Note: the real walking distance to your first stop may be longer than estimated — you may need to hurry.');
      }

      if (!mounted) return false;
      final selected = await showJourneyOptionsSheet(
        context,
        journeys: enrichedJourneys,
        languageService: _languageService,
        audioService: _audioService,
      );
      if (selected == null) return false; // user chose "walk only"

      // AUDIT FIX (CRITICAL background state persistence fix — real
      // bug caught during on-device testing): this MUST happen HERE,
      // before the Navigator.push below, not after it. The push awaits
      // until TransitJourneyGuideScreen is POPPED — i.e. the entire
      // transit journey has already finished — so persisting only
      // after that `await` returns would mean nothing is ever saved
      // while the user is actually mid-journey inside that screen,
      // which is exactly the scenario this whole fix exists for.
      // Confirmed live: backgrounding the app while
      // TransitJourneyGuideScreen was showing, then force-stopping,
      // left nothing to restore under the original (too-late)
      // placement.
      _lastFetchRouteSucceeded = true;
      await _sessionPersistenceService.saveActiveSession(_effectiveDestinationText);

      if (!mounted) return true;
      final outcome = await Navigator.of(context).push<Object?>(MaterialPageRoute(
        builder: (_) => TransitJourneyGuideScreen(
          journey: selected,
          locationService: _locationService,
          languageService: _languageService,
          audioService: _audioService,
          destinationLat: destinationCoords['lat']!,
          destinationLon: destinationCoords['lon']!,
          // AUDIT ADD (transit state machine production integration):
          // NavigationScreen's own camera controller is still alive
          // underneath this pushed route (it was never popped) — these
          // callbacks are the CameraDetectionCommand contract's real
          // implementation, reusing the exact same controller/stream
          // rather than a second one. See _startDetectionCamera's doc
          // comment.
          onStartDetectionCamera: _startDetectionCamera,
          onStopDetectionCamera: _stopDetectionCamera,
          onResetDetectionState: _resetDetectionState,
          // AUDIT ADD (Phase NEXT — camera visibility): same live feed
          // this screen itself renders, reused via `_buildCameraFeedWidget`.
          buildCameraPreview: _buildCameraFeedWidget,
        ),
      ));

      // AUDIT ADD (CRITICAL background state persistence fix):
      // TransitJourneyGuideScreen has now been popped — the journey is
      // over (completed, or the rider backed out of it) — either way
      // there is nothing left to restore FOR THIS destination. If
      // [outcome] is a new destination string, the recursive
      // _fetchRoute call just below will persist a fresh session for
      // THAT if it succeeds; clearing first is still correct since a
      // finished/abandoned journey must never be what gets restored.
      await _sessionPersistenceService.clearActiveSession();

      // AUDIT NOTE (architectural limitation, reported per explicit
      // instruction rather than silently worked around): the "final
      // walking after alighting" leg does NOT reuse this file's own
      // OSRM/turn-by-turn walking loop below — there is no existing
      // "arrival detected -> announce -> ask where next" component
      // ANYWHERE in this file to reuse for that (confirmed by
      // inspection: no such flow exists for a plain walking trip
      // either). TransitJourneyGuideScreen therefore does its own
      // straight-line-distance arrival check for that specific leg —
      // NOT a second full navigation engine, just an arrival trigger
      // — while the actually safety-relevant part (camera streaming
      // and YOLO hazard detection during that walk) genuinely IS this
      // same NavigationScreen's real pipeline, restarted via the
      // camera callbacks above. If a full OSRM-guided final walk is
      // required, that's new work building the SAME "arrival ->
      // prompt" flow this file has never had, not a wiring gap.
      //
      // What DOES flow back here: if the rider spoke a genuine new
      // destination at TransitJourneyGuideScreen's "where would you
      // like to go now?" prompt, it pops with that raw String — run
      // through this exact same _fetchRoute pipeline via
      // [overrideDestinationText] (widget.destination itself is
      // `final` and cannot be reassigned), never a second resolver.
      if (outcome is String) {
        await _fetchRoute(overrideDestinationText: outcome);
      }
      return true;
    } catch (e) {
      // ignore: avoid_print
      print('Journey planning failed (continuing with walking-only navigation): $e');
      return false;
    }
  }

  /// AUDIT ADD (Phase F2 — silent GPS wait fix): a fix can legitimately
  /// take up to [LocationService]'s own 20s internal timeout, and
  /// previously nothing was said or shown beyond the one static
  /// "Getting your location." status set before this call — a user who
  /// can't see the screen has no way to tell "still working" from
  /// "frozen" for up to 20 seconds. This races the real GPS future
  /// against a SINGLE delayed filler announcement.
  ///
  /// Correctness properties, each deliberate:
  ///  - A fast fix (before [_gpsWaitAnnouncementDelay] elapses) cancels
  ///    the timer outright — nothing is ever spoken for the common case.
  ///  - `resolved` is set the instant the real future completes,
  ///    BEFORE the timer callback can run — a fix that lands exactly as
  ///    the delay elapses can never trigger a stale/late announcement.
  ///  - The message never claims a location IS ready — it only reports
  ///    that the app is still looking, and never mentions coordinates.
  ///  - It fires at most once — no repeat/spam even if the fix takes
  ///    the full 20s.
  ///  - `_isDisposed`/`mounted` are checked before speaking, so a
  ///    screen exit mid-wait can never trigger a late announcement on a
  ///    torn-down screen.
  ///
  /// The 5s threshold is a reasoned default (long enough that a normal
  /// fast fix never triggers it, short enough that it fires well before
  /// a user would otherwise start wondering if the app is frozen) —
  /// NOT empirically tuned against real device GPS acquisition timing,
  /// since no physical device was reachable this session. Flagged
  /// explicitly rather than presented as measured.
  static const Duration _gpsWaitAnnouncementDelay = Duration(seconds: 5);

  Future<Position?> _getCurrentLocationWithProgressAnnouncement() {
    return runWithDelayedProgressAnnouncement(
      action: () => _locationService.getCurrentLocation(),
      delay: _gpsWaitAnnouncementDelay,
      onDelayed: () {
        if (_isDisposed || !mounted) return;
        _languageService.speak(_audioService, 'Still finding your location.');
      },
    );
  }

  /// AUDIT ADD (Phase E1 — destination-safety hardening): speaks the
  /// resolved destination back to the user and requires an EXPLICIT
  /// affirmative answer (see voice_confirmation.dart) before
  /// navigation proceeds — never treats silence, an unrelated answer,
  /// or a garbled STT result as acceptance. An ambiguous answer gets
  /// one internal re-prompt ("please say yes or no") before this gives
  /// up and returns [VoiceConfirmationOutcome.ambiguous] to the
  /// caller, which the caller treats the same as a rejection (re-enter
  /// destination collection) rather than ever assuming acceptance.
  Future<VoiceConfirmationOutcome> _confirmDestinationWithUser(String displayName) async {
    const maxSubAttempts = 2;
    for (int i = 1; i <= maxSubAttempts; i++) {
      await _languageService.speak(_audioService, 'I understood your destination as $displayName. Is that correct?');
      final answer = await _listenOnceForText();
      final outcome = interpretYesNoAnswer(answer);
      if (outcome != VoiceConfirmationOutcome.ambiguous) return outcome;
      if (i < maxSubAttempts) {
        await _languageService.speak(_audioService, 'Sorry, please say yes or no.');
      }
    }
    return VoiceConfirmationOutcome.ambiguous;
  }

  /// AUDIT ADD (Phase E1): a single bounded listen — used both for
  /// destination-confirmation answers and for re-collecting a
  /// destination after a rejected/ambiguous confirmation. Returns null
  /// on timeout/error rather than throwing, so every call site can
  /// treat "didn't hear anything" as its own explicit, handled case.
  Future<String?> _listenOnceForText() async {
    final completer = Completer<String?>();
    await _audioService.listen(
      (text) {
        if (!completer.isCompleted) completer.complete(text);
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(null);
      },
      // AUDIT NOTE (Phase E1C): matches home_screen.dart's initial
      // destination-capture override — see that call site's doc
      // comment for the full reasoning. This helper is used both for
      // re-collecting a (potentially multi-word) destination and for
      // yes/no confirmation answers; a modest +1s pauseFor is harmless
      // for a short yes/no and directly helps the multi-word case.
      pauseFor: const Duration(seconds: 3),
    );
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () => null);
  }

  Future<void> _fetchRoute({String? overrideDestinationText}) async {
    // AUDIT ADD (CRITICAL background state persistence fix): reset at
    // the top of every call (this method has many early `return;`
    // failure paths below — resetting here, once, means none of them
    // need individual edits) so the caller can tell success from
    // failure via _lastFetchRouteSucceeded without this method's
    // return type changing. See the two `= true;` sites below for
    // where this is actually decided.
    _lastFetchRouteSucceeded = false;
    // AUDIT FIX (route-search-latency investigation — "intelligent
    // status handling"): status text now tracks the REAL current
    // phase (LOCATING/RESOLVING/PREPARING/PLANNING/ROUTE READY)
    // instead of one generic "Locating destination..." shown for the
    // entire search — a blind user relying on this text (or the
    // handful of phases that are also spoken, below) deserves an
    // honest description of what's actually happening, especially
    // during the one phase (GTFS preparation) that can genuinely take
    // minutes on a first-ever run. No internal terms (SQLite, RAPTOR,
    // GTFS, "database") are ever surfaced here.
    setState(() {
      _statusText = "Getting your location.";
    });
    // TEMPORARY PERF-DIAGNOSTIC (route-search-latency investigation):
    // per-stage wall-clock timing for this search, printed as one
    // block via _printRouteSearchTimingSummary once the outcome is
    // known (see that method). Deliberately excludes any
    // user-paced wait (e.g. the "did you mean X?" confirmation
    // below) — this measures computation/network latency, not how
    // long the user took to answer. Delete these locals, the prints
    // below, and _printRouteSearchTimingSummary once the investigation
    // is done, or fold them into RuntimeMetricsCollector/EvaluationService
    // if worth keeping permanently.
    int destinationResolutionMs = 0;
    int gtfsInitMs = 0;
    int gtfsStopMatchMs = 0;
    int geocodingMs = 0;
    int osrmMs = 0;

    // P0 device report: the app could be stuck on "Locating
    // destination..." indefinitely — this is the GPS fix, not
    // destination resolution, and it happens BEFORE any destination
    // text is even looked at, so it hung for EVERY destination, not a
    // specific one. LocationService.getCurrentLocation() now bounds
    // the wait internally (see its own doc comment) and returns null
    // on timeout — same contract as "service disabled"/"permission
    // denied," handled by the existing null-check below.
    final gpsStopwatch = Stopwatch()..start();
    // ignore: avoid_print
    print('[TRACE] BEFORE _locationService.getCurrentLocation()');
    Position? pos = await _getCurrentLocationWithProgressAnnouncement();
    final gpsLocationMs = gpsStopwatch.elapsedMilliseconds;
    // ignore: avoid_print
    print('[TRACE] AFTER _locationService.getCurrentLocation() -> ${pos == null ? 'null' : '(${pos.latitude}, ${pos.longitude})'} (${gpsLocationMs}ms)');
    if (pos == null) {
      _statusText = "Could not determine your location. Please check GPS/location settings and try again.";
      await _languageService.speak(_audioService, _statusText);
      if (mounted) setState(() {});
      return;
    }
    _lastPosition = pos;
    setState(() {
      _statusText = "Finding your destination.";
    });

    // Phase 1 (Voice Understanding Layer): resolve short forms/STT
    // mistakes/multilingual names/code-switched phrasing into a
    // proper geocodable query BEFORE handing it to the existing
    // geocoder — see voice_understanding_layer.dart's doc comment.
    // This does not replace or touch the STT engine itself; it only
    // interprets text `effectiveDestinationText` already contains.
    //
    // AUDIT ADD (transit state machine production integration):
    // `widget.destination` is `final` — fixed at construction — so a
    // NEW destination spoken at TransitJourneyGuideScreen's "where
    // would you like to go now?" prompt (see that file's
    // `_handleNextDestinationSpeech`) cannot be run through by
    // reassigning it. [overrideDestinationText] is that escape hatch:
    // when provided, resolution runs against IT instead, through this
    // exact same pipeline (VoiceUnderstandingLayer -> GTFS/geocoder ->
    // JourneyPlannerService below) — no second resolver, no special
    // case for any specific destination name.
    // AUDIT FIX (Phase E1 — destination-safety hardening): previously
    // only a LOW-CONFIDENCE dictionary/fuzzy match got a spoken "Did
    // you mean X?" confirmation — a GTFS stop match or a geocoded
    // (Nominatim) destination, which is the majority of real
    // destinations, went straight to route planning with NO
    // opportunity to catch a misheard/misresolved destination before
    // navigation began. That's unsafe for a user who can't see the
    // screen to notice the app is about to send them somewhere wrong.
    //
    // Every successfully resolved destination now gets exactly ONE
    // unified confirmation, asked AFTER the full resolution pipeline
    // (dictionary/fuzzy match -> GTFS stop match -> geocoding
    // fallback) has produced a real, human-readable place name — not
    // the raw recognized text, and not a mid-pipeline guess. Only an
    // explicit affirmative answer (see voice_confirmation.dart) is
    // accepted; a clear "no," silence, an unrelated answer, or a
    // garbled STT result all re-enter destination collection rather
    // than silently proceeding. Bounded at
    // [_maxDestinationConfirmationAttempts] attempts so this can never
    // become an infinite loop — after that many failed attempts, the
    // search is abandoned with a clear spoken explanation instead of
    // guessing.
    const maxDestinationConfirmationAttempts = 3;
    String destinationTextForAttempt = overrideDestinationText ?? widget.destination;
    DestinationResolution? resolution;
    Map<String, double>? coords;
    bool isColdImport = false;
    bool destinationConfirmed = false;

    for (int attempt = 1; attempt <= maxDestinationConfirmationAttempts && !destinationConfirmed; attempt++) {
      _effectiveDestinationText = destinationTextForAttempt;
      final destinationResolutionStopwatch = Stopwatch()..start();
      resolution = _voiceUnderstandingLayer.resolve(destinationTextForAttempt);
      destinationResolutionMs = destinationResolutionStopwatch.elapsedMilliseconds;
      _lastDestinationConfidence = resolution.confidence;
      // ignore: avoid_print
      print('[VoiceUnderstandingLayer] "$destinationTextForAttempt" -> "${resolution.displayName}" '
          '(query="${resolution.searchQuery}", matchType=${resolution.matchType}, '
          'confidence=${resolution.confidence.toStringAsFixed(2)}, '
          'detectedLanguage=${resolution.detectedLanguage} @ ${resolution.languageDetectionConfidence.toStringAsFixed(2)})');

      final destinationQuery = resolution.searchQuery;

      // AUDIT FIX (destination-resolution root cause): destinationQuery
      // previously went straight to the online Nominatim geocoder even
      // when it named a known GTFS transit stop ("Guindy", "Chennai
      // Central", "Tambaram", ...). Nominatim is a general ADDRESS
      // geocoder with no knowledge of this app's own bundled transit
      // stop names — a bare stop/landmark name like "Central" is
      // frequently ambiguous or unresolvable there, and the call itself
      // depends on internet reachability with only an 8s timeout and no
      // retry. Meanwhile GtfsQueryService.searchStops + FuzzyMatcher
      // (both already built, previously wired only into the research/
      // validation screen) can resolve these names directly against the
      // ~5,600 real stop records already on-device, with zero network
      // dependency. This tries that path FIRST; if it doesn't find a
      // confident match, behavior falls through to the exact same
      // Nominatim call as before — nothing existing is removed.
      coords = null;
      GtfsStop? matchedGtfsStop;
      try {
        // AUDIT FIX (route-search-latency investigation — GTFS-during-
        // onboarding fix): GtfsRepository.instance.initialize() is
        // already kicked off, fire-and-forget, at app startup (see
        // main.dart) — for the large majority of real usage, by the
        // time a user actually reaches navigation, preparation has
        // already finished in the background, and the call below
        // resolves near-instantly.
        //
        // Reads [isImportingForFirstTime] — a plain in-memory flag, NOT
        // [needsFirstTimeImport] — deliberately. A real device bug (see
        // GtfsRepository.isImportingForFirstTime's own doc comment)
        // showed that a live database query issued here WHILE
        // preparation is still running queues behind that preparation's
        // write transaction on sqflite's single serialized connection
        // and can therefore block for the ENTIRE remaining duration —
        // exactly the "still looks stuck" problem this status check
        // exists to prevent, just moved from the destination-resolution
        // step to this one. Reading a boolean field can never block.
        isColdImport = _gtfsRepository.isImportingForFirstTime;
        if (isColdImport) {
          _statusText = 'Transit data is still preparing.';
          if (mounted) setState(() {});
          await _languageService.speak(_audioService, _statusText);
        }
        final gtfsInitStopwatch = Stopwatch()..start();
        // ignore: avoid_print
        print('[TRACE] BEFORE _gtfsRepository.initialize() (cold=$isColdImport)');
        await _gtfsRepository.initialize(
          locationService: _locationService,
          autoImportAssetPathIfEmpty: 'assets/gtfs/chennai-unified-gtfs.zip',
        );
        gtfsInitMs = gtfsInitStopwatch.elapsedMilliseconds;
        // ignore: avoid_print
        print('[TRACE] AFTER _gtfsRepository.initialize() (cold=$isColdImport, ${gtfsInitMs}ms)');
        if (isColdImport) {
          _statusText = "Finding your destination.";
          if (mounted) setState(() {});
        }
        final gtfsStopMatchStopwatch = Stopwatch()..start();
        // ignore: avoid_print
        print('[TRACE] BEFORE _gtfsLocalityResolver.resolve("$destinationQuery")');
        matchedGtfsStop = await _gtfsLocalityResolver.resolve(destinationQuery, currentPosition: _lastPosition);
        gtfsStopMatchMs = gtfsStopMatchStopwatch.elapsedMilliseconds;
        // ignore: avoid_print
        print('[TRACE] AFTER _gtfsLocalityResolver.resolve() -> ${matchedGtfsStop?.stopName ?? 'no match'} (${gtfsStopMatchMs}ms)');
      } catch (e) {
        // ignore: avoid_print
        print('[NavigationScreen] GTFS stop pre-resolution failed (falling back to geocoder): $e');
      }

      String resolvedDisplayName;
      if (matchedGtfsStop != null) {
        coords = {'lat': matchedGtfsStop.stopLat, 'lon': matchedGtfsStop.stopLon};
        resolvedDisplayName = matchedGtfsStop.stopName;
        // ignore: avoid_print
        print('[NavigationScreen] Resolved "$destinationQuery" directly to GTFS stop '
            '"${matchedGtfsStop.stopName}" (${matchedGtfsStop.stopLat}, ${matchedGtfsStop.stopLon}) — skipping geocoder.');
      } else {
        final geocodingStopwatch = Stopwatch()..start();
        // ignore: avoid_print
        print('[TRACE] BEFORE _locationService.getCoordinatesFromAddress("$destinationQuery")');
        coords = await _locationService.getCoordinatesFromAddress(
          destinationQuery,
          pos,
        );
        geocodingMs = geocodingStopwatch.elapsedMilliseconds;
        resolvedDisplayName = resolution.displayName;
        // ignore: avoid_print
        print('[TRACE] AFTER _locationService.getCoordinatesFromAddress() -> $coords (${geocodingMs}ms)');
      }

      if (coords == null) {
        _statusText = "Could not find destination on map.";
        await _languageService.speak(_audioService, _statusText);
        if (mounted) setState(() {});
        return;
      }

      final confirmationOutcome = await _confirmDestinationWithUser(resolvedDisplayName);
      if (confirmationOutcome == VoiceConfirmationOutcome.affirmative) {
        destinationConfirmed = true;
        break;
      }

      // Rejected, or no clear answer could be obtained — never
      // silently proceed to route planning on an unconfirmed
      // destination.
      if (attempt >= maxDestinationConfirmationAttempts) {
        _statusText = "I couldn't confirm your destination. Please try again.";
        await _languageService.speak(_audioService, _statusText);
        if (mounted) setState(() {});
        return;
      }

      await _languageService.speak(_audioService, "Okay, where would you like to go?");
      final restated = await _listenOnceForText();
      if (restated == null || restated.trim().isEmpty) {
        _statusText = "I didn't hear that. Please try again.";
        await _languageService.speak(_audioService, _statusText);
        if (mounted) setState(() {});
        return;
      }
      destinationTextForAttempt = restated;
    }

    if (!destinationConfirmed || coords == null || resolution == null) {
      // Defensive — the loop above always either confirms and breaks,
      // or speaks a failure message and returns, so this line should
      // be unreachable. Left explicit rather than assumed.
      return;
    }

    // Phase 1 requirement 7: boost confidence using the existing
    // behaviour-learning module's recorded frequent places.
    //
    // AUDIT FIX (System Stabilization phase): the boosted value was
    // being computed and logged but never stored anywhere — another
    // "computed but not used" gap. It now updates
    // _lastDestinationConfidence, which is what AdaptiveRiskEngine's
    // Destination Confidence factor actually reads during the hazard
    // loop that follows.
    final frequentPlaces = _behaviourLearningService.profile?.frequentlyVisitedLocations ?? const [];
    if (frequentPlaces.isNotEmpty) {
      final boosted = _voiceUnderstandingLayer.boostConfidenceWithFrequentPlaces(
        resolution: resolution,
        resolvedLat: coords['lat']!,
        resolvedLon: coords['lon']!,
        frequentlyVisitedLocations: frequentPlaces,
      );
      if (boosted.confidence != resolution.confidence) {
        // ignore: avoid_print
        print('[VoiceUnderstandingLayer] Confidence boosted by frequent-places match: '
            '${resolution.confidence.toStringAsFixed(2)} -> ${boosted.confidence.toStringAsFixed(2)}');
        _lastDestinationConfidence = boosted.confidence;
      }
    }

    // Stage 2B: always check for public transport options first, per
    // the stage's requirement — if the user picks one, this hands off
    // to TransitJourneyGuideScreen and the rest of this method (the
    // existing walking-only OSRM route logic, entirely unchanged
    // below) never runs for this destination.
    final journeyPlanningStopwatch = Stopwatch()..start();
    // ignore: avoid_print
    print('[TRACE] BEFORE _offerTransitJourneys() (GTFS init re-check + findJourneys/RAPTOR + journey-options sheet)');
    final handedOffToTransitJourney = await _offerTransitJourneys(pos, coords);
    final journeyPlanningMs = journeyPlanningStopwatch.elapsedMilliseconds;
    // ignore: avoid_print
    print('[TRACE] AFTER _offerTransitJourneys() -> handedOff=$handedOffToTransitJourney (${journeyPlanningMs}ms)');
    if (handedOffToTransitJourney) {
      _printRouteSearchTimingSummary(
        isColdGtfsImport: isColdImport,
        gpsLocationMs: gpsLocationMs,
        destinationResolutionMs: destinationResolutionMs,
        gtfsInitMs: gtfsInitMs,
        gtfsStopMatchMs: gtfsStopMatchMs,
        geocodingMs: geocodingMs,
        journeyPlanningMs: journeyPlanningMs,
        osrmMs: 0,
      );
      // AUDIT ADD (CRITICAL background state persistence fix): only
      // the flag, NOT another saveActiveSession() call — that already
      // happened inside _offerTransitJourneys, at journey SELECTION
      // time (see its doc comment for why it must not happen here:
      // by the time this line runs, the entire transit journey,
      // including TransitJourneyGuideScreen, has already finished —
      // re-saving here would incorrectly mark an already-completed
      // trip as still "active"/restorable).
      _lastFetchRouteSucceeded = true;
      // AUDIT FIX (live on-device bug, Oct 2026): this success path
      // never updated `_statusText` — it stayed frozen on whatever it
      // was set to before the transit-journey handoff (almost always
      // "Finding your destination.", set at line ~1545/1661) for the
      // rest of the session, since nothing else on this screen updates
      // it afterward. A user returning here from a completed
      // TransitJourneyGuideScreen trip would see a stale "still
      // searching" message indefinitely with no indication the app
      // had finished (or even that anything had happened), confirmed
      // via a real device screenshot. Mirrors the walking-route path's
      // own convention (`_statusText = "Route found."` below) instead
      // of leaving this path as the one case with no completion text.
      if (mounted) setState(() => _statusText = "Transit journey finished.");
      return;
    }

    setState(() {
      _statusText = "Finding the safest route.";
    });

    // Feature 3 (Contextual Intent Inference): computed BEFORE route
    // selection (not just before speech) specifically so Feature 2's
    // SafeRouteService can use it on the very first route choice, not
    // only on obstacle-warning verbosity later in the trip. Uses only
    // data already resolved at this point (destination text, resolved
    // coordinates, and the existing behaviour profile) — no new
    // tracking, and profile is available any time after
    // BehaviourLearningService.initialize(), independent of an active
    // session.
    _currentIntent = _intentInferenceService.inferInitial(
      destination: _effectiveDestinationText,
      time: DateTime.now(),
      profile: _behaviourLearningService.profile,
      destinationLatitude: coords['lat'],
      destinationLongitude: coords['lon'],
    );

    // Feature 2 (Safe Path Optimization): try multiple candidate
    // routes and pick the safest via SafeRouteService, reusing the
    // existing RouteSafetyService/EvaluationService/BehaviourLearningService
    // data. This is purely additive over the original single-route
    // fetch: if alternatives aren't available (network hiccup, or
    // OSRM only returning one route for this origin/destination pair),
    // `routeData` falls back to the EXACT call this method always
    // made, so existing behavior is fully preserved in that case.
    RouteData? routeData;
    String? routeSafetyExplanation;
    final osrmStopwatch = Stopwatch()..start();
    try {
      // ignore: avoid_print
      print('[TRACE] BEFORE _locationService.getRouteAlternatives()');
      final candidates = await _locationService.getRouteAlternatives(
        pos,
        coords['lat']!,
        coords['lon']!,
      );
      // ignore: avoid_print
      print('[TRACE] AFTER _locationService.getRouteAlternatives() -> ${candidates.length} candidate(s) (${osrmStopwatch.elapsedMilliseconds}ms so far)');
      if (candidates.length > 1) {
        final safeRouteStopwatch = Stopwatch()..start();
        // ignore: avoid_print
        print('[TRACE] BEFORE _safeRouteService.selectSafestRoute()');
        final ranked = await _safeRouteService.selectSafestRoute(
          candidates: candidates,
          historicalRecords: _evaluationService.allRecords,
          profile: _behaviourLearningService.profile,
          intent: _currentIntent,
          routePreference: _userProfileService.profile.routePreference,
        );
        // ignore: avoid_print
        print('[TRACE] AFTER _safeRouteService.selectSafestRoute() -> ${ranked != null ? 'selected' : 'null'} '
            '(safe_route_ms=${safeRouteStopwatch.elapsedMilliseconds})');
        if (ranked != null) {
          routeData = ranked.route;
          routeSafetyExplanation = ranked.explanation;
        }
      }
    } catch (e) {
      // ignore: avoid_print
      print(
        'SafeRouteService selection failed (falling back to default routing): $e',
      );
    }
    if (routeData == null) {
      // ignore: avoid_print
      print('[TRACE] BEFORE _locationService.getRouteInstructions() (fallback — no alternatives/safest-route result)');
    }
    routeData ??= await _locationService.getRouteInstructions(
      pos,
      coords['lat']!,
      coords['lon']!,
    );
    osrmMs = osrmStopwatch.elapsedMilliseconds;
    // ignore: avoid_print
    print('[TRACE] AFTER OSRM block (getRouteAlternatives + selectSafestRoute + getRouteInstructions fallback) -> routeData=${routeData != null} (${osrmMs}ms total)');
    _printRouteSearchTimingSummary(
      isColdGtfsImport: isColdImport,
      gpsLocationMs: gpsLocationMs,
      destinationResolutionMs: destinationResolutionMs,
      gtfsInitMs: gtfsInitMs,
      gtfsStopMatchMs: gtfsStopMatchMs,
      geocodingMs: geocodingMs,
      journeyPlanningMs: journeyPlanningMs,
      osrmMs: osrmMs,
    );

    if (routeData != null) {
      // "Route found." — visual only (matching how "Getting your
      // location."/"Finding your destination."/"Finding the safest
      // route." are also visual-only, not spoken): the real turn
      // instruction set just below speaks its own line immediately
      // after, and announcing BOTH back-to-back would be exactly the
      // kind of redundant, unnecessary speech a voice-first app for
      // blind users must avoid.
      _statusText = "Route found.";
      // AUDIT ADD (CRITICAL background state persistence fix): a real
      // walking route was found — persist it. See
      // NavigationSessionPersistenceService's doc comment.
      _lastFetchRouteSucceeded = true;
      await _sessionPersistenceService.saveActiveSession(_effectiveDestinationText);
      _routeSteps = List.from(routeData.steps);
      _routePoints = routeData.polylinePoints;
      _startPoint = LatLng(pos.latitude, pos.longitude);
      _endPoint = LatLng(coords['lat']!, coords['lon']!);

      if (_routeSteps.isNotEmpty) {
        final roadStart = _routeSteps.first.location;
        final distanceToRoad = const Distance().as(
          LengthUnit.Meter,
          _startPoint!,
          roadStart,
        );

        LatLng targetPoint = roadStart;
        if (distanceToRoad > 2.0) {
          _hasOffRoadStart = true;
          _lastSpokenDistanceToRoad = distanceToRoad;
        } else {
          _hasOffRoadStart = false;
          if (_routePoints.length > 1) {
            for (int i = 0; i < _routePoints.length; i++) {
              if (const Distance().as(
                    LengthUnit.Meter,
                    _startPoint!,
                    _routePoints[i],
                  ) >
                  10.0) {
                targetPoint = _routePoints[i];
                break;
              }
            }
          } else if (_routeSteps.length > 1) {
            targetPoint = _routeSteps[1].location;
          }
        }

        final bearing = Geolocator.bearingBetween(
          _startPoint!.latitude,
          _startPoint!.longitude,
          targetPoint.latitude,
          targetPoint.longitude,
        );

        double? currentHeading = _currentCompassHeading;
        if (currentHeading == null) {
          try {
            final firstEvent = await FlutterCompass.events?.first.timeout(
              const Duration(milliseconds: 1500),
            );
            currentHeading = firstEvent?.heading;
            _currentCompassHeading = currentHeading;
          } catch (_) {}
        }

        String initialInstruction;
        String? relativeDirection;

        if (currentHeading != null) {
          double relativeAngle = (bearing - currentHeading + 360) % 360;
          if (relativeAngle >= 315 || relativeAngle < 45) {
            relativeDirection = "straight ahead";
          } else if (relativeAngle >= 45 && relativeAngle < 135) {
            relativeDirection = "to your right";
          } else if (relativeAngle >= 135 && relativeAngle < 225) {
            relativeDirection = "behind you";
          } else {
            relativeDirection = "to your left";
          }
          _lastSpokenRelativeDirection = relativeDirection;
        }

        if (_hasOffRoadStart) {
          if (relativeDirection != null) {
            initialInstruction =
                "Proceed to the road first. The road is $relativeDirection, about ${distanceToRoad.round()} meters away.";
          } else {
            final cardinalDir = _getCardinalDirection(bearing);
            initialInstruction =
                "Proceed to the road first. Walk about ${distanceToRoad.round()} meters $cardinalDir to reach the street.";
          }

          if (_routeSteps.isNotEmpty) {
            initialInstruction += " Then, ${_routeSteps[0].instruction}";
          }

          _routeSteps.insert(0, RouteStep(initialInstruction, roadStart));
          _statusText = initialInstruction;
        } else {
          String originalInstruction = _routeSteps.first.instruction;
          if (relativeDirection != null) {
            initialInstruction =
                "The route continues $relativeDirection. $originalInstruction";
          } else {
            initialInstruction = originalInstruction;
          }

          if (_routeSteps.length > 1) {
            initialInstruction += " Then, ${_routeSteps[1].instruction}";
          }

          _routeSteps[0] = RouteStep(initialInstruction, roadStart);
          _statusText = initialInstruction;
        }

        await _languageService.speak(_audioService, "Route found. $_statusText");
        if (routeSafetyExplanation != null) {
          // Feature 2 requirement: "explain WHY a safer path was
          // selected." Spoken once, after the normal route
          // announcement, so it doesn't replace or delay it.
          await _languageService.speak(_audioService, 
            'This route was chosen for safety. $routeSafetyExplanation',
          );
        }
        _currentStepIndex = 1;
        _behaviourLearningService.startSession();
        _evaluationService.startSession();
        // Metrics-only: reuses the exact session ID EvaluationService
        // just generated (via its currentSessionId getter) so both
        // logs can be correlated, rather than minting a second,
        // independent ID for the same session.
        RuntimeMetricsCollector.instance.startSession();
        _navigationMetricsTracker.startSession(
          sessionId:
              _evaluationService.currentSessionId ??
              DateTime.now().millisecondsSinceEpoch.toString(),
          destination: _effectiveDestinationText,
          totalSteps: _routeSteps.length,
        );
      } else {
        _statusText = "Could not find a walking route.";
        await _languageService.speak(_audioService, _statusText);
      }

      try {
        _mapController.move(_startPoint!, 15.0);
      } catch (e) {}
    } else {
      _statusText = "Could not calculate a route.";
      await _languageService.speak(_audioService, _statusText);
    }

    if (mounted) setState(() {});
  }

  Future<void> _startNavigationLoop() async {
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
          ),
        ).listen((Position position) async {
          _lastPosition = position;
          _behaviourLearningService.recordPositionSample(
            latitude: position.latitude,
            longitude: position.longitude,
            speedMetersPerSecond: position.speed >= 0 ? position.speed : null,
            timestamp: position.timestamp,
          );
          // Feature 3: refine (never re-categorize) confidence in the
          // already-inferred intent using live speed + the deviation
          // count NavigationMetricsTracker already collects (Feature 3
          // requirement: "continuously update confidence").
          _currentIntent = _intentInferenceService.refineDuringNavigation(
            current: _currentIntent,
            currentSpeedMetersPerSecond: position.speed >= 0
                ? position.speed
                : null,
            routeDeviationCount:
                _navigationMetricsTracker.pendingSession?.deviationCount ?? 0,
          );
          if (_routeSteps.isNotEmpty &&
              _currentStepIndex < _routeSteps.length) {
            LatLng currentLoc = LatLng(position.latitude, position.longitude);
            LatLng nextManeuver = _routeSteps[_currentStepIndex].location;

            double distanceToNext = const Distance().as(
              LengthUnit.Meter,
              currentLoc,
              nextManeuver,
            );

            double threshold = 20.0;

            if (_hasOffRoadStart && _currentStepIndex == 1) {
              threshold = 2.0;

              if (DateTime.now()
                          .difference(_lastNavigationInstructionTime)
                          .inSeconds >
                      6 &&
                  !_isDescribingScene) {
                final distanceDiff =
                    (_lastSpokenDistanceToRoad - distanceToNext).abs();
                if (distanceDiff >= 1.0 && distanceToNext > threshold) {
                  _lastNavigationInstructionTime = DateTime.now();

                  final bearing = Geolocator.bearingBetween(
                    position.latitude,
                    position.longitude,
                    nextManeuver.latitude,
                    nextManeuver.longitude,
                  );

                  String dirMsg = "";
                  double? currentHeading =
                      _currentCompassHeading ??
                      (position.heading > 0.0 && position.speed > 0.5
                          ? position.heading
                          : null);
                  if (currentHeading != null) {
                    double relativeAngle =
                        (bearing - currentHeading + 360) % 360;
                    if (relativeAngle >= 315 || relativeAngle < 45) {
                      dirMsg = "straight ahead";
                    } else if (relativeAngle >= 45 && relativeAngle < 135) {
                      dirMsg = "to your right";
                    } else if (relativeAngle >= 135 && relativeAngle < 225) {
                      dirMsg = "behind you";
                    } else {
                      dirMsg = "to your left";
                    }
                    _lastSpokenRelativeDirection = dirMsg;
                  } else {
                    dirMsg = _getCardinalDirection(bearing);
                  }

                  String trend = "";
                  if (distanceToNext > _lastSpokenDistanceToRoad) {
                    trend = "You are moving away. ";
                    _navigationMetricsTracker.recordDeviation();
                  }

                  _lastSpokenDistanceToRoad = distanceToNext;
                  final progressMsg =
                      "${trend}The road is $dirMsg, ${distanceToNext.round()} meters away.";
                  setState(() {
                    _statusText = progressMsg;
                  });
                  await _languageService.speak(_audioService, progressMsg);
                }
              }
            }

            if (distanceToNext < threshold) {
              if (DateTime.now()
                          .difference(_lastNavigationInstructionTime)
                          .inSeconds >
                      10 &&
                  !_isDescribingScene) {
                _lastNavigationInstructionTime = DateTime.now();
                String instruction = _routeSteps[_currentStepIndex].instruction;
                setState(() {
                  _statusText = instruction;
                });
                await _languageService.speak(_audioService, instruction);
                _recordTurnFromInstruction(instruction);
                // Metrics-only: the OSRM 'arrive' step's instruction text
                // is this exact constant (see LocationService), so a match
                // here means the user genuinely reached the final
                // destination step, not just that the session ended.
                if (instruction == LocationService.arrivalInstruction) {
                  _navigationMetricsTracker.recordArrival();
                  // AUDIT ADD (CRITICAL background state persistence
                  // fix): the destination was actually reached —
                  // nothing left to restore. See
                  // NavigationSessionPersistenceService's doc comment.
                  await _sessionPersistenceService.clearActiveSession();
                }
                _currentStepIndex++;
              }
            }
          }
        });
  }

  /// TEMPORARY PERF-DIAGNOSTIC (route-search-latency investigation) —
  /// prints the exact stage breakdown requested for this investigation
  /// as ONE block per search (not scattered prints), including
  /// JourneyPlannerService's own internal sub-breakdown (GTFS
  /// timetable build / RAPTOR routing / route metadata / journey
  /// assembly — see `GtfsRepository.lastJourneySearchTimingsMs`) when
  /// a transit search actually ran. Not gated behind any flag — delete
  /// this method and its call sites in [_fetchRoute] once the
  /// investigation is done, or fold the numbers into
  /// RuntimeMetricsCollector/EvaluationService if worth keeping.
  void _printRouteSearchTimingSummary({
    required bool isColdGtfsImport,
    required int gpsLocationMs,
    required int destinationResolutionMs,
    required int gtfsInitMs,
    required int gtfsStopMatchMs,
    required int geocodingMs,
    required int journeyPlanningMs,
    required int osrmMs,
  }) {
    final totalMs =
        gpsLocationMs + destinationResolutionMs + gtfsInitMs + gtfsStopMatchMs + geocodingMs + journeyPlanningMs + osrmMs;
    final buffer = StringBuffer()
      ..writeln('[NavigationScreen] ROUTE SEARCH TIMING for "$_effectiveDestinationText":')
      ..writeln('  GPS location fix: ${gpsLocationMs}ms')
      ..writeln('  Destination resolution (voice understanding): ${destinationResolutionMs}ms')
      ..writeln('  GTFS init ${isColdGtfsImport ? '(COLD — first-ever import ran)' : '(WARM — database already present, reused)'}: ${gtfsInitMs}ms')
      ..writeln('  GTFS stop match (on-device, no network): ${gtfsStopMatchMs}ms')
      ..writeln('  Geocoding (Nominatim, only when GTFS stop match misses): ${geocodingMs}ms')
      ..writeln('  Journey planning (GTFS lookup + RAPTOR routing + journey assembly): ${journeyPlanningMs}ms');
    final subTimings = _gtfsRepository.lastJourneySearchTimingsMs;
    if (subTimings != null) {
      buffer.writeln('    breakdown -> nearby stops + service ids: ${subTimings['nearbyStopsAndServiceIdsMs']}ms, '
          'GTFS timetable build: ${subTimings['gtfsTimetableMs']}ms, '
          'RAPTOR routing: ${subTimings['raptorRoutingMs']}ms, '
          'route metadata: ${subTimings['routeMetadataMs']}ms, '
          'journey assembly: ${subTimings['journeyAssemblyMs']}ms');
    }
    buffer
      ..writeln('  OSRM walking route (only when no transit journey was taken): ${osrmMs}ms')
      ..writeln('  TOTAL (excludes any user-paced confirmation wait): ${totalMs}ms');
    // ignore: avoid_print
    print(buffer.toString());
  }

  /// Milestone 2 hook: infers a left/right turn from the same
  /// instruction text already spoken to the user (e.g. an OSRM
  /// maneuver like "Turn left onto Main Street"), without adding any
  /// new UI or sensor. Deliberately simple keyword matching — no NLP,
  /// no ML, consistent with this milestone's "collect data only,
  /// simple heuristics" scope.
  void _recordTurnFromInstruction(String instruction) {
    final lower = instruction.toLowerCase();
    final hasLeft = lower.contains('left');
    final hasRight = lower.contains('right');
    if (hasLeft && !hasRight) {
      _behaviourLearningService.recordTurn('left');
    } else if (hasRight && !hasLeft) {
      _behaviourLearningService.recordTurn('right');
    }
    // Instructions matching neither, or ambiguously matching both
    // (e.g. mentioning a street with "Right" in its name), are
    // skipped rather than guessed at.
  }

  /// Builds a read-only snapshot of current live state for the
  /// developer debug dashboard. Purely observational — reads existing
  /// fields/getters, calls no service methods, and changes nothing.
  DebugSnapshot _buildDebugSnapshot() {
    return DebugSnapshot(
      detectorSource: _lastHazard?.sourceDetector,
      hazardLabel: _lastHazard?.label,
      hazardConfidence: _lastHazard?.confidence,
      distanceBand: _lastHazard?.distanceBand.name,
      liveSpeedMetersPerSecond:
          (_lastPosition != null && _lastPosition!.speed >= 0)
          ? _lastPosition!.speed
          : null,
      gpsLatitude: _lastPosition?.latitude,
      gpsLongitude: _lastPosition?.longitude,
      cameraStreaming:
          _cameraController.value.isInitialized &&
          _cameraController.value.isStreamingImages,
      isSpeaking: _audioService.isSpeaking,
      isListening: _audioService.isListening,
      hiveOpen: _behaviourLearningService.isHiveOpen,
      profile: _behaviourLearningService.profile,
      riskAssessment: _lastRiskAssessment,
      emergencyCountdownActive: _emergencyService.isCountdownActive,
      emergencySecondsRemaining: _emergencyService.secondsRemaining,
      emergencyContactCount: _emergencyService.contacts.length,
      lastEmergencyEventStatus: _emergencyService.eventLog.isNotEmpty
          ? _emergencyService.eventLog.first.status.name
          : null,
      currentLanguage: _languageService.currentLanguage.name,
      detectorAvailability: _hazardDetectionService.detectorAvailability,
    );
  }

  @override
  void dispose() {
    // AUDIT FIX (Phase E4 — camera/interpreter lifecycle safety): set
    // FIRST, before anything else — see `_isDisposed`'s own doc
    // comment for why this is the primary defense against a frame
    // callback touching torn-down services.
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _positionStream?.cancel();
    _compassSubscription?.cancel();
    _sosCountdownTickSubscription?.cancel();
    _sosOutcomeSubscription?.cancel();

    // AUDIT FIX (Phase E4): best-effort request to stop the image
    // stream before disposing the controller — `dispose()` cannot be
    // `async`, so this cannot be awaited to completion first, but
    // issuing it before `_cameraController.dispose()` gives the plugin
    // a chance to wind the stream down in the right order rather than
    // relying solely on `dispose()` to handle a still-streaming
    // controller implicitly. Errors from this fire-and-forget call are
    // swallowed deliberately — this is a best-effort nicety, not the
    // real safety guard (that's `_isDisposed`, checked above).
    if (_cameraController.value.isStreamingImages) {
      // ignore: discarded_futures
      _cameraController.stopImageStream().catchError((Object e) {
        // ignore: avoid_print
        print('NavigationScreen.dispose: stopImageStream failed (non-fatal): $e');
      });
    }

    // AUDIT FIX (Phase E4): previously unguarded — an exception from
    // either of these (a real, documented occurrence with the `camera`
    // plugin's native teardown on some OEM devices) would have
    // propagated out of dispose() and skipped EVERY cleanup call below
    // it (metrics export, Hive box closes, other services' dispose()
    // calls) — a much larger blast radius than the camera/interpreter
    // failure itself. Matches the try/catch-per-call pattern
    // `AudioService.dispose()` already uses for the same reason.
    try {
      _cameraController.dispose();
    } catch (e) {
      // ignore: avoid_print
      print('NavigationScreen.dispose: cameraController.dispose failed (non-fatal): $e');
    }
    try {
      _hazardDetectionService.dispose();
    } catch (e) {
      // ignore: avoid_print
      print('NavigationScreen.dispose: hazardDetectionService.dispose failed (non-fatal): $e');
    }

    // Evaluation-metrics export. Everything in this block up to and
    // including computeReport() is fully synchronous, so it runs HERE
    // — before any Hive box below is closed, and without waiting on
    // NavigationMetricsTracker.endSession()'s async Hive write — by
    // finalizing this session's record in memory (currentSession) and
    // passing it directly to computeReport() as an override. Only the
    // actual Hive persistence and file-writing below are deferred,
    // detached async steps, since neither touches anything this
    // dispose() call is about to tear down.
    RuntimeMetricsCollector.instance.endSession();
    final currentSession = _navigationMetricsTracker.pendingSession?.copyWith(
      endTime: DateTime.now(),
      stepsCompleted: _currentStepIndex,
    );
    final metricsReport = MetricsReportService.instance.computeReport(
      evaluationService: _evaluationService,
      behaviourLearningService: _behaviourLearningService,
      navigationMetricsTracker: _navigationMetricsTracker,
      currentSessionOverride: currentSession,
    );

    _navigationMetricsTracker
        .endSession(stepsCompleted: _currentStepIndex)
        .catchError((e) {
          // ignore: avoid_print
          print(
            'NavigationMetricsTracker.endSession failed (non-blocking): $e',
          );
        })
        .whenComplete(() => _navigationMetricsTracker.dispose());

    MetricsReportService.instance
        .writeReportFiles(metricsReport)
        .then((paths) {
          // ignore: avoid_print
          print('Evaluation metrics exported: $paths');
        })
        .catchError((e) {
          // ignore: avoid_print
          print('Evaluation metrics export failed (non-blocking): $e');
        });

    _behaviourLearningService.endSession();
    _evaluationService.endSession();
    _behaviourLearningService.dispose();
    _userProfileService.dispose();
    _fallDetectionSignalSource.dispose();
    _emergencyService.dispose();
    _sessionPersistenceService.dispose();
    _languageService.dispose();
    _evaluationService.dispose();
    _audioService.dispose();
    // AUDIT FIX (route-search-latency investigation): _gtfsRepository
    // is now the shared, app-lifetime GtfsRepository.instance (see its
    // field doc comment) — this screen must NOT dispose it; doing so
    // would close the database connection out from under every other
    // screen/future navigation session for the rest of the app's
    // process lifetime.
    _scannerAnimationController.dispose();
    super.dispose();
  }

  Future<void> _resumeCameraAndFinish() async {
    if (mounted) {
      setState(() {
        _isDescribingScene = false;
        if (_savedStatusText.isNotEmpty) {
          _statusText = _savedStatusText;
        }
      });
      if (!_cameraController.value.isStreamingImages) {
        try {
          _cameraController.startImageStream((CameraImage image) {
            RuntimeMetricsCollector.instance.recordCameraFrame();
            _processCameraImage(image);
          });
        } catch (_) {}
      }
    }
  }

  Future<void> _describeScene({bool isDirect = false}) async {
    if (_isDescribingScene) return;

    await _audioService.stopSpeaking();

    _savedStatusText = _statusText;

    setState(() {
      _isDescribingScene = true;
      _statusText = isDirect
          ? "Analyzing scene..."
          : "Listening for question...";
    });

    HapticFeedback.heavyImpact();

    if (isDirect) {
      try {
        if (_cameraController.value.isStreamingImages) {
          await _cameraController.stopImageStream();
        }
      } catch (_) {}

      await _languageService.speak(_audioService, "Analyzing scene");
      await Future.delayed(const Duration(milliseconds: 200));

      try {
        final XFile imageFile = await _cameraController.takePicture();
        HapticFeedback.heavyImpact();

        final description = await _sceneDescriptionService.describeScene(
          imageFile,
        );
        if (description != null) {
          await _languageService.speak(_audioService, description);
        }
      } catch (e) {
        print("Camera capture error: $e");
        await _languageService.speak(_audioService, 
          "Sorry, there was an error capturing the scene.",
        );
      } finally {
        await _resumeCameraAndFinish();
      }
    } else {
      await _languageService.speak(_audioService, "Ask your question.");
      await Future.delayed(const Duration(milliseconds: 200));

      await _audioService.listen(
        (recognizedWords) async {
          if (recognizedWords.isEmpty) {
            await _resumeCameraAndFinish();
            return;
          }

          await _audioService.stopListening();
          setState(() {
            _statusText = "Analyzing: \"$recognizedWords\"";
          });

          try {
            if (_cameraController.value.isStreamingImages) {
              await _cameraController.stopImageStream();
            }
          } catch (_) {}

          await _languageService.speak(_audioService, "Checking...");
          HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 200));

          try {
            final XFile imageFile = await _cameraController.takePicture();
            final description = await _sceneDescriptionService.describeScene(
              imageFile,
              userQuestion: recognizedWords,
            );
            if (description != null) {
              await _languageService.speak(_audioService, description);
            }
          } catch (e) {
            print("Camera capture error: $e");
            await _languageService.speak(_audioService, 
              "Sorry, there was an error capturing the scene.",
            );
          } finally {
            await _resumeCameraAndFinish();
          }
        },
        onError: (errorMsg) async {
          try {
            setState(() {
              _statusText = "Analyzing scene...";
            });

            try {
              if (_cameraController.value.isStreamingImages) {
                await _cameraController.stopImageStream();
              }
            } catch (_) {}

            await _languageService.speak(_audioService, "Describing scene.");
            HapticFeedback.heavyImpact();
            await Future.delayed(const Duration(milliseconds: 200));

            final XFile imageFile = await _cameraController.takePicture();
            final description = await _sceneDescriptionService.describeScene(
              imageFile,
            );
            if (description != null) {
              await _languageService.speak(_audioService, description);
            }
          } catch (e) {
            print("Camera capture error: $e");
          } finally {
            await _resumeCameraAndFinish();
          }
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_cameraController.value.isInitialized) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                flex: 35,
                child: _startPoint == null
                    ? const Center(child: CircularProgressIndicator())
                    : FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: _startPoint!,
                          initialZoom: 15.0,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            // AUDIT FIX (real-device validation phase —
                            // map/route accuracy): was the flutter_map
                            // default placeholder ('com.example.vaishnavi'),
                            // not this app's real package id. OSM's tile
                            // usage policy requires an identifiable
                            // User-Agent; a generic placeholder is exactly
                            // what their servers are known to throttle or
                            // degrade, which can present to a user as
                            // tiles failing or loading inconsistently.
                            userAgentPackageName: 'com.project1.vaishnavi',
                          ),
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: _routePoints,
                                color: Colors.blueAccent,
                                strokeWidth: 5.0,
                              ),
                            ],
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: _startPoint!,
                                child: const Icon(
                                  Icons.person_pin_circle,
                                  color: Colors.blue,
                                  size: 40,
                                ),
                              ),
                              if (_endPoint != null)
                                Marker(
                                  point: _endPoint!,
                                  child: const Icon(
                                    Icons.location_on,
                                    color: Colors.red,
                                    size: 40,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
              ),
              Expanded(
                flex: 65,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Semantics(
                      label: 'Describe Scene',
                      hint:
                          'Double tap to ask a question, or long press to describe the scene immediately.',
                      button: true,
                      onTap: _describeScene,
                      onLongPress: () => _describeScene(isDirect: true),
                      child: GestureDetector(
                        onDoubleTap: _describeScene,
                        onLongPress: () => _describeScene(isDirect: true),
                        child: _buildCameraFeedWidget(),
                      ),
                    ),
                    if (_isDescribingScene)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black26,
                          child: ClipRect(
                            child: BackdropFilter(
                              filter: ImageFilter.blur(
                                sigmaX: 5.0,
                                sigmaY: 5.0,
                              ),
                              child: Container(
                                color: Colors.black.withOpacity(0.4),
                                child: Stack(
                                  children: [
                                    LayoutBuilder(
                                      builder: (context, constraints) {
                                        return AnimatedBuilder(
                                          animation:
                                              _scannerAnimationController,
                                          builder: (context, child) {
                                            return Positioned(
                                              top:
                                                  _scannerAnimationController
                                                      .value *
                                                  constraints.maxHeight,
                                              left: 0,
                                              right: 0,
                                              child: Container(
                                                height: 4,
                                                decoration: BoxDecoration(
                                                  boxShadow: [
                                                    BoxShadow(
                                                      color: Colors.cyan
                                                          .withOpacity(0.8),
                                                      blurRadius: 15,
                                                      spreadRadius: 3,
                                                    ),
                                                  ],
                                                  gradient: LinearGradient(
                                                    colors: [
                                                      Colors.transparent,
                                                      Colors.cyan.shade300,
                                                      Colors.blueAccent,
                                                      Colors.cyan.shade300,
                                                      Colors.transparent,
                                                    ],
                                                    stops: const [
                                                      0.0,
                                                      0.2,
                                                      0.5,
                                                      0.8,
                                                      1.0,
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );
                                          },
                                        );
                                      },
                                    ),
                                    Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Container(
                                            width: 80,
                                            height: 80,
                                            decoration: BoxDecoration(
                                              shape: BoxShape.circle,
                                              border: Border.all(
                                                color: Colors.cyan.shade300,
                                                width: 2,
                                              ),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: Colors.cyan
                                                      .withOpacity(0.2),
                                                  blurRadius: 10,
                                                  spreadRadius: 2,
                                                ),
                                              ],
                                            ),
                                            child: Padding(
                                              padding: const EdgeInsets.all(
                                                12.0,
                                              ),
                                              child: CircularProgressIndicator(
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                      Color
                                                    >(Colors.cyan.shade300),
                                                strokeWidth: 3,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 24),
                                          Text(
                                            _statusText.contains("Listening")
                                                ? "Listening for question..."
                                                : "AI Lens is analyzing...",
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                              color: Colors.cyan.shade100,
                                              fontSize: 20,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.5,
                                              shadows: [
                                                Shadow(
                                                  color: Colors.cyan
                                                      .withOpacity(0.5),
                                                  blurRadius: 10,
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          const Text(
                                            "Please hold your camera steady",
                                            style: TextStyle(
                                              color: Colors.white70,
                                              fontSize: 14,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      bottom: 20,
                      left: 20,
                      right: 20,
                      child: Container(
                        padding: const EdgeInsets.all(15),
                        decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              "Destination: $_effectiveDestinationText",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Text(
                              _statusText,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.lightGreenAccent,
                                fontSize: 18,
                              ),
                            ),
                            if (_obstacleText.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.redAccent.withOpacity(0.9),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.warning_amber_rounded,
                                      color: Colors.white,
                                      size: 24,
                                    ),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        _obstacleText,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  "Enable object detection",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Switch(
                                  value: _enableObjectDetection,
                                  activeColor: Colors.deepPurpleAccent,
                                  onChanged: (val) {
                                    setState(() {
                                      _enableObjectDetection = val;
                                      if (!val) {
                                        _obstacleText = "";
                                      }
                                    });
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: const Alignment(0, -0.3),
            child: Semantics(
              button: true,
              label: "Restart Navigation",
              hint: "Double tap to go back to the home screen.",
              child: FloatingActionButton(
                backgroundColor: Colors.redAccent,
                onPressed: () {
                  _audioService.stopSpeaking();
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (context) => const HomeScreen()),
                  );
                },
                child: const Icon(Icons.refresh, color: Colors.white, size: 30),
              ),
            ),
          ),
          // Developer Debug Dashboard entry point.
          // FIX (Issue 2): was `if (kDebugMode)`, which made this
          // button — and therefore the dashboard itself — not exist
          // at all in release builds, including release builds built
          // specifically for a demonstration that needs it. Replaced
          // with the dedicated `enableResearchTools` flag (see
          // research_tools_config.dart); the widget is still not
          // built at all when that flag is false, same guarantee as
          // before, just controlled by a flag meant for this purpose
          // instead of the debug/release build-mode constant. This is
          // one of two independent enforcement points; see
          // DebugDashboardScreen's own doc comment for the second.
          if (enableResearchTools)
            Align(
              alignment: const Alignment(0.88, 0.95),
              child: FloatingActionButton.small(
                heroTag: 'debug_dashboard_fab',
                backgroundColor: Colors.black54,
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => DebugDashboardScreen(
                        getSnapshot: _buildDebugSnapshot,
                      ),
                    ),
                  );
                },
                child: const Icon(Icons.bug_report, color: Colors.white),
              ),
            ),
          // Phases 1-7: Research Menu entry point (AI Learning Dashboard,
          // Research Dashboard, Route Safety). FIX (Issue 2): was
          // `if (kDebugMode)`, same reason/replacement as the Debug
          // Dashboard FAB above — this is research tooling that still
          // needs to be reachable in a demonstration release build,
          // not an end-user feature. Positioned top-right, clear of
          // the bottom-corner debug/SOS buttons.
          if (enableResearchTools)
            Align(
              alignment: const Alignment(0.88, -0.85),
              child: FloatingActionButton.small(
                heroTag: 'research_menu_fab',
                backgroundColor: Colors.indigo,
                onPressed: () async {
                  // AUDIT FIX (Phase C4): release this screen's camera
                  // BEFORE pushing — see _releaseCameraForExternalScreen's
                  // doc comment for the real freeze this prevents. The
                  // Vision Model Benchmark screen (reachable from here)
                  // opens its own CameraController on the same hardware
                  // — see ResearchMenuScreen's own doc comment on why
                  // that release/reacquire pair is scoped to ONLY that
                  // one sub-screen's navigation now, not this whole
                  // push (every other Research Menu screen, including
                  // Distance Calibration, needs THIS screen's camera
                  // to keep running, not release it).
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => ResearchMenuScreen(
                        behaviourLearningService: _behaviourLearningService,
                        evaluationService: _evaluationService,
                        emergencyService: _emergencyService,
                        getLiveHazards: () => _currentFrameHazards,
                        onReleaseCameraForExternalScreen: _releaseCameraForExternalScreen,
                        onReacquireCameraAfterExternalScreen: _reacquireCameraAfterExternalScreen,
                        lastExplanation: _lastExplanation,
                      ),
                    ),
                  );
                },
                child: const Icon(
                  Icons.analytics_outlined,
                  color: Colors.white,
                ),
              ),
            ),
          // Milestone 5: SOS button. NOT gated by kDebugMode — this is a
          // real safety feature, not a developer tool, so it must exist
          // in release builds. Tap: start a cancellable countdown. Tap
          // again while counting down: cancel. Long-press: open contact
          // management. Uses only AudioService's existing speak() — no
          // change to the speech architecture.
          Align(
            alignment: const Alignment(-0.88, 0.95),
            child: Semantics(
              button: true,
              label: _emergencyService.isCountdownActive
                  ? "Cancel SOS"
                  : "Send SOS",
              hint: _emergencyService.isCountdownActive
                  ? "Double tap to cancel the emergency alert."
                  : "Double tap to start an emergency alert countdown. Long press to manage emergency contacts.",
              child: GestureDetector(
                onLongPress: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => EmergencyContactsScreen(
                        emergencyService: _emergencyService,
                      ),
                    ),
                  );
                },
                child: FloatingActionButton.small(
                  heroTag: 'sos_fab',
                  backgroundColor: _emergencyService.isCountdownActive
                      ? Colors.orange
                      : Colors.red,
                  onPressed: () async {
                    if (_emergencyService.isCountdownActive) {
                      _emergencyService.cancelCountdown();
                      await _languageService.speak(_audioService, "S O S cancelled.");
                    } else {
                      _emergencyService.startCountdown(
                        type: EmergencyTriggerType.manual,
                        latitude: _lastPosition?.latitude,
                        longitude: _lastPosition?.longitude,
                      );
                      await _languageService.speak(_audioService, 
                        "S O S will be sent in ${EmergencyService.countdownDuration.inSeconds} seconds. Tap again to cancel.",
                      );
                    }
                    if (mounted) setState(() {});
                  },
                  child: Icon(
                    _emergencyService.isCountdownActive
                        ? Icons.close
                        : Icons.sos,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
