import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/metrics/runtime_metrics_collector.dart';

void main() {
  // RuntimeMetricsCollector.instance is a process-wide singleton, so
  // every test must start from a clean slate — otherwise an earlier
  // test's events would leak into a later one's assertions.
  setUp(() => RuntimeMetricsCollector.instance.reset());

  group('RuntimeMetricsCollector.recordVoiceRecognitionEvent', () {
    test('a recorded event is retrievable with every field intact', () {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'tamil',
        recognizedText: 'guindy poganum',
        success: true,
        confidence: 0.82,
        latencyMs: 1345.6,
        retryCount: 1,
      );

      final events = RuntimeMetricsCollector.instance.voiceRecognitionEvents;
      expect(events, hasLength(1));
      final event = events.single;
      expect(event.language, 'tamil');
      expect(event.recognizedText, 'guindy poganum');
      expect(event.success, isTrue);
      expect(event.confidence, closeTo(0.82, 0.0001));
      expect(event.latencyMs, closeTo(1345.6, 0.01));
      expect(event.retryCount, 1);
      expect(event.timestamp, isNotNull);
    });

    test('a failed recognition attempt is recorded with success=false and null confidence', () {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'english',
        recognizedText: '',
        success: false,
        confidence: null,
        latencyMs: 40000.0, // timed out
        retryCount: 3,
      );

      final event = RuntimeMetricsCollector.instance.voiceRecognitionEvents.single;
      expect(event.success, isFalse);
      expect(event.confidence, isNull);
      expect(event.recognizedText, isEmpty);
      expect(event.retryCount, 3);
    });

    test('multiple events accumulate in call order', () {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'english',
        recognizedText: 'central',
        success: true,
        confidence: 0.9,
        latencyMs: 800,
        retryCount: 0,
      );
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'hindi',
        recognizedText: 'सेंट्रल',
        success: true,
        confidence: 0.75,
        latencyMs: 950,
        retryCount: 1,
      );

      final events = RuntimeMetricsCollector.instance.voiceRecognitionEvents;
      expect(events, hasLength(2));
      expect(events[0].language, 'english');
      expect(events[1].language, 'hindi');
    });

    test('the returned list is unmodifiable — callers cannot mutate collector state directly', () {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'english',
        recognizedText: 'test',
        success: true,
        confidence: 0.9,
        latencyMs: 100,
        retryCount: 0,
      );
      final events = RuntimeMetricsCollector.instance.voiceRecognitionEvents;
      expect(() => events.clear(), throwsUnsupportedError);
    });

    test('reset() clears all recorded voice recognition events', () {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'english',
        recognizedText: 'test',
        success: true,
        confidence: 0.9,
        latencyMs: 100,
        retryCount: 0,
      );
      expect(RuntimeMetricsCollector.instance.voiceRecognitionEvents, hasLength(1));

      RuntimeMetricsCollector.instance.reset();
      expect(RuntimeMetricsCollector.instance.voiceRecognitionEvents, isEmpty);
    });
  });
}
