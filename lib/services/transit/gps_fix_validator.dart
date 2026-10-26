import '../gtfs/gtfs_geo_utils.dart';

/// AUDIT ADD (Phase E2 — GPS safety hardening): a pre-filter that sits
/// IN FRONT OF the existing, proven arrival trackers
/// (`TransitProgressTracker`, `FinalWalkingRouteTracker`) — it never
/// touches their two-consecutive-reading hysteresis, which stays
/// exactly as it was. This only decides whether a raw
/// `Geolocator`/`Position` fix is trustworthy enough to be FORWARDED
/// to those trackers at all.
///
/// Prior state (found during the read-only audit): neither tracker's
/// `onLocationUpdate`/`updateLocation` consumes a fix's timestamp,
/// accuracy, or the implied speed since the last fix — a fix could be
/// stale, low-accuracy, or a physically-impossible jump and would
/// still count toward arrival/progress exactly like a genuine one.
/// The two-consecutive-reading hysteresis (already proven, unmodified
/// here) protects against a single BAD-BUT-PLAUSIBLE reading; it does
/// not protect against two consecutive fixes that are individually
/// plausible-looking but collectively describe an impossible jump, or
/// against a stale/degraded fix being trusted just because its
/// coordinates happen to look reasonable.
///
/// PURE / NO HARDWARE DEPENDENCY — same discipline as the trackers
/// this feeds (see `TransitSessionStateMachine`'s own doc comment):
/// takes plain values, returns a plain result, never touches
/// `Geolocator` itself. A short-lived, per-tracking-session instance
/// (create one per `_startTransitProgressTracking`/
/// `_startWalkingRouteTracking` call, not shared across sessions —
/// see call sites in `transit_journey_guide_screen.dart`).
class GpsFixValidator {
  /// A fix's own reported acquisition time older than this is treated
  /// as stale and rejected outright. Chosen relative to the app's own
  /// arrival-radius thresholds (25m final-walking, 60m in-transit): a
  /// rider on a bus (routinely 10+ m/s in Chennai traffic) could have
  /// moved 150m+ in 15 seconds — well past the *smaller* radius — so a
  /// fix reported as older than this can no longer be trusted for an
  /// arrival decision. Fixes typically arrive well under this age;
  /// this is a rejection floor for the tail, not a normal-case gate.
  static const Duration maxFixAge = Duration(seconds: 15);

  /// `Position.accuracy` (meters, Android's 68%-confidence radius)
  /// worse than this is rejected. 100m is not "mediocre" — Chennai
  /// urban-canyon accuracy is commonly 15-50m even in dense areas per
  /// this project's own GPS-noise-simulation test fixtures; 100m
  /// represents a genuinely degraded fix (e.g. a stale/cell-tower-only
  /// estimate), not routine street-level noise. This deliberately does
  /// NOT reject ordinary mediocre-but-usable fixes, per the explicit
  /// instruction not to blindly filter on accuracy.
  static const double maxAcceptableAccuracyMeters = 100.0;

  /// Upper bound on plausible speed BETWEEN TWO ACCEPTED FIXES, in
  /// meters/second. Set high enough to never reject genuine bus/metro
  /// travel (Chennai arterial/highway traffic realistically tops out
  /// well under 30 m/s ≈ 108 km/h; this leaves real headroom above
  /// that) while still catching a genuine GPS teleportation/multipath
  /// spike. This is deliberately much higher than
  /// `CollisionTimeEstimator._maxPlausibleClosingSpeedMetersPerSecond`
  /// (15 m/s) — that bound is for a hazard closing on a PEDESTRIAN;
  /// this one is for the rider's OWN possibly-vehicle-borne movement,
  /// a different physical situation entirely.
  static const double maxPlausibleSpeedMetersPerSecond = 40.0;

  _Fix? _lastAccepted;
  _Fix? _pendingSuspicious;

  /// Feed one raw fix through the validator. [timestamp] and
  /// [accuracyMeters] are optional (nullable, matching
  /// `Position.timestamp`/`Position.accuracy`'s own nullability on
  /// some platforms/mocks) — a fix missing that metadata skips the
  /// corresponding check rather than being rejected for a data gap
  /// that isn't the fix's fault.
  ///
  /// A jump that looks implausible against the last ACCEPTED fix is
  /// not rejected outright — it's held as "pending" and compared
  /// against the NEXT fix. If the next fix corroborates it (a
  /// plausible speed relative to the pending one, not the old
  /// position), both are accepted: this is what makes a genuine fast
  /// bus/metro departure or real GPS-signal recovery (e.g. exiting a
  /// building) pass through instead of being permanently rejected —
  /// only an isolated, uncorroborated spike is filtered out.
  GpsFixValidationResult validate({
    required double latitude,
    required double longitude,
    required DateTime now,
    DateTime? timestamp,
    double? accuracyMeters,
  }) {
    if (timestamp != null) {
      final age = now.difference(timestamp).abs();
      if (age > maxFixAge) {
        return const GpsFixValidationResult(accepted: false, reason: GpsRejectionReason.stale);
      }
    }

    if (accuracyMeters != null && accuracyMeters > maxAcceptableAccuracyMeters) {
      return const GpsFixValidationResult(accepted: false, reason: GpsRejectionReason.poorAccuracy);
    }

    final last = _lastAccepted;
    if (last == null) {
      _lastAccepted = _Fix(latitude, longitude, now);
      _pendingSuspicious = null;
      return const GpsFixValidationResult(accepted: true);
    }

    final impliedSpeed = _impliedSpeedMetersPerSecond(last, latitude, longitude, now);
    if (impliedSpeed <= maxPlausibleSpeedMetersPerSecond) {
      _lastAccepted = _Fix(latitude, longitude, now);
      _pendingSuspicious = null;
      return const GpsFixValidationResult(accepted: true);
    }

    final pending = _pendingSuspicious;
    if (pending != null) {
      final corroborationSpeed = _impliedSpeedMetersPerSecond(pending, latitude, longitude, now);
      if (corroborationSpeed <= maxPlausibleSpeedMetersPerSecond) {
        // Two consecutive fixes agree with EACH OTHER even though both
        // disagree with the older accepted position — treat as a real
        // jump (fast vehicle departure, or genuine GPS recovery), not
        // noise.
        _lastAccepted = _Fix(latitude, longitude, now);
        _pendingSuspicious = null;
        return const GpsFixValidationResult(accepted: true, recoveredFromJump: true);
      }
    }

    _pendingSuspicious = _Fix(latitude, longitude, now);
    return const GpsFixValidationResult(accepted: false, reason: GpsRejectionReason.implausibleMovement);
  }

  double _impliedSpeedMetersPerSecond(_Fix from, double latitude, double longitude, DateTime now) {
    final distance = haversineDistanceMeters(from.lat, from.lon, latitude, longitude);
    final dtSeconds = now.difference(from.at).inMilliseconds / 1000.0;
    if (dtSeconds <= 0) return double.infinity;
    return distance / dtSeconds;
  }
}

class _Fix {
  final double lat;
  final double lon;
  final DateTime at;
  const _Fix(this.lat, this.lon, this.at);
}

enum GpsRejectionReason { stale, poorAccuracy, implausibleMovement }

class GpsFixValidationResult {
  final bool accepted;
  final GpsRejectionReason? reason;

  /// True only when this fix was accepted specifically because it
  /// corroborated a previously-pending suspicious jump — useful for
  /// diagnostics/logging, not required for the accept/reject decision
  /// itself.
  final bool recoveredFromJump;

  const GpsFixValidationResult({required this.accepted, this.reason, this.recoveredFromJump = false});
}
