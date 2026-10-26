import 'dart:async';

import 'package:flutter/material.dart';

import '../config/research_tools_config.dart';
import '../models/risk_assessment.dart';
import '../models/user_behaviour_profile.dart';

/// Immutable, transient bundle of live app state for the developer
/// debug dashboard.
///
/// This is deliberately NOT a domain model and is never persisted —
/// it exists only to carry a single moment's worth of display data
/// from [NavigationScreen]'s state into [DebugDashboardScreen] on
/// each poll tick.
class DebugSnapshot {
  final String? detectorSource;
  final String? hazardLabel;
  final double? hazardConfidence;
  final String? distanceBand;
  final double? liveSpeedMetersPerSecond;
  final double? gpsLatitude;
  final double? gpsLongitude;
  final bool cameraStreaming;
  final bool isSpeaking;
  final bool isListening;
  final bool hiveOpen;
  final UserBehaviourProfile? profile;

  /// Milestone 3 addition.
  final RiskAssessment? riskAssessment;

  /// Milestone 5 additions.
  final bool emergencyCountdownActive;
  final int emergencySecondsRemaining;
  final int emergencyContactCount;
  final String? lastEmergencyEventStatus;

  /// Milestone 6 addition.
  final String? currentLanguage;

  /// Per-backend readiness (see [HazardDetectionService.detectorAvailability]) —
  /// e.g. {'coco_tflite': false, 'mlkit_fallback': true} when the COCO
  /// model files haven't been added yet. Lets the debug dashboard
  /// confirm which detector is actually active without waiting for a
  /// real obstacle to walk in front of the camera.
  final Map<String, bool>? detectorAvailability;

  const DebugSnapshot({
    this.detectorSource,
    this.hazardLabel,
    this.hazardConfidence,
    this.distanceBand,
    this.liveSpeedMetersPerSecond,
    this.gpsLatitude,
    this.gpsLongitude,
    required this.cameraStreaming,
    required this.isSpeaking,
    required this.isListening,
    required this.hiveOpen,
    this.profile,
    this.riskAssessment,
    this.emergencyCountdownActive = false,
    this.emergencySecondsRemaining = 0,
    this.emergencyContactCount = 0,
    this.lastEmergencyEventStatus,
    this.currentLanguage,
    this.detectorAvailability,
  });
}

/// Read-only developer debug dashboard for development, testing,
/// demonstrations, and dissertation screenshots.
///
/// NOT FOR RELEASE BUILDS BY DEFAULT — enforced in two independent
/// places (defense in depth):
///  1. Its entry point in `navigation_screen.dart` only renders the
///     button that opens this screen when `enableResearchTools` is
///     true (see `research_tools_config.dart`), so when that flag is
///     false there is no way to reach it.
///  2. This screen also checks `enableResearchTools` itself in
///     [build] and pops immediately if somehow reached while it's
///     false.
/// FIX (Issue 2): both checks were previously `kDebugMode`, which made
/// this screen unreachable in EVERY release build, including a
/// release build specifically prepared for a demonstration that needs
/// it. `enableResearchTools` is a dedicated flag for that purpose —
/// still a compile-time constant, so the "not built at all when
/// disabled" guarantee is unchanged.
///
/// This screen has no side effects: it holds no service references,
/// makes no calls into the app's services, and cannot change any
/// navigation, detection, or speech behavior. It only displays values
/// obtained by repeatedly calling [getSnapshot], which is supplied by
/// `navigation_screen.dart` and reads directly from its own live
/// state — this screen never reaches into services on its own.
class DebugDashboardScreen extends StatefulWidget {
  final DebugSnapshot Function() getSnapshot;

  const DebugDashboardScreen({super.key, required this.getSnapshot});

  @override
  State<DebugDashboardScreen> createState() => _DebugDashboardScreenState();
}

class _DebugDashboardScreenState extends State<DebugDashboardScreen> {
  Timer? _pollTimer;
  late DebugSnapshot _snapshot;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.getSnapshot();
    if (enableResearchTools) {
      _pollTimer = Timer.periodic(const Duration(milliseconds: 750), (_) {
        if (!mounted) return;
        setState(() {
          _snapshot = widget.getSnapshot();
        });
      });
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!enableResearchTools) {
      // Defense in depth — should be unreachable, since the entry
      // point that pushes this screen is itself enableResearchTools-gated.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
      return const Scaffold(
        body: Center(child: Text('Debug dashboard is unavailable in this build.')),
      );
    }

    final profile = _snapshot.profile;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black87,
        title: const Text('Developer Debug Dashboard'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('Detection'),
          _row('Current detector', _snapshot.detectorSource ?? '—'),
          _row('Current detected hazard', _snapshot.hazardLabel ?? 'none'),
          _row(
            'Detection confidence',
            _snapshot.hazardConfidence != null
                ? _snapshot.hazardConfidence!.toStringAsFixed(2)
                : '—',
          ),
          _row('Distance band', _snapshot.distanceBand ?? '—'),
          ...?_snapshot.detectorAvailability?.entries.map(
            (entry) => _row(
              '${entry.key} backend',
              entry.value ? 'Ready' : 'Not available (check assets/ml_models/README.md)',
            ),
          ),
          _sectionHeader('Risk Assessment'),
          _row(
            'Risk score',
            _snapshot.riskAssessment != null
                ? _snapshot.riskAssessment!.overallRiskScore.toStringAsFixed(2)
                : '—',
          ),
          _row('Risk level', _snapshot.riskAssessment?.riskLevel.name ?? '—'),
          _row(
            'Behaviour contribution',
            _snapshot.riskAssessment != null
                ? _snapshot.riskAssessment!.behaviourContribution.toStringAsFixed(2)
                : '—',
          ),
          _row(
            'Environment contribution',
            _snapshot.riskAssessment != null
                ? _snapshot.riskAssessment!.environmentContribution.toStringAsFixed(2)
                : '—',
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              _snapshot.riskAssessment != null
                  ? 'Reason: ${_snapshot.riskAssessment!.explanation}'
                  : 'Reason: —',
              style: const TextStyle(color: Colors.white70, fontStyle: FontStyle.italic),
            ),
          ),
          _sectionHeader('Movement & GPS'),
          _row(
            'Walking speed (live)',
            _snapshot.liveSpeedMetersPerSecond != null
                ? '${_snapshot.liveSpeedMetersPerSecond!.toStringAsFixed(2)} m/s'
                : '—',
          ),
          _row('GPS latitude', _snapshot.gpsLatitude?.toStringAsFixed(6) ?? '—'),
          _row('GPS longitude', _snapshot.gpsLongitude?.toStringAsFixed(6) ?? '—'),
          _sectionHeader('Behaviour Profile'),
          _row(
            'Avg walking speed (profile)',
            profile != null ? '${profile.averageWalkingSpeed.toStringAsFixed(2)} m/s' : '—',
          ),
          _row(
            'Reaction time (avg)',
            profile != null ? '${profile.averageReactionTime.toStringAsFixed(2)} s' : '—',
          ),
          _row('Confidence score', profile != null ? profile.confidenceScore.toStringAsFixed(2) : '—'),
          _row('Navigation sessions', profile?.totalNavigationSessions.toString() ?? '—'),
          _row('Near misses', profile?.nearMisses.toString() ?? '—'),
          _row('Successful avoidances', profile?.successfulObstacleAvoidances.toString() ?? '—'),
          _row('Preferred turn direction', profile?.preferredTurningDirection ?? 'none yet'),
          _row(
            'Route familiarity',
            profile != null ? profile.routeFamiliarityScore.toStringAsFixed(2) : '—',
          ),
          _row(
            'Total distance walked',
            profile != null ? '${profile.totalWalkingDistanceMeters.toStringAsFixed(1)} m' : '—',
          ),
          _row(
            'Visited locations tracked',
            profile?.frequentlyVisitedLocations.length.toString() ?? '—',
          ),
          _sectionHeader('System Status'),
          _row('Hive status', _snapshot.hiveOpen ? 'Open' : 'Closed / not ready'),
          _row('Camera status', _snapshot.cameraStreaming ? 'Streaming' : 'Idle'),
          _row(
            'Speech status',
            _snapshot.isSpeaking
                ? 'Speaking'
                : (_snapshot.isListening ? 'Listening' : 'Idle'),
          ),
          _sectionHeader('Emergency System (Milestone 5)'),
          _row('SOS countdown', _snapshot.emergencyCountdownActive
              ? 'ACTIVE — ${_snapshot.emergencySecondsRemaining}s remaining'
              : 'Idle'),
          _row('Contacts saved', _snapshot.emergencyContactCount.toString()),
          _row('Last event status', _snapshot.lastEmergencyEventStatus ?? 'none yet'),
          _sectionHeader('Language (Milestone 6)'),
          _row('Current language', _snapshot.currentLanguage ?? 'english'),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(
          title,
          style: const TextStyle(
            color: Colors.tealAccent,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
      );

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white70)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
}
