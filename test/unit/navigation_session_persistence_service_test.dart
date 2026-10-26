import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:vaishnavi/services/navigation_session_persistence_service.dart';

/// CRITICAL background state persistence fix — regression test.
/// Exercises the REAL service against a REAL (temp-directory) Hive
/// box, same pattern as evaluation_service_race_test.dart — not a
/// mock, not a re-implementation of the save/load logic.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('insight_nav_session_test_');
    Hive.init(tempDir.path);
  });

  tearDown(() async {
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('NavigationSessionPersistenceService', () {
    test('nothing saved -> loadFreshActiveDestination returns null', () async {
      final service = NavigationSessionPersistenceService();
      await service.initialize();

      expect(await service.loadFreshActiveDestination(), isNull);
    });

    test('save then load returns the exact same destination text', () async {
      final service = NavigationSessionPersistenceService();
      await service.initialize();

      await service.saveActiveSession('Tambaram');

      expect(await service.loadFreshActiveDestination(), 'Tambaram');
    });

    test('clearActiveSession removes a previously saved session', () async {
      final service = NavigationSessionPersistenceService();
      await service.initialize();
      await service.saveActiveSession('Tambaram');

      await service.clearActiveSession();

      expect(await service.loadFreshActiveDestination(), isNull);
    });

    test('a fresh save from a NEW service instance is visible (survives "process restart")', () async {
      final writer = NavigationSessionPersistenceService();
      await writer.initialize();
      await writer.saveActiveSession('Chennai Central');
      await writer.dispose();

      // A brand-new instance, exactly like the one HomeScreen creates
      // on a cold start after the OS killed the previous process.
      final reader = NavigationSessionPersistenceService();
      await reader.initialize();

      expect(await reader.loadFreshActiveDestination(), 'Chennai Central');
    });

    test('a stale saved session (older than maxSessionAge) is treated as absent and cleared', () async {
      // Writes directly to the box the same way the service itself
      // does internally, but with a backdated timestamp — the
      // service's own save/load API has no way to fake elapsed time,
      // so this reaches into its known (mirrored) storage keys the
      // same way a real stale on-disk record would look after a real
      // 30+ minute gap.
      final box = await Hive.openBox('navigation_session_box');
      await box.put('destinationText', 'Old Destination');
      await box.put(
        'savedAtIso8601',
        DateTime.now().subtract(const Duration(hours: 2)).toIso8601String(),
      );
      await box.close();

      final service = NavigationSessionPersistenceService();
      await service.initialize();

      expect(await service.loadFreshActiveDestination(), isNull);

      // Also verify the stale entry was actually cleared, not just
      // ignored-but-left-behind.
      final reopened = await Hive.openBox('navigation_session_box');
      expect(reopened.get('destinationText'), isNull);
    });

    test('saving an empty destination is a no-op (never persists garbage)', () async {
      final service = NavigationSessionPersistenceService();
      await service.initialize();

      await service.saveActiveSession('   ');

      expect(await service.loadFreshActiveDestination(), isNull);
    });
  });
}
