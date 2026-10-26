import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:vaishnavi/services/evaluation_service.dart';

/// P0-6 regression test: exercises the REAL EvaluationService against
/// a REAL (temp-directory) Hive box — not a mock — so this actually
/// verifies the fixed persistence behavior, not a re-implementation of
/// it. Uses `package:hive/hive.dart`'s `Hive.init(path)` directly
/// (not `hive_flutter`'s `initFlutter()`), which needs no Flutter
/// platform channels and therefore runs in a plain `flutter test`
/// process — EvaluationService itself only ever calls
/// `Hive.openBox(...)`, which works identically either way.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('insight_eval_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('EvaluationService — P0-6 rapid overlapping episodes', () {
    test('begin A, begin B (before A settles), mark warning, complete — A and B stay separate and correct', () async {
      final service = EvaluationService();
      await service.initialize();
      service.startSession();

      // Neither beginRecord call is awaited before the next one
      // starts — this is exactly the unawaited-fire-and-forget
      // pattern navigation_screen.dart uses, and exactly the
      // interleaving that used to be able to lose or duplicate a
      // record (see EvaluationService's P0-6 doc comments).
      final beginA = service.beginRecord(
        objectType: 'car',
        detectionConfidence: 0.9,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.7,
        riskLevel: 'high',
      );
      final beginB = service.beginRecord(
        objectType: 'bicycle',
        detectionConfidence: 0.8,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.4,
        riskLevel: 'medium',
      );
      await beginA;
      await beginB;

      // Only B is "current" now — a warning/completion here must
      // attach to B, never to A (which was already superseded and
      // queued for persistence exactly as it was, unwarned/uncleared).
      service.markWarningSpoken(adaptiveGuidanceMode: 'standard/normal');
      await service.completeRecord();

      // Drain every queued write (endSession() awaits _writeQueue —
      // see EvaluationService's doc comment on why this is safe to
      // rely on) before inspecting what actually landed on disk.
      await service.endSession();

      final records = service.allRecords;
      expect(records, hasLength(2), reason: 'Neither episode should be lost or merged into one record');

      final recordA = records.firstWhere((r) => r.objectType == 'car');
      final recordB = records.firstWhere((r) => r.objectType == 'bicycle');

      // A was superseded before it ever got a warning/clearance — it
      // must be persisted AS-IS (both null), not silently dropped,
      // and NOT carrying B's warning/clearance data.
      expect(recordA.voiceWarningTimestamp, isNull);
      expect(recordA.hazardClearanceTimestamp, isNull);

      // B is the one that actually got the warning + completion.
      expect(recordB.voiceWarningTimestamp, isNotNull);
      expect(recordB.hazardClearanceTimestamp, isNotNull);
      expect(recordB.adaptiveGuidanceMode, 'standard/normal');

      await service.dispose();
    });

    test('three rapid begin calls in a row each produce their own correct record', () async {
      final service = EvaluationService();
      await service.initialize();
      service.startSession();

      await service.beginRecord(
        objectType: 'car',
        detectionConfidence: 0.9,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.9,
        riskLevel: 'critical',
      );
      await service.beginRecord(
        objectType: 'truck',
        detectionConfidence: 0.85,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.6,
        riskLevel: 'high',
      );
      await service.beginRecord(
        objectType: 'person',
        detectionConfidence: 0.7,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.3,
        riskLevel: 'medium',
      );
      await service.endSession(); // persists the 3rd (still-pending) one too

      final records = service.allRecords;
      expect(records.map((r) => r.objectType).toSet(), {'car', 'truck', 'person'});
      expect(records, hasLength(3));

      await service.dispose();
    });

    test('dispose() flushes a still-pending record rather than losing it', () async {
      final service = EvaluationService();
      await service.initialize();
      service.startSession();

      await service.beginRecord(
        objectType: 'motorcycle',
        detectionConfidence: 0.8,
        detectorSource: 'yolov8n_tflite',
        riskScore: 0.65,
        riskLevel: 'high',
      );
      // No completeRecord()/endSession() — simulates the app being
      // torn down mid-episode.
      await service.dispose();

      // Re-open the same box to confirm the record actually reached
      // disk before dispose() closed it (this is a fresh
      // EvaluationService instance, so allRecords necessarily reads
      // from Hive, not from any in-memory state).
      final reopened = EvaluationService();
      await reopened.initialize();
      expect(reopened.allRecords.map((r) => r.objectType), contains('motorcycle'));
      await reopened.dispose();
    });
  });
}
