import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/models/evaluation_record.dart';

EvaluationRecord _record({
  String recordId = 'rec_1',
  String sessionId = 'sess_1',
  DateTime? detectionTimestamp,
  String objectType = 'car',
  double detectionConfidence = 0.87,
  String detectorSource = 'yolov8n_tflite',
  double riskScore = 0.62,
  String riskLevel = 'high',
  DateTime? voiceWarningTimestamp,
  DateTime? hazardClearanceTimestamp,
  double? walkingSpeedMetersPerSecond,
  double? gpsLatitude,
  double? gpsLongitude,
  double? routeFamiliarityScore,
  String behaviourProfileSummary = 'cautious',
  String language = 'english',
  String adaptiveGuidanceMode = 'standard/normal',
  int emergencyEventCount = 0,
  double? processingLatencyMs,
  double? boundingBoxLeft,
  double? boundingBoxTop,
  double? boundingBoxWidth,
  double? boundingBoxHeight,
  double? estimatedDistanceMeters,
}) =>
    EvaluationRecord(
      recordId: recordId,
      sessionId: sessionId,
      detectionTimestamp: detectionTimestamp ?? DateTime.utc(2026, 1, 15, 10, 30),
      objectType: objectType,
      detectionConfidence: detectionConfidence,
      detectorSource: detectorSource,
      riskScore: riskScore,
      riskLevel: riskLevel,
      voiceWarningTimestamp: voiceWarningTimestamp,
      hazardClearanceTimestamp: hazardClearanceTimestamp,
      walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond,
      gpsLatitude: gpsLatitude,
      gpsLongitude: gpsLongitude,
      routeFamiliarityScore: routeFamiliarityScore,
      behaviourProfileSummary: behaviourProfileSummary,
      language: language,
      adaptiveGuidanceMode: adaptiveGuidanceMode,
      emergencyEventCount: emergencyEventCount,
      processingLatencyMs: processingLatencyMs,
      boundingBoxLeft: boundingBoxLeft,
      boundingBoxTop: boundingBoxTop,
      boundingBoxWidth: boundingBoxWidth,
      boundingBoxHeight: boundingBoxHeight,
      estimatedDistanceMeters: estimatedDistanceMeters,
    );

/// Minimal, RFC-4180-aware CSV line parser — used ONLY to verify that
/// EvaluationRecord.csvEscape's output can actually be parsed back,
/// without pulling in a CSV package dependency just for this test.
List<String> _parseCsvLine(String line) {
  final fields = <String>[];
  final buffer = StringBuffer();
  bool inQuotes = false;
  for (int i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        buffer.write(c);
      }
    } else {
      if (c == '"') {
        inQuotes = true;
      } else if (c == ',') {
        fields.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(c);
      }
    }
  }
  fields.add(buffer.toString());
  return fields;
}

void main() {
  group('EvaluationRecord — toMap/fromMap round trip', () {
    test('a fully-populated record survives a round trip unchanged', () {
      final original = _record(
        voiceWarningTimestamp: DateTime.utc(2026, 1, 15, 10, 30, 2),
        hazardClearanceTimestamp: DateTime.utc(2026, 1, 15, 10, 30, 3, 500),
        walkingSpeedMetersPerSecond: 1.2,
        gpsLatitude: 13.0067,
        gpsLongitude: 80.2206,
        routeFamiliarityScore: 0.4,
        processingLatencyMs: 87.3,
        boundingBoxLeft: 0.2,
        boundingBoxTop: 0.3,
        boundingBoxWidth: 0.15,
        boundingBoxHeight: 0.25,
        estimatedDistanceMeters: 4.7,
      );
      final restored = EvaluationRecord.fromMap(original.toMap());

      expect(restored.recordId, original.recordId);
      expect(restored.sessionId, original.sessionId);
      expect(restored.detectionTimestamp, original.detectionTimestamp);
      expect(restored.objectType, original.objectType);
      expect(restored.detectionConfidence, original.detectionConfidence);
      expect(restored.riskScore, original.riskScore);
      expect(restored.riskLevel, original.riskLevel);
      expect(restored.voiceWarningTimestamp, original.voiceWarningTimestamp);
      expect(restored.hazardClearanceTimestamp, original.hazardClearanceTimestamp);
      expect(restored.walkingSpeedMetersPerSecond, original.walkingSpeedMetersPerSecond);
      expect(restored.gpsLatitude, original.gpsLatitude);
      expect(restored.gpsLongitude, original.gpsLongitude);
      expect(restored.routeFamiliarityScore, original.routeFamiliarityScore);
      expect(restored.processingLatencyMs, original.processingLatencyMs);
      expect(restored.boundingBoxLeft, original.boundingBoxLeft);
      expect(restored.boundingBoxHeight, original.boundingBoxHeight);
      expect(restored.estimatedDistanceMeters, original.estimatedDistanceMeters);
      expect(restored.hazardClearanceLatencySeconds, closeTo(1.5, 0.001));
    });

    test('a minimal record (all optional fields null) round-trips without throwing', () {
      final original = _record();
      final restored = EvaluationRecord.fromMap(original.toMap());

      expect(restored.voiceWarningTimestamp, isNull);
      expect(restored.hazardClearanceTimestamp, isNull);
      expect(restored.hazardClearanceLatencySeconds, isNull); // needs BOTH timestamps
      expect(restored.walkingSpeedMetersPerSecond, isNull);
      expect(restored.gpsLatitude, isNull);
      expect(restored.boundingBoxLeft, isNull);
      expect(restored.estimatedDistanceMeters, isNull);
    });

    test('hazardClearanceLatencySeconds is null when only ONE of the two timestamps is present', () {
      final warnedOnly = _record(voiceWarningTimestamp: DateTime.utc(2026, 1, 15, 10, 30, 2));
      expect(warnedOnly.hazardClearanceLatencySeconds, isNull);

      final respondedOnly = _record(hazardClearanceTimestamp: DateTime.utc(2026, 1, 15, 10, 30, 3));
      expect(respondedOnly.hazardClearanceLatencySeconds, isNull);
    });
  });

  group('EvaluationRecord — CSV header/row shape', () {
    test('csvHeader and toCsvRow() always have the same column count', () {
      final row = _record().toCsvRow();
      expect(row.length, EvaluationRecord.csvHeader.length);
    });

    test('csvHeader has no duplicate column names', () {
      expect(EvaluationRecord.csvHeader.toSet().length, EvaluationRecord.csvHeader.length);
    });

    test('row values appear in the documented column order (spot-check a few)', () {
      final record = _record(recordId: 'rec_42', objectType: 'bicycle', riskLevel: 'critical');
      final row = record.toCsvRow();
      final header = EvaluationRecord.csvHeader;

      expect(row[header.indexOf('record_id')], 'rec_42');
      expect(row[header.indexOf('object_type')], 'bicycle');
      expect(row[header.indexOf('risk_level')], 'critical');
    });

    test('missing/null optional values render as empty CSV cells, not "null" or NaN text', () {
      final row = _record().toCsvRow();
      final header = EvaluationRecord.csvHeader;
      expect(row[header.indexOf('voice_warning_timestamp')], '');
      expect(row[header.indexOf('hazard_clearance_latency_seconds')], '');
      expect(row[header.indexOf('gps_latitude')], '');
      expect(row[header.indexOf('bounding_box_left')], '');
      expect(row[header.indexOf('estimated_distance_meters')], '');
      for (final cell in row) {
        expect(cell.toLowerCase(), isNot('null'));
        expect(cell.toLowerCase(), isNot('nan'));
      }
    });

    test('numeric fields are formatted with the documented fixed decimal places', () {
      final row = _record(
        detectionConfidence: 0.8654321,
        riskScore: 0.6,
        gpsLatitude: 13.006700123,
      ).toCsvRow();
      final header = EvaluationRecord.csvHeader;
      expect(row[header.indexOf('detection_confidence')], '0.8654');
      expect(row[header.indexOf('risk_score')], '0.6000');
      expect(row[header.indexOf('gps_latitude')], '13.006700');
    });

    test('emergency_event_count is a plain integer string, not a decimal', () {
      final row = _record(emergencyEventCount: 3).toCsvRow();
      final header = EvaluationRecord.csvHeader;
      expect(row[header.indexOf('emergency_event_count')], '3');
    });
  });

  group('EvaluationRecord.csvEscape', () {
    test('a plain field with no special characters is returned unchanged', () {
      expect(EvaluationRecord.csvEscape('car'), 'car');
    });

    test('a field containing a comma is quoted', () {
      expect(EvaluationRecord.csvEscape('cautious, alert'), '"cautious, alert"');
    });

    test('a field containing a double quote is quoted and the quote is doubled', () {
      expect(EvaluationRecord.csvEscape('said "stop"'), '"said ""stop"""');
    });

    test('a field containing a newline is quoted', () {
      expect(EvaluationRecord.csvEscape('line1\nline2'), '"line1\nline2"');
    });
  });

  group('EvaluationRecord — full CSV export round trip (header + one row)', () {
    test('a record with a comma in a free-text field parses back to the exact original value', () {
      final record = _record(behaviourProfileSummary: 'cautious, risk-averse');
      final headerLine = EvaluationRecord.csvHeader.map(EvaluationRecord.csvEscape).join(',');
      final rowLine = record.toCsvRow().map(EvaluationRecord.csvEscape).join(',');

      final parsedHeader = _parseCsvLine(headerLine);
      final parsedRow = _parseCsvLine(rowLine);

      expect(parsedHeader, EvaluationRecord.csvHeader);
      expect(parsedRow.length, EvaluationRecord.csvHeader.length);
      expect(parsedRow[parsedHeader.indexOf('behaviour_profile_summary')], 'cautious, risk-averse');
      expect(parsedRow[parsedHeader.indexOf('object_type')], 'car');
    });

    test('multiple rows preserve their own values independently after export', () {
      final records = [
        _record(recordId: 'a', objectType: 'car', riskScore: 0.9),
        _record(recordId: 'b', objectType: 'bicycle', riskScore: 0.3),
        _record(recordId: 'c', objectType: 'person', riskScore: 0.55),
      ];
      final lines = records.map((r) => r.toCsvRow().map(EvaluationRecord.csvEscape).join(',')).toList();
      final parsedRows = lines.map(_parseCsvLine).toList();
      final header = EvaluationRecord.csvHeader;

      expect(parsedRows[0][header.indexOf('record_id')], 'a');
      expect(parsedRows[1][header.indexOf('record_id')], 'b');
      expect(parsedRows[2][header.indexOf('record_id')], 'c');
      expect(parsedRows[1][header.indexOf('object_type')], 'bicycle');
      expect(parsedRows[2][header.indexOf('risk_score')], '0.5500');
    });
  });
}
