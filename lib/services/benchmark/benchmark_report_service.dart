import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../../models/benchmark_result.dart';

/// Persists every [ModelBenchmarkResult] from every benchmark session
/// (not just the most recent one) and exports the full history as
/// CSV — mirrors `EvaluationService`'s own persistence/export pattern
/// for consistency with the rest of this codebase's research tooling.
///
/// WHY KEEP HISTORY ACROSS SESSIONS, UNLIKE A SIMPLE "LAST RUN"
/// SNAPSHOT: since this app needs to work broadly across many
/// devices, one person's single test run on one phone is not enough
/// to decide anything — the CSV is designed to be collected from
/// several different physical devices/testers, then combined
/// (e.g. concatenated, or loaded together in pandas) before drawing
/// any conclusion about which candidate to promote.
class BenchmarkReportService {
  static const String _boxName = 'model_benchmark_results_box';

  late Box _box;
  bool _initialized = false;

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    _initialized = true;
  }

  Future<void> record(ModelBenchmarkResult result) async {
    if (!_initialized) return;
    final key = '${result.timestamp.microsecondsSinceEpoch}_${result.modelName}_${result.delegate.name}';
    await _box.put(key, result.toMap());
  }

  List<Map<String, dynamic>> get allResultRows {
    if (!_initialized) return [];
    return _box.values.map((v) => Map<String, dynamic>.from(v as Map)).toList()
      ..sort((a, b) => (a['timestamp'] as String).compareTo(b['timestamp'] as String));
  }

  /// Same rows as [allResultRows], parsed back into
  /// [ModelBenchmarkResult] objects — used by
  /// `BenchmarkComparisonService` so it works with the same typed
  /// model the benchmark runner itself produces, rather than raw
  /// string maps.
  List<ModelBenchmarkResult> get allResults =>
      allResultRows.map((row) => ModelBenchmarkResult.fromMap(row)).toList();

  /// Writes every persisted result (across all sessions this device
  /// has ever run) to a CSV file and returns the path, or null if
  /// there's nothing to export yet.
  Future<String?> exportToCsv() async {
    final rows = allResultRows;
    if (rows.isEmpty) return null;

    final buffer = StringBuffer();
    buffer.writeln(ModelBenchmarkResult.csvHeader.map(_csvEscape).join(','));
    for (final row in rows) {
      buffer.writeln(ModelBenchmarkResult.csvHeader.map((h) => _csvEscape(row[h] as String? ?? '')).join(','));
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filename = 'insight_model_benchmark_${DateTime.now().millisecondsSinceEpoch}.csv';
      final file = File('${directory.path}/$filename');
      await file.writeAsString(buffer.toString());
      return file.path;
    } catch (e) {
      // ignore: avoid_print
      print('BenchmarkReportService: CSV export failed: $e');
      return null;
    }
  }

  String _csvEscape(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  Future<void> dispose() async {
    if (_initialized) {
      await _box.close();
    }
  }
}
