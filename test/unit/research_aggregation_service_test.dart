import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/evaluation_record.dart';
import 'package:vaishnavi/services/research_aggregation_service.dart';

EvaluationRecord _record({
  required DateTime timestamp,
  String objectType = 'car',
  double riskScore = 0.5,
  String riskLevel = 'medium',
  String detectorSource = 'yolov8n_tflite',
  double detectionConfidence = 0.8,
  double? processingLatencyMs,
  DateTime? voiceWarningTimestamp,
  DateTime? hazardClearanceTimestamp,
}) =>
    EvaluationRecord(
      recordId: 'rec_${timestamp.microsecondsSinceEpoch}',
      sessionId: 'sess_1',
      detectionTimestamp: timestamp,
      objectType: objectType,
      detectionConfidence: detectionConfidence,
      detectorSource: detectorSource,
      riskScore: riskScore,
      riskLevel: riskLevel,
      behaviourProfileSummary: 'test',
      language: 'english',
      adaptiveGuidanceMode: 'standard/normal',
      emergencyEventCount: 0,
      processingLatencyMs: processingLatencyMs,
      voiceWarningTimestamp: voiceWarningTimestamp,
      hazardClearanceTimestamp: hazardClearanceTimestamp,
    );

void main() {
  final service = ResearchAggregationService();
  final baseTime = DateTime.utc(2026, 1, 1, 9, 0);

  group('ResearchAggregationService — insufficient-data guards return ResearchStat.insufficient()', () {
    test('averageRiskScore on an empty list is insufficient, not zero', () {
      final result = service.averageRiskScore([]);
      expect(result.hasEnoughData, isFalse);
      expect(result.value, isNull);
    });

    test('riskLevelDistribution requires at least 3 records', () {
      final twoRecords = [
        _record(timestamp: baseTime, riskLevel: 'high'),
        _record(timestamp: baseTime.add(const Duration(seconds: 1)), riskLevel: 'low'),
      ];
      expect(service.riskLevelDistribution(twoRecords).hasEnoughData, isFalse);

      final threeRecords = [...twoRecords, _record(timestamp: baseTime.add(const Duration(seconds: 2)))];
      expect(service.riskLevelDistribution(threeRecords).hasEnoughData, isTrue);
    });

    test('firstVsSecondHalfDelta requires at least 10 records', () {
      final nine = List.generate(
        9,
        (i) => _record(timestamp: baseTime.add(Duration(seconds: i)), processingLatencyMs: 100.0),
      );
      expect(
        service.firstVsSecondHalfDelta(nine, (r) => r.processingLatencyMs).hasEnoughData,
        isFalse,
      );

      final ten = [...nine, _record(timestamp: baseTime.add(const Duration(seconds: 10)), processingLatencyMs: 100.0)];
      expect(
        service.firstVsSecondHalfDelta(ten, (r) => r.processingLatencyMs).hasEnoughData,
        isTrue,
      );
    });

    test('averageProcessingLatencyMs is insufficient when no record has a latency value at all', () {
      final records = [
        _record(timestamp: baseTime),
        _record(timestamp: baseTime.add(const Duration(seconds: 1))),
      ];
      expect(service.averageProcessingLatencyMs(records).hasEnoughData, isFalse);
    });

    test('averageHazardClearanceLatency is insufficient when no record has both timestamps', () {
      final records = [
        _record(timestamp: baseTime, voiceWarningTimestamp: baseTime), // no response
        _record(timestamp: baseTime, hazardClearanceTimestamp: baseTime), // no warning
      ];
      expect(service.averageHazardClearanceLatency(records).hasEnoughData, isFalse);
    });
  });

  group('ResearchAggregationService — correctness on real synthetic data', () {
    test('averageRiskScore computes the correct mean', () {
      final records = [
        _record(timestamp: baseTime, riskScore: 0.2),
        _record(timestamp: baseTime.add(const Duration(seconds: 1)), riskScore: 0.4),
        _record(timestamp: baseTime.add(const Duration(seconds: 2)), riskScore: 0.6),
      ];
      final result = service.averageRiskScore(records);
      expect(result.hasEnoughData, isTrue);
      expect(result.value, closeTo(0.4, 0.0001));
    });

    test('highestRiskScore finds the true maximum, not the last record', () {
      final records = [
        _record(timestamp: baseTime, riskScore: 0.3),
        _record(timestamp: baseTime.add(const Duration(seconds: 1)), riskScore: 0.9),
        _record(timestamp: baseTime.add(const Duration(seconds: 2)), riskScore: 0.1),
      ];
      expect(service.highestRiskScore(records).value, closeTo(0.9, 0.0001));
    });

    test('mostDangerousObject picks the object type with the highest average risk score', () {
      final records = [
        _record(timestamp: baseTime, objectType: 'bicycle', riskScore: 0.2),
        _record(timestamp: baseTime.add(const Duration(seconds: 1)), objectType: 'truck', riskScore: 0.9),
        _record(timestamp: baseTime.add(const Duration(seconds: 2)), objectType: 'truck', riskScore: 0.8),
      ];
      expect(service.mostDangerousObject(records).value, 'truck');
    });

    test('detectorUsage counts records per detector source', () {
      final records = [
        _record(timestamp: baseTime, detectorSource: 'yolov8n_tflite'),
        _record(timestamp: baseTime.add(const Duration(seconds: 1)), detectorSource: 'yolov8n_tflite'),
        _record(timestamp: baseTime.add(const Duration(seconds: 2)), detectorSource: 'mlkit_fallback'),
      ];
      final result = service.detectorUsage(records);
      expect(result.value!['yolov8n_tflite'], 2);
      expect(result.value!['mlkit_fallback'], 1);
    });

    test('warningCount only counts records where a warning was actually spoken', () {
      final records = [
        _record(timestamp: baseTime, voiceWarningTimestamp: baseTime),
        _record(timestamp: baseTime.add(const Duration(seconds: 1))), // no warning
        _record(timestamp: baseTime.add(const Duration(seconds: 2)), voiceWarningTimestamp: baseTime),
      ];
      expect(service.warningCount(records), 2);
    });
  });

  group('ResearchAggregationService — before-vs-after personalization aggregation', () {
    test('firstVsSecondHalfDelta reports a negative delta for a real improvement in hazard clearance latency', () {
      // First half (before personalization): slower clearance latencies.
      // Second half (after personalization): faster clearance latencies.
      // Chronological order matters — records must be passed in as
      // they actually occurred.
      final records = <EvaluationRecord>[];
      for (int i = 0; i < 5; i++) {
        records.add(_record(
          timestamp: baseTime.add(Duration(seconds: i)),
          voiceWarningTimestamp: baseTime.add(Duration(seconds: i)),
          hazardClearanceTimestamp: baseTime.add(Duration(seconds: i, milliseconds: 3000)), // 3.0s reaction
        ));
      }
      for (int i = 5; i < 10; i++) {
        records.add(_record(
          timestamp: baseTime.add(Duration(seconds: i)),
          voiceWarningTimestamp: baseTime.add(Duration(seconds: i)),
          hazardClearanceTimestamp: baseTime.add(Duration(seconds: i, milliseconds: 1500)), // 1.5s reaction
        ));
      }

      final result = service.firstVsSecondHalfDelta(records, (r) => r.hazardClearanceLatencySeconds);
      expect(result.hasEnoughData, isTrue);
      // second half average (1.5) - first half average (3.0) = -1.5:
      // a negative delta correctly signals "got faster."
      expect(result.value, closeTo(-1.5, 0.01));
    });
  });
}
