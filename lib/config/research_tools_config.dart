/// Single switch controlling whether research/debug tooling (Research
/// Menu, AI Learning Dashboard, Research Dashboard, Route Safety,
/// Vision Model Benchmark, GTFS Validation, and the developer Debug
/// Dashboard) is reachable from the running app.
///
/// REPLACES the previous `kDebugMode` gate on these same entry points.
/// `kDebugMode` is `false` in every release build, which meant this
/// tooling was completely unreachable in a release APK — including
/// for dissertation demonstrations that specifically need a release
/// build WITH this tooling available. This is still a compile-time
/// `const bool`, exactly like `kDebugMode` was, so a gated widget is
/// still never built at all when this is `false` (not just hidden) —
/// only WHICH condition controls that changed, not the mechanism or
/// the "does not exist in a locked-down build" guarantee.
///
/// Set to `false` before shipping a build to end users. Set to `true`
/// for a demonstration/research build that still needs to be a
/// release build (e.g. for performance, or because that's what's
/// being submitted/installed for the demonstration).
const bool enableResearchTools = true;

/// Logs a `[LATENCY] <message>` diagnostic line, gated by
/// [enableResearchTools] — these trace the hazard-detection pipeline
/// stage-by-stage (frame capture through TTS completion) for the kind
/// of on-device latency investigation done earlier this project, and
/// are not meant to print in a build shipped to end users. Centralizing
/// the two dozen individual `print('[LATENCY] ...')` call sites this
/// replaces means they now share one on/off switch with the rest of
/// the research tooling instead of needing to be found and deleted by
/// hand before a release build.
void logLatency(String message) {
  if (enableResearchTools) {
    // ignore: avoid_print
    print('[LATENCY] $message');
  }
}
