import 'dart:io';

/// A single optional ground-truth annotation. Nothing in the app
/// generates these on its own — they only exist if an external test
/// harness (e.g. a Flutter integration test replaying labeled footage,
/// or a human tester marking a detection as correct/incorrect during
/// a controlled test run) calls
/// [RuntimeMetricsCollector.recordGroundTruthAnnotation]. Without any
/// annotations, object-detection metrics that require ground truth
/// (False Negatives, Accuracy, Recall, F1) are reported as
/// unavailable rather than estimated — see [MetricsReportService].
class GroundTruthAnnotation {
  final bool hazardActuallyPresent;
  final bool hazardWasDetected;

  const GroundTruthAnnotation({
    required this.hazardActuallyPresent,
    required this.hazardWasDetected,
  });
}

/// A single voice-recognition attempt during onboarding (or any other
/// voice interaction that chooses to log one) — added for Phase 1H's
/// evaluation requirement (language, recognized text, success/failure,
/// retry count, latency, confidence). Deliberately reuses this same
/// collector rather than introducing a second, separate voice-specific
/// logging subsystem — this class already exists for exactly this
/// "passively record a value the caller computed" purpose (see
/// [RuntimeMetricsCollector]'s doc comment) and already tracks speech
/// latency for TTS.
class VoiceRecognitionEvent {
  final DateTime timestamp;
  final String language;
  final String recognizedText;
  final bool success;
  final double? confidence;
  final double latencyMs;
  final int retryCount;

  const VoiceRecognitionEvent({
    required this.timestamp,
    required this.language,
    required this.recognizedText,
    required this.success,
    required this.confidence,
    required this.latencyMs,
    required this.retryCount,
  });

  /// AUDIT ADD (P1-10): [RuntimeMetricsCollector] is purely in-memory
  /// and process-lifetime-scoped, so voice-recognition data would
  /// otherwise be lost the moment the app closes — this CSV support
  /// (mirroring `EvaluationRecord.csvHeader`/`toCsvRow`/`csvEscape`'s
  /// established pattern exactly, not a new format) is what lets
  /// [EvaluationService.exportVoiceEventsToCsv] actually get this data
  /// onto disk. Deliberately does NOT store `recognizedText` verbatim
  /// forever without thought — it's plain recognized speech text (a
  /// destination name, a yes/no, a menu choice), never raw audio, per
  /// the explicit "do not store raw audio" requirement.
  static const List<String> csvHeader = [
    'timestamp',
    'language',
    'recognized_text',
    'success',
    'confidence',
    'latency_ms',
    'retry_count',
  ];

  List<String> toCsvRow() => [
        timestamp.toIso8601String(),
        language,
        recognizedText,
        success.toString(),
        confidence?.toStringAsFixed(4) ?? '',
        latencyMs.toStringAsFixed(1),
        retryCount.toString(),
      ];
}

/// Collects lightweight, additive runtime measurements that aren't
/// already captured by [EvaluationService] or [BehaviourLearningService]
/// — camera frame timing, whole-pipeline processing latency, speech
/// latency, memory samples, empty-detection-frame counts, and (only if
/// externally supplied) ground-truth detection annotations.
///
/// SCOPE BOUNDARY, same as EvaluationService: every method here is a
/// passive recording of a value the caller already computed, or a
/// passive read of an already-in-memory list. Nothing here changes
/// any navigation, detection, speech, or guidance decision — call
/// sites add a call to this collector ALONGSIDE their existing logic,
/// never inside a conditional that could alter behavior.
///
/// LIFETIME: this is a process-wide singleton whose sample lists
/// reset per navigation session (see [startSession]/[reset]), matching
/// the same "one session, one evaluation window" concept
/// EvaluationService and NavigationMetricsTracker use.
class RuntimeMetricsCollector {
  RuntimeMetricsCollector._internal();
  static final RuntimeMetricsCollector instance = RuntimeMetricsCollector._internal();

  DateTime? _sessionClockStart;
  DateTime? _sessionClockEnd;

  int _cameraFrameCount = 0;
  int _emptyDetectionFrameCount = 0;

  final List<double> _processingLatencySamplesMs = [];
  final List<double> _speechLatencySamplesMs = [];
  final List<double> _memoryUsageSamplesBytes = [];
  final List<GroundTruthAnnotation> _groundTruthAnnotations = [];
  final List<VoiceRecognitionEvent> _voiceRecognitionEvents = [];

  /// Whether `ProcessInfo.currentRss` has thrown or returned nothing
  /// usable on this platform/run, so memory metrics can be reported as
  /// "not available" rather than a misleading zero.
  bool _memorySamplingSupported = true;

  int get cameraFrameCount => _cameraFrameCount;
  int get emptyDetectionFrameCount => _emptyDetectionFrameCount;
  List<double> get processingLatencySamplesMs => List.unmodifiable(_processingLatencySamplesMs);
  List<double> get speechLatencySamplesMs => List.unmodifiable(_speechLatencySamplesMs);
  List<double> get memoryUsageSamplesBytes => List.unmodifiable(_memoryUsageSamplesBytes);
  List<GroundTruthAnnotation> get groundTruthAnnotations =>
      List.unmodifiable(_groundTruthAnnotations);
  List<VoiceRecognitionEvent> get voiceRecognitionEvents => List.unmodifiable(_voiceRecognitionEvents);
  bool get memorySamplingSupported => _memorySamplingSupported;

  /// Wall-clock duration of the current/most recent session, or null
  /// if a session was never started. Used only for Camera FPS
  /// (frames ÷ elapsed seconds) — never to fabricate a frame count.
  Duration? get sessionWallClockDuration {
    if (_sessionClockStart == null) return null;
    final end = _sessionClockEnd ?? DateTime.now();
    return end.difference(_sessionClockStart!);
  }

  void startSession() {
    reset();
    _sessionClockStart = DateTime.now();
  }

  void endSession() {
    _sessionClockEnd = DateTime.now();
  }

  void recordCameraFrame() {
    _cameraFrameCount++;
  }

  void recordEmptyDetectionFrame() {
    _emptyDetectionFrameCount++;
  }

  void recordProcessingLatencyMs(double milliseconds) {
    _processingLatencySamplesMs.add(milliseconds);
  }

  void recordSpeechLatencyMs(double milliseconds) {
    _speechLatencySamplesMs.add(milliseconds);
  }

  /// Samples current resident memory via `dart:io`'s `ProcessInfo`,
  /// which is the only memory-usage API available without adding a
  /// new plugin dependency. Some platforms/build configurations don't
  /// support it; a thrown exception or a non-positive value is
  /// treated as "unsupported here" rather than recorded as a zero
  /// (which would silently understate memory usage in any average).
  void sampleMemoryUsage() {
    try {
      final rss = ProcessInfo.currentRss;
      if (rss > 0) {
        _memoryUsageSamplesBytes.add(rss.toDouble());
      } else {
        _memorySamplingSupported = false;
      }
    } catch (_) {
      _memorySamplingSupported = false;
    }
  }

  /// Optional hook for a test harness or human tester to supply real
  /// ground truth for a detection episode. NOT called anywhere in the
  /// app's own navigation/detection pipeline — it exists purely so
  /// that, when a labeled test run IS performed, full
  /// Accuracy/Recall/F1/False-Negative figures become computable
  /// instead of reported as unavailable.
  void recordGroundTruthAnnotation({
    required bool hazardActuallyPresent,
    required bool hazardWasDetected,
  }) {
    _groundTruthAnnotations.add(GroundTruthAnnotation(
      hazardActuallyPresent: hazardActuallyPresent,
      hazardWasDetected: hazardWasDetected,
    ));
  }

  void recordVoiceRecognitionEvent({
    required String language,
    required String recognizedText,
    required bool success,
    double? confidence,
    required double latencyMs,
    required int retryCount,
  }) {
    _voiceRecognitionEvents.add(VoiceRecognitionEvent(
      timestamp: DateTime.now(),
      language: language,
      recognizedText: recognizedText,
      success: success,
      confidence: confidence,
      latencyMs: latencyMs,
      retryCount: retryCount,
    ));
  }

  void reset() {
    _sessionClockStart = null;
    _sessionClockEnd = null;
    _cameraFrameCount = 0;
    _emptyDetectionFrameCount = 0;
    _processingLatencySamplesMs.clear();
    _speechLatencySamplesMs.clear();
    _memoryUsageSamplesBytes.clear();
    _groundTruthAnnotations.clear();
    _voiceRecognitionEvents.clear();
    _memorySamplingSupported = true;
  }
}
