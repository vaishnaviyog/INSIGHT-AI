import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:vaishnavi/services/evaluation_service.dart';
import 'package:vaishnavi/services/metrics/runtime_metrics_collector.dart';

/// EvaluationService.exportVoiceEventsToCsv() calls
/// path_provider's getApplicationDocumentsDirectory(), which normally
/// goes over a platform channel — unavailable in a plain `flutter
/// test` VM process (no real platform/plugin registration happens
/// there). This fake stands in for the real platform implementation,
/// exactly like the actual path_provider_windows/_android/etc.
/// plugins do, just pointed at this test's temp directory.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationDocumentsPath() async => _path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('insight_voice_export_test_');
    Hive.init(tempDir.path);
    RuntimeMetricsCollector.instance.reset();
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempDir.path);
  });

  tearDown(() async {
    RuntimeMetricsCollector.instance.reset();
    await Hive.deleteFromDisk();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('VoiceRecognitionEvent.toCsvRow / csvHeader', () {
    test('row length matches header length', () {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'tamil',
        recognizedText: 'guindy poganum',
        success: true,
        confidence: 0.82,
        latencyMs: 1200,
        retryCount: 0,
      );
      final row = RuntimeMetricsCollector.instance.voiceRecognitionEvents.single.toCsvRow();
      expect(row.length, VoiceRecognitionEvent.csvHeader.length);
    });

    test('a null confidence (failed recognition) renders as an empty cell, not "null"', () {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'english',
        recognizedText: '',
        success: false,
        confidence: null,
        latencyMs: 40000,
        retryCount: 3,
      );
      final row = RuntimeMetricsCollector.instance.voiceRecognitionEvents.single.toCsvRow();
      final confidenceIndex = VoiceRecognitionEvent.csvHeader.indexOf('confidence');
      expect(row[confidenceIndex], '');
      for (final cell in row) {
        expect(cell.toLowerCase(), isNot('null'));
      }
    });
  });

  group('EvaluationService.exportVoiceEventsToCsv', () {
    test('returns null when there are no voice events to export', () async {
      final service = EvaluationService();
      await service.initialize();
      final path = await service.exportVoiceEventsToCsv();
      expect(path, isNull);
      await service.dispose();
    });

    test('writes a real CSV file with the correct header and one row per event, readable back', () async {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'tamil',
        recognizedText: 'guindy poganum',
        success: true,
        confidence: 0.82,
        latencyMs: 1345.6,
        retryCount: 1,
      );
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'english',
        recognizedText: 'central',
        success: true,
        confidence: 0.91,
        latencyMs: 800.0,
        retryCount: 0,
      );

      final service = EvaluationService();
      await service.initialize();
      final path = await service.exportVoiceEventsToCsv();

      expect(path, isNotNull);
      final file = File(path!);
      expect(file.existsSync(), isTrue);

      final lines = await file.readAsLines();
      expect(lines.length, 3); // header + 2 rows
      expect(lines.first.split(','), VoiceRecognitionEvent.csvHeader);
      expect(lines[1], contains('tamil'));
      expect(lines[1], contains('guindy poganum'));
      expect(lines[2], contains('english'));
      expect(lines[2], contains('central'));

      await service.dispose();
    });

    test('recognized text containing a comma is quoted and survives the round trip', () async {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: 'english',
        recognizedText: 'central, please',
        success: true,
        confidence: 0.7,
        latencyMs: 900,
        retryCount: 0,
      );

      final service = EvaluationService();
      await service.initialize();
      final path = await service.exportVoiceEventsToCsv();
      final content = await File(path!).readAsString();

      expect(content, contains('"central, please"'));

      await service.dispose();
    });
  });
}
