import 'package:flutter/material.dart';

import '../../services/ai_recommendation_engine.dart';
import '../../services/behaviour_learning_service.dart';
import '../../services/emergency_service.dart';
import '../../services/evaluation_service.dart';
import '../../models/detected_hazard.dart';
import '../../services/research_aggregation_service.dart';
import '../../services/route_safety_service.dart';
import '../../services/explainable_ai_service.dart';
import 'ai_learning_dashboard_screen.dart';
import 'distance_calibration_screen.dart';
import 'gtfs_validation_screen.dart';
import 'model_benchmark_screen.dart';
import 'research_dashboard_screen.dart';
import 'route_safety_screen.dart';

/// Single entry point to every research/evaluation screen added in
/// this phase. Gated behind kDebugMode at the call site in
/// navigation_screen.dart — this whole area is research tooling, not
/// an end-user feature.
class ResearchMenuScreen extends StatelessWidget {
  final BehaviourLearningService behaviourLearningService;
  final EvaluationService evaluationService;
  final EmergencyService emergencyService;
  final ExplanationResult? lastExplanation;

  /// AUDIT ADD (engineering-hardening phase — distance calibration
  /// tool): the same live-hazards getter NavigationScreen already
  /// maintains for its own preview/overlay (`_currentFrameHazards`),
  /// handed through so `DistanceCalibrationScreen` can read it without
  /// this screen or that one needing any new coupling to
  /// `HazardDetectionService` itself.
  final List<DetectedHazard> Function() getLiveHazards;

  /// AUDIT FIX (engineering-hardening phase — camera-lifecycle
  /// scoping): previously NavigationScreen released its camera before
  /// pushing this ENTIRE screen and reacquired it only after this
  /// whole screen (and everything pushed from it) popped — correct for
  /// "Vision Model Benchmark" (the one sub-screen that opens its own
  /// second `CameraController`), wrong for every other sub-screen here,
  /// which either needs NO camera or — like Distance Calibration —
  /// specifically needs NavigationScreen's own camera to keep running.
  /// These two callbacks are now invoked ONLY around the one push that
  /// actually needs them, below.
  final Future<void> Function() onReleaseCameraForExternalScreen;
  final Future<void> Function() onReacquireCameraAfterExternalScreen;

  const ResearchMenuScreen({
    super.key,
    required this.behaviourLearningService,
    required this.evaluationService,
    required this.emergencyService,
    required this.getLiveHazards,
    required this.onReleaseCameraForExternalScreen,
    required this.onReacquireCameraAfterExternalScreen,
    this.lastExplanation,
  });

  @override
  Widget build(BuildContext context) {
    final aggregation = ResearchAggregationService();
    final recommendationEngine = AIRecommendationEngine();
    final routeSafetyService = RouteSafetyService();

    return Scaffold(
      appBar: AppBar(title: const Text('Research Menu')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.insights),
            title: const Text('AI Learning Dashboard'),
            subtitle: const Text('Phase 2'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (context) => AiLearningDashboardScreen(
                behaviourLearningService: behaviourLearningService,
                evaluationService: evaluationService,
                emergencyService: emergencyService,
                recommendationEngine: recommendationEngine,
                aggregation: aggregation,
                lastExplanation: lastExplanation,
              ),
            )),
          ),
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('Research Dashboard'),
            subtitle: const Text('Phase 5 (includes Session Replay)'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (context) => ResearchDashboardScreen(
                behaviourLearningService: behaviourLearningService,
                evaluationService: evaluationService,
                aggregation: aggregation,
              ),
            )),
          ),
          ListTile(
            leading: const Icon(Icons.map_outlined),
            title: const Text('Route Safety Intelligence'),
            subtitle: const Text('Phase 7'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (context) => RouteSafetyScreen(
                evaluationService: evaluationService,
                routeSafetyService: routeSafetyService,
              ),
            )),
          ),
          ListTile(
            leading: const Icon(Icons.speed_outlined),
            title: const Text('Vision Model Benchmark'),
            subtitle: const Text('Pre-replacement candidate benchmarking — run on each physical device'),
            onTap: () async {
              // AUDIT FIX (engineering-hardening phase): this is the
              // ONLY sub-screen here that opens its own CameraController
              // on the same physical camera NavigationScreen's is
              // already holding — see the class doc comment on
              // onReleaseCameraForExternalScreen. Scoped tightly to just
              // this navigation, not the whole Research Menu.
              await onReleaseCameraForExternalScreen();
              if (!context.mounted) return;
              await Navigator.of(context).push(MaterialPageRoute(
                builder: (context) => const ModelBenchmarkScreen(),
              ));
              await onReacquireCameraAfterExternalScreen();
            },
          ),
          ListTile(
            leading: const Icon(Icons.directions_bus_outlined),
            title: const Text('GTFS Import & Validation'),
            subtitle: const Text('Stage 2 — import bundled Chennai feed, verify every query method'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (context) => const GtfsValidationScreen(),
            )),
          ),
          ListTile(
            leading: const Icon(Icons.straighten_outlined),
            title: const Text('Distance Calibration'),
            subtitle: const Text('Run the real focal-length calibration DistanceEstimationConfig has always needed'),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (context) => DistanceCalibrationScreen(getLiveHazards: getLiveHazards),
            )),
          ),
        ],
      ),
    );
  }
}
