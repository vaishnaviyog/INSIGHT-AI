import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/async/delayed_progress_announcement.dart';

/// Phase F2 regression coverage for the GPS-silent-wait fix's generic
/// race logic. Uses real, short durations (no fake clock / mock
/// needed) — matching this codebase's own established pattern for
/// timing-sensitive pure logic (see collision_time_estimator_test.dart,
/// which also uses real `Future.delayed`).
void main() {
  group('runWithDelayedProgressAnnouncement', () {
    test('a FAST action never triggers the delayed announcement', () async {
      var announced = false;
      final result = await runWithDelayedProgressAnnouncement<String>(
        action: () => Future.delayed(const Duration(milliseconds: 10), () => 'fast-result'),
        delay: const Duration(milliseconds: 80),
        onDelayed: () => announced = true,
      );
      expect(result, 'fast-result');
      // Give any (incorrectly still-pending) timer a chance to fire
      // before asserting it did not.
      await Future.delayed(const Duration(milliseconds: 120));
      expect(announced, isFalse, reason: 'a fast action must cancel the timer, not just race it');
    });

    test('a SLOW action triggers the delayed announcement exactly once', () async {
      var announcedCount = 0;
      final result = await runWithDelayedProgressAnnouncement<String>(
        action: () => Future.delayed(const Duration(milliseconds: 150), () => 'slow-result'),
        delay: const Duration(milliseconds: 30),
        onDelayed: () => announcedCount++,
      );
      expect(result, 'slow-result');
      expect(announcedCount, 1, reason: 'must announce exactly once, never zero, never more than once');
    });

    test('an action that fails still cancels the timer cleanly (no late announcement after failure)', () async {
      var announced = false;
      await expectLater(
        runWithDelayedProgressAnnouncement<String>(
          action: () => Future.delayed(const Duration(milliseconds: 10), () => throw StateError('boom')),
          delay: const Duration(milliseconds: 80),
          onDelayed: () => announced = true,
        ),
        throwsA(isA<StateError>()),
      );
      await Future.delayed(const Duration(milliseconds: 120));
      expect(announced, isFalse, reason: 'a failed-but-fast action must still cancel the timer');
    });

    test('a slow action that later fails still announces once before the failure propagates', () async {
      var announced = false;
      await expectLater(
        runWithDelayedProgressAnnouncement<String>(
          action: () => Future.delayed(const Duration(milliseconds: 150), () => throw StateError('boom')),
          delay: const Duration(milliseconds: 30),
          onDelayed: () => announced = true,
        ),
        throwsA(isA<StateError>()),
      );
      expect(announced, isTrue);
    });

    test('the announcement never fires more than once even for a very slow action', () async {
      var announcedCount = 0;
      await runWithDelayedProgressAnnouncement<int>(
        action: () => Future.delayed(const Duration(milliseconds: 200), () => 42),
        delay: const Duration(milliseconds: 20),
        onDelayed: () => announcedCount++,
      );
      expect(announcedCount, 1);
    });
  });
}
