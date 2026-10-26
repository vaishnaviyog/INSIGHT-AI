import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/transit/gps_fix_validator.dart';

/// Phase E2 regression coverage. The scenarios below are exactly the
/// ones the phase spec named: one bad fix, two bad fixes, a stale fix,
/// a GPS jump, real (walking) movement, a stationary user, bus-speed
/// movement, metro-speed movement, and a noisy urban-canyon trace.
///
/// Real Chennai coordinates are used throughout (same fixture points
/// used elsewhere in this suite's GPS-noise tests) so distances are
/// realistic, not arbitrary.
void main() {
  // Guindy area, ~ (13.0067, 80.2206) and a point ~1km east.
  const originLat = 13.0067;
  const originLon = 80.2206;
  const oneKmEastLat = 13.0067;
  const oneKmEastLon = 80.2317; // ~1.09km east at this latitude

  group('GpsFixValidator — basic accept/reject', () {
    test('first fix is always accepted (nothing to compare against)', () {
      final v = GpsFixValidator();
      final result = v.validate(latitude: originLat, longitude: originLon, now: DateTime(2026, 1, 1, 9, 0, 0));
      expect(result.accepted, isTrue);
    });

    test('stale fix is rejected', () {
      final v = GpsFixValidator();
      final now = DateTime(2026, 1, 1, 9, 0, 0);
      final result = v.validate(
        latitude: originLat,
        longitude: originLon,
        now: now,
        timestamp: now.subtract(const Duration(seconds: 30)),
      );
      expect(result.accepted, isFalse);
      expect(result.reason, GpsRejectionReason.stale);
    });

    test('a fix within the age threshold is accepted', () {
      final v = GpsFixValidator();
      final now = DateTime(2026, 1, 1, 9, 0, 0);
      final result = v.validate(
        latitude: originLat,
        longitude: originLon,
        now: now,
        timestamp: now.subtract(const Duration(seconds: 5)),
      );
      expect(result.accepted, isTrue);
    });

    test('poor accuracy fix is rejected', () {
      final v = GpsFixValidator();
      final result =
          v.validate(latitude: originLat, longitude: originLon, now: DateTime(2026, 1, 1, 9, 0, 0), accuracyMeters: 250);
      expect(result.accepted, isFalse);
      expect(result.reason, GpsRejectionReason.poorAccuracy);
    });

    test('ordinary mediocre-but-usable accuracy (e.g. urban-canyon 40m) is NOT blindly rejected', () {
      final v = GpsFixValidator();
      final result =
          v.validate(latitude: originLat, longitude: originLon, now: DateTime(2026, 1, 1, 9, 0, 0), accuracyMeters: 40);
      expect(result.accepted, isTrue);
    });

    test('missing timestamp/accuracy metadata does not cause rejection', () {
      final v = GpsFixValidator();
      final result = v.validate(latitude: originLat, longitude: originLon, now: DateTime(2026, 1, 1, 9, 0, 0));
      expect(result.accepted, isTrue);
    });
  });

  group('GpsFixValidator — stationary user', () {
    test('a stationary user across many updates is always accepted', () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      for (int i = 0; i < 20; i++) {
        now = now.add(const Duration(seconds: 5));
        final result = v.validate(latitude: originLat, longitude: originLon, now: now);
        expect(result.accepted, isTrue, reason: 'update $i should be accepted — user has not moved');
      }
    });
  });

  group('GpsFixValidator — real movement (walking, bus, metro)', () {
    test('realistic walking pace (~1.3 m/s) is accepted', () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      var lat = originLat;
      const stepMeters = 6.5; // ~5s of walking at 1.3 m/s
      final result1 = v.validate(latitude: lat, longitude: originLon, now: now);
      expect(result1.accepted, isTrue);
      for (int i = 0; i < 10; i++) {
        now = now.add(const Duration(seconds: 5));
        lat += stepMeters / 111320.0; // ~ meters -> degrees latitude
        final result = v.validate(latitude: lat, longitude: originLon, now: now);
        expect(result.accepted, isTrue, reason: 'walking step $i should be accepted');
      }
    });

    test('realistic bus speed (~12 m/s / 43 km/h) is accepted, not flagged as a jump', () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      var lat = originLat;
      const stepMeters = 60.0; // 12 m/s * 5s
      v.validate(latitude: lat, longitude: originLon, now: now);
      for (int i = 0; i < 10; i++) {
        now = now.add(const Duration(seconds: 5));
        lat += stepMeters / 111320.0;
        final result = v.validate(latitude: lat, longitude: originLon, now: now);
        expect(result.accepted, isTrue, reason: 'bus-speed update $i should be accepted (legitimate vehicle movement)');
      }
    });

    test('realistic metro speed (~20 m/s / 72 km/h) is accepted', () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      var lat = originLat;
      const stepMeters = 100.0; // 20 m/s * 5s
      v.validate(latitude: lat, longitude: originLon, now: now);
      for (int i = 0; i < 10; i++) {
        now = now.add(const Duration(seconds: 5));
        lat += stepMeters / 111320.0;
        final result = v.validate(latitude: lat, longitude: originLon, now: now);
        expect(result.accepted, isTrue, reason: 'metro-speed update $i should be accepted');
      }
    });
  });

  group('GpsFixValidator — GPS jumps', () {
    test('ONE bad fix (isolated jump) is rejected and does not contaminate the trend', () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      final r1 = v.validate(latitude: originLat, longitude: originLon, now: now);
      expect(r1.accepted, isTrue);

      // A ~1km jump in 5 seconds -> ~218 m/s, far beyond any plausible bound.
      now = now.add(const Duration(seconds: 5));
      final r2 = v.validate(latitude: oneKmEastLat, longitude: oneKmEastLon, now: now);
      expect(r2.accepted, isFalse);
      expect(r2.reason, GpsRejectionReason.implausibleMovement);

      // The NEXT fix returns to near the original position at a
      // plausible speed relative to the OLD accepted position — proves
      // the isolated spike did not permanently corrupt tracking.
      now = now.add(const Duration(seconds: 5));
      final r3 = v.validate(latitude: originLat, longitude: originLon + 0.0001, now: now);
      expect(r3.accepted, isTrue, reason: 'tracking should recover cleanly after filtering one bad fix');
    });

    test('TWO consecutive corroborating "bad" fixes are treated as a genuine jump (e.g. GPS recovery / fast departure), not noise',
        () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      v.validate(latitude: originLat, longitude: originLon, now: now);

      // First jump: flagged suspicious, not yet trusted.
      now = now.add(const Duration(seconds: 5));
      final r2 = v.validate(latitude: oneKmEastLat, longitude: oneKmEastLon, now: now);
      expect(r2.accepted, isFalse);

      // Second fix lands NEAR the first jump (consistent with a real,
      // continuing jump — e.g. genuine signal recovery after exiting a
      // building, or a bus that just pulled away fast) — this SHOULD
      // be accepted, not permanently blocked.
      now = now.add(const Duration(seconds: 2));
      final r3 = v.validate(latitude: oneKmEastLat, longitude: oneKmEastLon + 0.0001, now: now);
      expect(r3.accepted, isTrue, reason: 'two corroborating fixes should be trusted as a real jump, not rejected forever');
      expect(r3.recoveredFromJump, isTrue);
    });

    test('a teleportation-style jump followed by more noise (not corroborated) stays rejected', () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      v.validate(latitude: originLat, longitude: originLon, now: now);

      now = now.add(const Duration(seconds: 5));
      final r2 = v.validate(latitude: oneKmEastLat, longitude: oneKmEastLon, now: now);
      expect(r2.accepted, isFalse);

      // Second fix jumps somewhere ELSE entirely, not corroborating the
      // first jump — both are noise, not a real trend.
      now = now.add(const Duration(seconds: 2));
      final r3 = v.validate(latitude: originLat - 0.02, longitude: originLon - 0.02, now: now);
      expect(r3.accepted, isFalse, reason: 'uncorroborated second jump in a different direction should also be rejected');
    });
  });

  group('GpsFixValidator — noisy urban-canyon trace', () {
    test('small jitter around a real walking path is all accepted', () {
      final v = GpsFixValidator();
      var now = DateTime(2026, 1, 1, 9, 0, 0);
      var lat = originLat;
      // Simulates ~5-15m of urban-canyon jitter superimposed on a slow
      // real walk — realistic multipath noise, not a jump.
      const jitters = [3.0, -4.0, 6.0, -2.0, 5.0, -6.0, 2.0, -3.0];
      v.validate(latitude: lat, longitude: originLon, now: now);
      for (final jitterMeters in jitters) {
        now = now.add(const Duration(seconds: 5));
        lat += (6.5 + jitterMeters) / 111320.0;
        final result = v.validate(latitude: lat, longitude: originLon, now: now);
        expect(result.accepted, isTrue, reason: 'ordinary multipath jitter should not be rejected as a jump');
      }
    });
  });
}
