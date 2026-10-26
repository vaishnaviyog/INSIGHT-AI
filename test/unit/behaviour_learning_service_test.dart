import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:vaishnavi/services/behaviour_learning_service.dart';

/// AUDIT ADD (patent-strengthening pass — Core B test-coverage gap):
/// `BehaviourLearningService` is one of the two mechanisms this
/// project's own prior-art audit identified as the genuinely novel
/// differentiators (the event-driven reaction-time/clearance-latency
/// measurement — see `_onObstacleWarningIssued`/`_onObstacleCleared`'s
/// own doc comments) — yet before this file, it had NO direct unit
/// test coverage at all. `metrics_report_service_ground_truth_test.dart`
/// constructs a real instance but never exercises this service's own
/// arithmetic (reaction-time running average, near-miss detection,
/// confidence scoring, implausible-sample filtering).
///
/// Uses real Hive against a temp directory (the same pattern already
/// established by `metrics_report_service_ground_truth_test.dart` and
/// `evaluation_service_race_test.dart`), and controlled synthetic
/// timestamps (via the `timestamp` parameter added to
/// `recordObstacleWarningIssued`/`recordObstacleCleared` alongside
/// this file) rather than real wall-clock delays — precise and fast,
/// not slow and approximate.
void main() {
  late Directory tempDir;
  late BehaviourLearningService service;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('insight_behaviour_learning_test_');
    Hive.init(tempDir.path);
    service = BehaviourLearningService();
    await service.initialize();
  });

  tearDown(() async {
    await service.dispose();
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('Initial state', () {
    test('a fresh profile starts at the documented neutral defaults', () {
      final p = service.profile!;
      expect(p.averageReactionTime, 0.0);
      expect(p.reactionSampleCount, 0);
      expect(p.confidenceScore, 0.5);
      expect(p.successfulObstacleAvoidances, 0);
      expect(p.nearMisses, 0);
    });
  });

  group('Core B — event-driven reaction-time (clearance-latency) measurement', () {
    test(
        'a warning followed by clearance 1.5s later records exactly that as the reaction time, one sample, one avoidance',
        () {
      final warningTime = DateTime(2026, 1, 1, 12, 0, 0);
      final clearedTime = warningTime.add(const Duration(milliseconds: 1500));

      service.recordObstacleWarningIssued('car', 'near', timestamp: warningTime);
      service.recordObstacleCleared(timestamp: clearedTime);

      final p = service.profile!;
      expect(p.averageReactionTime, closeTo(1.5, 0.0001));
      expect(p.reactionSampleCount, 1);
      expect(p.successfulObstacleAvoidances, 1);
    });

    test('the running average correctly blends multiple real reaction samples, not just the most recent one', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);

      // Sample 1: 1.0s
      service.recordObstacleWarningIssued('car', 'near', timestamp: t0);
      service.recordObstacleCleared(timestamp: t0.add(const Duration(seconds: 1)));

      // Sample 2: 3.0s
      final t1 = t0.add(const Duration(minutes: 1));
      service.recordObstacleWarningIssued('pole', 'medium', timestamp: t1);
      service.recordObstacleCleared(timestamp: t1.add(const Duration(seconds: 3)));

      // Sample 3: 2.0s
      final t2 = t1.add(const Duration(minutes: 1));
      service.recordObstacleWarningIssued('person', 'near', timestamp: t2);
      service.recordObstacleCleared(timestamp: t2.add(const Duration(seconds: 2)));

      final p = service.profile!;
      expect(p.reactionSampleCount, 3);
      // Running average of 1.0, 3.0, 2.0 = 2.0 exactly.
      expect(p.averageReactionTime, closeTo(2.0, 0.0001));
      expect(p.successfulObstacleAvoidances, 3);
    });

    test('confidence score increases by exactly 0.02 per successful avoidance and clamps at 1.0', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      expect(service.profile!.confidenceScore, 0.5);

      service.recordObstacleWarningIssued('car', 'near', timestamp: t0);
      service.recordObstacleCleared(timestamp: t0.add(const Duration(seconds: 1)));
      expect(service.profile!.confidenceScore, closeTo(0.52, 0.0001));

      // Drive it to the clamp: (1.0 - 0.5) / 0.02 = 25 more successful avoidances reaches 1.0 exactly.
      for (int i = 0; i < 30; i++) {
        final t = t0.add(Duration(minutes: i + 1));
        service.recordObstacleWarningIssued('car', 'near', timestamp: t);
        service.recordObstacleCleared(timestamp: t.add(const Duration(seconds: 1)));
      }
      expect(service.profile!.confidenceScore, 1.0, reason: 'must clamp at 1.0, never exceed it');
    });

    test('a clearance with NO preceding warning is a no-op — nothing to correlate it with', () {
      service.recordObstacleCleared(timestamp: DateTime(2026, 1, 1, 12, 0, 0));

      final p = service.profile!;
      expect(p.reactionSampleCount, 0);
      expect(p.averageReactionTime, 0.0);
      expect(p.successfulObstacleAvoidances, 0);
    });

    test('a SECOND warning before the first clears does not double-count — only the pending one is correlated', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      service.recordObstacleWarningIssued('car', 'near', timestamp: t0);
      // A second warning overwrites the pending correlation point (matches
      // the real single-hazard-at-a-time assumption documented on
      // _pendingWarningTime — this is not a multi-hazard tracker).
      final t1 = t0.add(const Duration(seconds: 1));
      service.recordObstacleWarningIssued('car', 'near', timestamp: t1);
      service.recordObstacleCleared(timestamp: t1.add(const Duration(seconds: 1)));

      final p = service.profile!;
      expect(p.reactionSampleCount, 1);
      expect(p.averageReactionTime, closeTo(1.0, 0.0001),
          reason: 'must correlate against the SECOND (most recent) warning time, not the first');
    });

    test('a zero-duration or negative clearance latency (clock/ordering anomaly) is excluded, not recorded as zero', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      service.recordObstacleWarningIssued('car', 'near', timestamp: t0);
      // Cleared at the EXACT same instant as the warning — not a genuine
      // measured reaction, should be excluded per the `> 0` bound.
      service.recordObstacleCleared(timestamp: t0);

      final p = service.profile!;
      expect(p.reactionSampleCount, 0);
      expect(p.successfulObstacleAvoidances, 0);
      expect(p.confidenceScore, 0.5, reason: 'no reward for a non-genuine zero-latency sample');
    });
  });

  group('Core B — near-miss detection', () {
    test('a warning issued at "veryNear" distance is counted as a near miss immediately, before any clearance', () {
      service.recordObstacleWarningIssued('car', 'veryNear', timestamp: DateTime(2026, 1, 1, 12, 0, 0));
      expect(service.profile!.nearMisses, 1);
    });

    test('a warning at any OTHER distance band is not counted as a near miss', () {
      for (final band in ['near', 'medium', 'far']) {
        service.recordObstacleWarningIssued('car', band, timestamp: DateTime(2026, 1, 1, 12, 0, 0));
      }
      expect(service.profile!.nearMisses, 0);
    });

    test('near-miss counting and reaction-time counting are independent — a veryNear warning that clears '
        'normally counts as BOTH a near miss AND a successful avoidance', () {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      service.recordObstacleWarningIssued('car', 'veryNear', timestamp: t0);
      service.recordObstacleCleared(timestamp: t0.add(const Duration(seconds: 1)));

      final p = service.profile!;
      expect(p.nearMisses, 1);
      expect(p.successfulObstacleAvoidances, 1);
    });
  });

  group('Persistence — Core B data survives a real Hive round-trip', () {
    test('reaction-time and near-miss data written by one service instance is read back correctly by a fresh one',
        () async {
      final t0 = DateTime(2026, 1, 1, 12, 0, 0);
      service.recordObstacleWarningIssued('car', 'veryNear', timestamp: t0);
      service.recordObstacleCleared(timestamp: t0.add(const Duration(seconds: 2)));
      await service.dispose(); // forces the final persist to complete before the box closes

      final reopened = BehaviourLearningService();
      await reopened.initialize();
      final p = reopened.profile!;
      expect(p.averageReactionTime, closeTo(2.0, 0.0001));
      expect(p.reactionSampleCount, 1);
      expect(p.nearMisses, 1);
      expect(p.successfulObstacleAvoidances, 1);
      await reopened.dispose();
      // Outer tearDown calls `service.dispose()` again on the original
      // (already-disposed-above) instance — Hive's `Box.close()` is
      // idempotent (safe to call on an already-closed box), so this is
      // harmless, not a double-close error.
    });
  });

  group('Fail-soft contract', () {
    test('recording events before initialize() completes does not throw', () {
      // A genuinely UN-initialized instance — deliberately never
      // calling initialize()/dispose() on it, so it never touches the
      // 'behaviour_profile_box' Hive box the outer setUp/tearDown's
      // `service` already has open (Hive caches boxes globally by
      // name, not per-instance — opening/closing a second instance of
      // the SAME name here would race with the outer one's lifecycle).
      // `_applyEvent`'s `if (!_initialized) return;` guard means these
      // calls never reach Hive at all pre-initialization, so this is a
      // real, complete test of the fail-soft guarantee without needing
      // to open a second box.
      final fresh = BehaviourLearningService();
      expect(() => fresh.recordObstacleWarningIssued('car', 'near'), returnsNormally);
      expect(() => fresh.recordObstacleCleared(), returnsNormally);
      expect(() => fresh.recordTurn('left'), returnsNormally);
    });
  });
}
