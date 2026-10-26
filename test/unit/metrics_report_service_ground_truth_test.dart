import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:vaishnavi/services/behaviour_learning_service.dart';
import 'package:vaishnavi/services/evaluation_service.dart';
import 'package:vaishnavi/services/metrics/metrics_report_service.dart';
import 'package:vaishnavi/services/metrics/navigation_metrics_tracker.dart';
import 'package:vaishnavi/services/metrics/runtime_metrics_collector.dart';

/// P1-9 regression test: real EvaluationService/BehaviourLearningService/
/// NavigationMetricsTracker against a temp-directory Hive instance (same
/// proven pattern as evaluation_service_race_test.dart) — this exercises
/// MetricsReportService.computeReport for real, not a re-implementation
/// of its logic.
void main() {
  late Directory tempDir;
  late EvaluationService evaluationService;
  late BehaviourLearningService behaviourLearningService;
  late NavigationMetricsTracker navigationMetricsTracker;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('insight_metrics_test_');
    Hive.init(tempDir.path);
    RuntimeMetricsCollector.instance.reset();

    evaluationService = EvaluationService();
    await evaluationService.initialize();
    evaluationService.startSession();

    behaviourLearningService = BehaviourLearningService();
    await behaviourLearningService.initialize();

    navigationMetricsTracker = NavigationMetricsTracker();
    await navigationMetricsTracker.initialize();
  });

  tearDown(() async {
    await evaluationService.dispose();
    await behaviourLearningService.dispose();
    RuntimeMetricsCollector.instance.reset();
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  MetricEntry _entry(MetricsReport report, String name) =>
      report.entries.firstWhere((e) => e.category == 'Object Detection' && e.name == name);

  group('MetricsReportService — P1-9 ground-truth-only object detection metrics', () {
    test('without ANY ground truth annotations, every detection-accuracy metric is unavailable (null)', () async {
      // Populate plenty of behavioral signal (warnings, clearances)
      // that the OLD proxy code would have turned into fake TP/FP —
      // deliberately, to prove the fix doesn't fall back to it.
      await evaluationService.beginRecord(
        objectType: 'car',
        detectionConfidence: 0.9,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.8,
        riskLevel: 'high',
      );
      evaluationService.markWarningSpoken(adaptiveGuidanceMode: 'standard/normal');
      await evaluationService.completeRecord();
      await evaluationService.endSession();

      final report = MetricsReportService.instance.computeReport(
        evaluationService: evaluationService,
        behaviourLearningService: behaviourLearningService,
        navigationMetricsTracker: navigationMetricsTracker,
      );

      for (final name in ['Precision', 'Recall', 'F1 Score', 'Accuracy', 'True Positives', 'False Positives', 'True Negatives', 'False Negatives']) {
        final entry = _entry(report, name);
        expect(entry.value, isNull, reason: '$name must be null without ground truth');
        expect(entry.sampleSize, 0);
        expect(entry.notes.toLowerCase(), contains('ground-truth'));
      }
    });

    test('WITH real ground-truth annotations, TP/FP/TN/FN/Precision/Recall/F1/Accuracy are computed correctly', () {
      // 2 true positives, 1 false positive, 1 false negative, 1 true negative.
      RuntimeMetricsCollector.instance.recordGroundTruthAnnotation(hazardActuallyPresent: true, hazardWasDetected: true);
      RuntimeMetricsCollector.instance.recordGroundTruthAnnotation(hazardActuallyPresent: true, hazardWasDetected: true);
      RuntimeMetricsCollector.instance.recordGroundTruthAnnotation(hazardActuallyPresent: false, hazardWasDetected: true);
      RuntimeMetricsCollector.instance.recordGroundTruthAnnotation(hazardActuallyPresent: true, hazardWasDetected: false);
      RuntimeMetricsCollector.instance.recordGroundTruthAnnotation(hazardActuallyPresent: false, hazardWasDetected: false);

      final report = MetricsReportService.instance.computeReport(
        evaluationService: evaluationService,
        behaviourLearningService: behaviourLearningService,
        navigationMetricsTracker: navigationMetricsTracker,
      );

      expect(_entry(report, 'True Positives').value, 2.0);
      expect(_entry(report, 'False Positives').value, 1.0);
      expect(_entry(report, 'True Negatives').value, 1.0);
      expect(_entry(report, 'False Negatives').value, 1.0);
      // precision = TP/(TP+FP) = 2/3
      expect(_entry(report, 'Precision').value, closeTo(2 / 3, 0.0001));
      // recall = TP/(TP+FN) = 2/3
      expect(_entry(report, 'Recall').value, closeTo(2 / 3, 0.0001));
      // accuracy = (TP+TN)/total = 3/5
      expect(_entry(report, 'Accuracy').value, closeTo(3 / 5, 0.0001));
      for (final name in ['Precision', 'Recall', 'F1 Score', 'Accuracy', 'True Positives', 'False Positives']) {
        expect(_entry(report, name).notes, contains('ground-truth annotations'));
      }
    });

    test('behavioral proxies (warning count, empty-detection frames) remain available and are labeled as proxies, not accuracy', () async {
      await evaluationService.beginRecord(
        objectType: 'car',
        detectionConfidence: 0.9,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.8,
        riskLevel: 'high',
      );
      evaluationService.markWarningSpoken(adaptiveGuidanceMode: 'standard/normal');
      await evaluationService.completeRecord();
      await evaluationService.endSession();
      RuntimeMetricsCollector.instance.recordEmptyDetectionFrame();
      RuntimeMetricsCollector.instance.recordEmptyDetectionFrame();

      final report = MetricsReportService.instance.computeReport(
        evaluationService: evaluationService,
        behaviourLearningService: behaviourLearningService,
        navigationMetricsTracker: navigationMetricsTracker,
      );

      final warningsIssued = report.entries.firstWhere((e) => e.category == 'Safety' && e.name == 'Warnings Issued');
      expect(warningsIssued.value, 1.0);

      final emptyFrames = report.entries.firstWhere((e) => e.category == 'Safety' && e.name == 'Empty Detection Frames');
      expect(emptyFrames.value, 2.0);
      expect(emptyFrames.notes, contains('NOT used as a True Negative proxy'));

      final clearanceRate =
          report.entries.firstWhere((e) => e.category == 'Safety' && e.name.contains('Clearance Rate'));
      expect(clearanceRate.notes.toUpperCase(), contains('BEHAVIORAL PROXY'));
      expect(clearanceRate.notes.toUpperCase(), contains('NOT'));
    });
  });
}
