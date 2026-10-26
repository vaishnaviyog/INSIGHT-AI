import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import '../models/evaluation_record.dart';
import '../models/user_behaviour_profile.dart';
import 'metrics/runtime_metrics_collector.dart';

/// Automatically logs one research-evaluation record per detected
/// hazard episode (detection → warning-spoken → user-response) and
/// exports the full log as CSV or JSON.
///
/// SCOPE BOUNDARY (explicit, per instruction): this module exists
/// ONLY for scientific evaluation. It never alters navigation, speech,
/// detection, or risk/guidance decisions — every method here is
/// either a passive read (of values already computed elsewhere and
/// passed in) or a write to this module's own Hive box. Integration
/// points in `navigation_screen.dart` call these methods immediately
/// alongside existing logic, without changing any existing branch,
/// condition, or spoken output.
///
/// LIFECYCLE: mirrors the "single pending item, filled in over time"
/// pattern already used by BehaviourLearningService for warning→
/// reaction correlation — [beginRecord] opens a record when a hazard
/// is detected, [markWarningSpoken] fills in the warning timestamp if
/// AdaptiveGuidanceService decided to actually speak, and
/// [completeRecord] fills in the response timestamp and persists the
/// finished record. A hazard superseded by a new detection before
/// clearing, or a session that ends first, still gets persisted via
/// [endSession] — no data is silently dropped.
class EvaluationService {
  static const String _boxName = 'evaluation_records_box';
  static const String _metaBoxName = 'evaluation_meta_box';
  static const String _lastExportPathKey = 'lastExportPath';
  static const String _lastExportTimeKey = 'lastExportTime';
  static const String _lastExportFormatKey = 'lastExportFormat';

  late Box _box;
  late Box _metaBox;
  bool _initialized = false;

  String? _currentSessionId;
  EvaluationRecord? _pendingRecord;

  /// AUDIT ADD (P0-6): serializes actual Hive writes so overlapping
  /// beginRecord/completeRecord/endSession calls can never interleave
  /// on the box itself, WITHOUT making any of those calls block on
  /// disk I/O — each just chains onto this and returns. See
  /// [_enqueuePersist].
  Future<void> _writeQueue = Future<void>.value();

  /// AUDIT FIX (P0-6 follow-up — recordId collision): appended to
  /// every generated [EvaluationRecord.recordId] alongside the
  /// timestamp. `DateTime.now().microsecondsSinceEpoch` looks
  /// microsecond-precise but isn't actually guaranteed to be — on some
  /// platforms the underlying clock resolution is coarser (e.g.
  /// low-single-digit milliseconds), so several [beginRecord] calls
  /// fired in rapid, near-simultaneous succession (exactly the P0-6
  /// "rapid overlapping episodes" scenario this service exists to
  /// handle) can generate the SAME recordId. Since [_persist] uses
  /// recordId as the Hive box key, a collision meant a later record
  /// silently overwrote an earlier, still-unrelated one — losing data
  /// without any error. A monotonically increasing in-process counter
  /// makes every recordId unique regardless of clock resolution.
  int _recordSequence = 0;

  bool get isInitialized => _initialized;
  String? get currentSessionId => _currentSessionId;

  Future<void> initialize() async {
    _box = await Hive.openBox(_boxName);
    _metaBox = await Hive.openBox(_metaBoxName);
    _initialized = true;
  }

  /// Call once per navigation session (alongside
  /// BehaviourLearningService.startSession()) to tag every record
  /// from this session with a shared ID.
  void startSession() {
    _currentSessionId = DateTime.now().millisecondsSinceEpoch.toString();
  }

  /// Call once per navigation session end. Persists any still-pending
  /// record (with a null clearance timestamp — a legitimate "session
  /// ended before the hazard cleared" data point) rather than
  /// discarding it. AWAITS the write (unlike beginRecord/
  /// completeRecord) — session shutdown is exactly the moment P0-6
  /// asked to make race-safe against a write still in flight.
  Future<void> endSession() async {
    // AUDIT FIX (P0-6): read-and-clear happens in one synchronous
    // step (no `await` in between) — see beginRecord's doc comment
    // for why that specific ordering is what actually eliminates the
    // race, not just moving the persist into a queue.
    final toPersist = _pendingRecord;
    _pendingRecord = null;
    _currentSessionId = null;
    if (toPersist != null) {
      await _enqueuePersist(toPersist);
    } else {
      // Nothing of THIS session's to persist, but a previous
      // beginRecord's fire-and-forget persist (or a previous
      // completeRecord's) may still be in flight — wait for the
      // queue to drain so a caller that awaits endSession() can rely
      // on "every record from this session is safely on disk" being
      // true when this returns.
      await _writeQueue;
    }
  }

  /// Opens a new record for a freshly detected hazard. If a previous
  /// record was still pending (superseded before it cleared), it's
  /// queued for persistence as-is first — nothing is overwritten
  /// silently.
  ///
  /// AUDIT FIX (P0-6 — evaluation-record race): this used to `await
  /// _persist(_pendingRecord!)` BEFORE overwriting `_pendingRecord`
  /// with the new episode. Since navigation_screen.dart calls
  /// beginRecord() without awaiting it, a second hazard episode's
  /// beginRecord() call could start while that await was still
  /// in-flight and see the SAME still-non-null `_pendingRecord`,
  /// racing to overwrite it — the loser's episode was silently
  /// dropped rather than persisted. The fix: read the old pending
  /// record and assign the new one in one synchronous step (no
  /// `await` anywhere in between — Dart is single-threaded, so a
  /// synchronous block can never be interleaved with another async
  /// call), THEN queue the old record's persistence separately. Any
  /// overlapping beginRecord() call now either runs its whole
  /// synchronous block before this one starts, or after — never
  /// interleaved with it.
  Future<void> beginRecord({
    required String objectType,
    required double detectionConfidence,
    required String detectorSource,
    required double riskScore,
    required String riskLevel,
    String language = 'english',
    double? processingLatencyMs,
    double? boundingBoxLeft,
    double? boundingBoxTop,
    double? boundingBoxWidth,
    double? boundingBoxHeight,
    double? estimatedDistanceMeters,
  }) async {
    if (!_initialized || _currentSessionId == null) return;

    final toPersist = _pendingRecord;
    _pendingRecord = EvaluationRecord(
      recordId: '${_currentSessionId}_${DateTime.now().microsecondsSinceEpoch}_${_recordSequence++}',
      sessionId: _currentSessionId!,
      detectionTimestamp: DateTime.now(),
      objectType: objectType,
      detectionConfidence: detectionConfidence,
      detectorSource: detectorSource,
      riskScore: riskScore,
      riskLevel: riskLevel,
      behaviourProfileSummary: '',
      language: language,
      adaptiveGuidanceMode: 'unknown',
      emergencyEventCount: 0,
      processingLatencyMs: processingLatencyMs,
      boundingBoxLeft: boundingBoxLeft,
      boundingBoxTop: boundingBoxTop,
      boundingBoxWidth: boundingBoxWidth,
      boundingBoxHeight: boundingBoxHeight,
      estimatedDistanceMeters: estimatedDistanceMeters,
    );

    if (toPersist != null) {
      // Fire-and-forget from THIS call's point of view — the safety/
      // guidance path must never block on disk I/O — but still
      // strictly ordered relative to every other queued write via
      // _enqueuePersist. Not awaited here by design.
      unawaited(_enqueuePersist(toPersist));
    }
  }

  /// Call immediately after a warning is actually spoken (only when
  /// AdaptiveGuidanceService's decision led to real speech). Also
  /// records which guidance mode produced it.
  void markWarningSpoken({String? adaptiveGuidanceMode}) {
    if (_pendingRecord == null) return;
    _pendingRecord = _pendingRecord!.copyWith(
      voiceWarningTimestamp: DateTime.now(),
      adaptiveGuidanceMode: adaptiveGuidanceMode,
    );
  }

  /// Call when the pending hazard clears (the same moment
  /// BehaviourLearningService.recordObstacleCleared() is called).
  /// Fills in the clearance timestamp and context, clears the pending
  /// slot synchronously, then queues the finished record for
  /// persistence (see beginRecord's doc comment for why the
  /// synchronous-clear-before-persist ordering matters). NOTE: this
  /// records when the hazard stopped being detected, not a confirmed
  /// human response — see EvaluationRecord.hazardClearanceTimestamp's
  /// doc comment.
  Future<void> completeRecord({
    double? walkingSpeedMetersPerSecond,
    double? gpsLatitude,
    double? gpsLongitude,
    UserBehaviourProfile? profile,
    int emergencyEventCount = 0,
  }) async {
    if (_pendingRecord == null) return;

    final finished = _pendingRecord!.copyWith(
      hazardClearanceTimestamp: DateTime.now(),
      walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond,
      gpsLatitude: gpsLatitude,
      gpsLongitude: gpsLongitude,
      routeFamiliarityScore: profile?.routeFamiliarityScore,
      behaviourProfileSummary: _summarize(profile),
      emergencyEventCount: emergencyEventCount,
    );
    // AUDIT FIX (P0-6): clear the pending slot synchronously BEFORE
    // queuing the persist — previously this order was reversed
    // (`await _persist(finished)` THEN `_pendingRecord = null`),
    // which left `_pendingRecord` still non-null (pointing at the
    // episode already being completed) for the whole duration of that
    // await. An unawaited beginRecord() call for the NEXT episode
    // arriving during that window would see the stale non-null
    // `_pendingRecord`, believe it still needed persisting, and queue
    // a SECOND, duplicate persist of the same already-completing
    // record.
    _pendingRecord = null;
    unawaited(_enqueuePersist(finished));
  }

  String _summarize(UserBehaviourProfile? profile) {
    if (profile == null) return 'no_profile_data';
    return 'sessions=${profile.totalNavigationSessions};'
        'avg_speed=${profile.averageWalkingSpeed.toStringAsFixed(2)};'
        // Field name kept as averageReactionTime (see
        // UserBehaviourProfile's doc comment on why — Hive persistence
        // compatibility) but summarized honestly here as a clearance-
        // latency proxy, per the same P0-5 fix as EvaluationRecord.
        'avg_clearance_latency=${profile.averageReactionTime.toStringAsFixed(2)};'
        'confidence=${profile.confidenceScore.toStringAsFixed(2)};'
        'near_misses=${profile.nearMisses};'
        'avoidances=${profile.successfulObstacleAvoidances};'
        'familiarity=${profile.routeFamiliarityScore.toStringAsFixed(2)}';
  }

  /// AUDIT ADD (P0-6): the ONLY path that actually writes to
  /// [_box]. Chains onto [_writeQueue] so writes are strictly
  /// FIFO-ordered no matter how many callers queue one concurrently,
  /// and — critically — the returned/stored Future NEVER completes
  /// with an error (a failed [_persist] is caught and logged inside
  /// this method), so one failed write can never cause every
  /// subsequently-queued write to be silently skipped (which is what
  /// would happen if a rejected Future were left in the chain: a
  /// `.then()` callback never runs after a rejection it doesn't
  /// itself catch).
  Future<void> _enqueuePersist(EvaluationRecord record) {
    final queued = _writeQueue.then((_) async {
      try {
        await _persist(record);
      } catch (e) {
        // ignore: avoid_print
        print('EvaluationService: queued persist failed for record ${record.recordId}: $e');
      }
    });
    _writeQueue = queued;
    return queued;
  }

  Future<void> _persist(EvaluationRecord record) async {
    if (!_initialized) return;
    await _box.put(record.recordId, record.toMap());
  }

  /// All persisted records, oldest first.
  List<EvaluationRecord> get allRecords {
    if (!_initialized) return [];
    final records = _box.values
        .map((v) => EvaluationRecord.fromMap(Map<dynamic, dynamic>.from(v as Map)))
        .toList();
    records.sort((a, b) => a.detectionTimestamp.compareTo(b.detectionTimestamp));
    return records;
  }

  /// Records grouped by session ID, preserving chronological order —
  /// used by the Session Replay screen (Phase 6) and Evaluation
  /// History (Phase 5).
  Map<String, List<EvaluationRecord>> get recordsBySession {
    final grouped = <String, List<EvaluationRecord>>{};
    for (final record in allRecords) {
      grouped.putIfAbsent(record.sessionId, () => []).add(record);
    }
    return grouped;
  }

  String? get lastExportPath => _initialized ? _metaBox.get(_lastExportPathKey) as String? : null;
  DateTime? get lastExportTime {
    if (!_initialized) return null;
    final stored = _metaBox.get(_lastExportTimeKey) as String?;
    return stored != null ? DateTime.parse(stored) : null;
  }

  String? get lastExportFormat =>
      _initialized ? _metaBox.get(_lastExportFormatKey) as String? : null;

  Future<void> _recordExportStatus(String path, String format) async {
    if (!_initialized) return;
    await _metaBox.put(_lastExportPathKey, path);
    await _metaBox.put(_lastExportTimeKey, DateTime.now().toIso8601String());
    await _metaBox.put(_lastExportFormatKey, format);
  }

  /// Writes every persisted record to a CSV file in the app's
  /// documents directory and returns the file path, or null if there
  /// was nothing to export or writing failed.
  ///
  /// Output format is deliberately plain (ISO 8601 timestamps, decimal
  /// numbers, no thousands separators) so it loads directly in
  /// pandas.read_csv, R's read.csv, or Excel without any cleanup step.
  Future<String?> exportToCsv() async {
    final records = allRecords;
    if (records.isEmpty) return null;

    final buffer = StringBuffer();
    buffer.writeln(EvaluationRecord.csvHeader.map(EvaluationRecord.csvEscape).join(','));
    for (final record in records) {
      buffer.writeln(record.toCsvRow().map(EvaluationRecord.csvEscape).join(','));
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filename = 'insight_evaluation_${DateTime.now().millisecondsSinceEpoch}.csv';
      final file = File('${directory.path}/$filename');
      await file.writeAsString(buffer.toString());
      await _recordExportStatus(file.path, 'csv');
      return file.path;
    } catch (e) {
      // ignore: avoid_print
      print('EvaluationService: CSV export failed: $e');
      return null;
    }
  }

  /// AUDIT ADD (P1-10): writes every voice-recognition event collected
  /// this process lifetime (see [RuntimeMetricsCollector.voiceRecognitionEvents])
  /// to its OWN CSV file — kept separate from [exportToCsv]'s hazard-
  /// episode records rather than bolted onto that schema, since a
  /// voice event and a hazard episode are different kinds of rows with
  /// no natural shared key. Same plain-CSV design (ISO 8601 timestamps,
  /// decimals, no thousands separators) for the same pandas/R/Excel
  /// reasons as [exportToCsv]. Returns null if there's nothing to
  /// export or writing failed — same contract as [exportToCsv].
  Future<String?> exportVoiceEventsToCsv() async {
    final events = RuntimeMetricsCollector.instance.voiceRecognitionEvents;
    if (events.isEmpty) return null;

    final buffer = StringBuffer();
    buffer.writeln(VoiceRecognitionEvent.csvHeader.map(EvaluationRecord.csvEscape).join(','));
    for (final event in events) {
      buffer.writeln(event.toCsvRow().map(EvaluationRecord.csvEscape).join(','));
    }

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filename = 'insight_voice_events_${DateTime.now().millisecondsSinceEpoch}.csv';
      final file = File('${directory.path}/$filename');
      await file.writeAsString(buffer.toString());
      await _recordExportStatus(file.path, 'voice_events_csv');
      return file.path;
    } catch (e) {
      // ignore: avoid_print
      print('EvaluationService: voice-events CSV export failed: $e');
      return null;
    }
  }

  /// Writes every persisted record to a JSON file (a JSON array of
  /// objects, one per record, using the same field names as
  /// [EvaluationRecord.toMap]) and returns the file path, or null if
  /// there was nothing to export or writing failed.
  Future<String?> exportToJson() async {
    final records = allRecords;
    if (records.isEmpty) return null;

    try {
      final directory = await getApplicationDocumentsDirectory();
      final filename = 'insight_evaluation_${DateTime.now().millisecondsSinceEpoch}.json';
      final file = File('${directory.path}/$filename');
      final jsonList = records.map((r) => r.toMap()).toList();
      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(jsonList));
      await _recordExportStatus(file.path, 'json');
      return file.path;
    } catch (e) {
      // ignore: avoid_print
      print('EvaluationService: JSON export failed: $e');
      return null;
    }
  }

  /// AUDIT FIX (P0-6/P0-7): the pending record is cleared synchronously
  /// (matching beginRecord/completeRecord's fix above), AND — this is
  /// the part the old version missed entirely — every previously
  /// QUEUED write (from an unawaited beginRecord/completeRecord call
  /// still in flight via [_writeQueue]) is now awaited before the Hive
  /// boxes close. Previously `dispose()` only awaited persisting
  /// whatever was in `_pendingRecord` at that exact moment; any write
  /// already queued but not yet flushed could still be running when
  /// `_box.close()` ran underneath it.
  Future<void> dispose() async {
    final toPersist = _pendingRecord;
    _pendingRecord = null;
    if (toPersist != null) {
      await _enqueuePersist(toPersist);
    } else {
      await _writeQueue;
    }
    if (_initialized) {
      await _box.close();
      await _metaBox.close();
    }
  }
}
