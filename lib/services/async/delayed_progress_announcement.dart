import 'dart:async';

/// PHASE F2 (silent-GPS-wait fix) — generic, hardware/UI-agnostic
/// helper: runs [action] to completion, invoking [onDelayed] at most
/// ONCE if [action] hasn't completed within [delay]. Deliberately
/// separated from `AudioService`/`LocationService`/`Timer`-in-a-widget
/// so the race behavior itself — the part that's actually easy to get
/// subtly wrong (a late callback firing after the real result already
/// arrived, or firing more than once) — can be unit-tested with real
/// short durations, no platform channel and no fake clock needed.
///
/// Correctness properties this guarantees:
///  - If [action] completes before [delay] elapses, [onDelayed] is
///    NEVER called — `timer.cancel()` runs before the timer could ever
///    fire, and the `resolved` guard is a second, redundant safety net
///    for the case where the timer already queued its callback in the
///    same event-loop tick.
///  - If [action] takes longer than [delay], [onDelayed] fires exactly
///    once, and never again regardless of how much longer [action]
///    continues to run.
///  - [onDelayed] is a synchronous callback (never awaited) — a caller
///    that needs to speak/show something should fire-and-forget that
///    itself (see navigation_screen.dart's real caller), exactly the
///    same non-blocking pattern this app already uses for TTS
///    elsewhere (Phase C3's decoupling).
Future<T> runWithDelayedProgressAnnouncement<T>({
  required Future<T> Function() action,
  required Duration delay,
  required void Function() onDelayed,
}) async {
  bool resolved = false;
  final timer = Timer(delay, () {
    if (!resolved) onDelayed();
  });
  try {
    final result = await action();
    resolved = true;
    return result;
  } finally {
    timer.cancel();
  }
}
