import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common/sqlite_api.dart' show DatabaseExecutor;

/// Owns the GTFS SQLite database file and its schema — connection and
/// table/index definitions only. Import logic (`GtfsImportService`)
/// and read queries (`GtfsQueryService`) both depend on this, not on
/// each other, keeping the module's layers separate per Stage 2's
/// requested architecture.
///
/// WHY SQLITE, NOT THE Hive STORE THIS PROJECT USES ELSEWHERE
/// (evaluation records, benchmark results): GTFS querying is
/// inherently relational — "trips for a route," "stop_times for a
/// trip joined against calendar for today's service" — and `stop_times`
/// alone is ~1.36M rows in the bundled Chennai feed. A key-value store
/// has no way to do these joins or range queries efficiently; a real
/// relational engine with indexes does.
class GtfsDatabase {
  static const String _dbFileName = 'gtfs.db';

  /// GTFS schema version, bumped whenever [createSchema] changes in a
  /// way that requires a fresh import (new column, new table). Stored
  /// in the db's own `PRAGMA user_version` so a future app update can
  /// detect a stale on-device database and prompt a re-import, rather
  /// than silently querying against a schema the code no longer
  /// matches.
  static const int schemaVersion = 2;

  /// AUDIT ADD (prepared-database architecture — route-search-latency
  /// investigation): identifies WHICH bundled GTFS data the currently
  /// shipped [preparedDatabaseAssetPath] was built from — bump this
  /// (plain manual string, same convention as [schemaVersion] above)
  /// whenever `tool/prepare_gtfs_database.dart` is re-run against an
  /// updated `assets/gtfs/chennai-unified-gtfs.zip`. Compared against
  /// the on-device copy's sidecar version file by
  /// [installPreparedDatabaseIfNeeded] to decide "reuse" vs "replace"
  /// — see that method's doc comment. Unrelated to [schemaVersion]:
  /// this tracks DATA content, that tracks TABLE/INDEX structure.
  // AUDIT FIX (metro data-completeness phase): bumped from v1 -> v2 —
  // the underlying chennai-unified-gtfs.zip's stops.txt/routes.txt were
  // corrected (44 real CMRL metro station rows + 3 CMRL metro route
  // rows, previously rejected for a source-data column-alignment
  // defect, now import correctly; trips.txt/stop_times.txt untouched,
  // no bus data affected). This bump is what makes an on-device install
  // that already has the OLD prepared database correctly detect the
  // change and replace it, rather than treating "chennai-unified-gtfs-v1"
  // as still current forever.
  //
  // AUDIT FIX (Phase D — transit network/route-quality phase): bumped
  // v2 -> v3 — trips.txt's remaining 96 CMRL rows were ALSO corrected.
  // Root cause independently proven (not guessed): the rows had 5
  // comma-separated fields against the header's declared 4 columns,
  // in the actual order [route_id, service_id, trip_id, direction_id,
  // shape_id] — cross-validated against calendar.txt (service_id),
  // routes.txt (route_id), and stop_times.txt (trip_id appears
  // verbatim with real stop_time rows). Reordered to match the
  // EXISTING unmodified header exactly (trip_id, route_id, service_id,
  // direction_id), dropping the undeclared trailing shape_id field.
  // Every other byte of the feed (stops.txt, routes.txt, stop_times.txt,
  // calendar.txt, shapes.txt, agency.txt, feed_info.txt, and trips.txt's
  // 47047 pre-existing bus rows + 6 unrelated calendar-shaped leaked
  // rows) is untouched — confirmed byte-identical. Chennai Metro
  // (all 3 CMRL lines) now has real, importable TRIPS for the first
  // time — see `GtfsImportReport.hasChennaiMetroData` and
  // `GtfsQueryService.getNearestMetroStation`, both of which were
  // already correctly written to report this honestly either way.
  // AUDIT FIX (live on-device bug, Oct 2026): -v4 adds Southern
  // Railway suburban rail data (763 routes/services, 708 stations,
  // Beach-Tambaram + Avadi-Arakkonam corridors, sourced from CUMTA's
  // public transit data portal via the same ChennaiGTFS project this
  // feed's bus/metro data already came from) merged into the
  // previously bus+metro-only feed. Root cause this fixes: a journey
  // from Chromepet to Pallavaram (adjacent stations on the same
  // suburban rail line) was only ever offered as a 50-63 minute,
  // multi-transfer BUS route looping via a distant Kilambakkam
  // interchange — confirmed on a real device — because the feed had
  // zero rail routes (route_type=2... actually SR's own data uses
  // route_type=1, see routes.txt) for RAPTOR to consider at all. No
  // existing MTC/CMRL IDs collide with SR's (route_id 40000+ range,
  // alpha station codes, `service_NNNNNNN` calendar IDs) — verified
  // directly before merging, not assumed.
  static const String bundledGtfsDataVersion = 'chennai-unified-gtfs-v4';

  /// Gzip-compressed — the raw prepared database is ~142MB (built from
  /// the same ~1.36M-row feed a CSV import produces on-device);
  /// gzipping it for shipping cuts that to ~35MB (~4.2x), decompressed
  /// back to a real `.db` file by [installPreparedDatabaseIfNeeded]
  /// using `dart:io`'s built-in `gzip` codec (zlib, no extra
  /// dependency, works identically on Android/iOS). See
  /// `tool/prepare_gtfs_database.dart`, which writes this file
  /// pre-compressed.
  static const String preparedDatabaseAssetPath = 'assets/gtfs/prepared_chennai_gtfs.db.gz';

  /// AUDIT ADD (route-search-latency investigation, Phase 3 —
  /// precomputed RAPTOR patterns): schema version for the
  /// `raptor_patterns`/`raptor_pattern_schema` tables specifically —
  /// separate from [schemaVersion] (the core GTFS tables, unchanged by
  /// this work) and [bundledGtfsDataVersion] (which GTFS DATA was
  /// imported). This tracks the STRUCTURE of the packed BLOB encoding
  /// (`lib/services/journey/raptor/raptor_pattern_store.dart`) —
  /// bump it whenever that encoding changes (int width, byte order,
  /// added/removed columns). A stale/mismatched version must never be
  /// read as if it matched — see
  /// `raptor_pattern_store.dart#decodePreparedPatterns`'s doc comment
  /// for how a mismatch is detected and safely handled (report +
  /// fallback to the row-by-row `stop_times` path, never a silent
  /// wrong-answer read).
  static const int raptorPatternSchemaVersion = 1;

  Database? _database;

  Future<Database> open() async {
    if (_database != null) return _database!;
    final directory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(directory.path, _dbFileName);
    _database = await openDatabase(
      dbPath,
      version: schemaVersion,
      onCreate: (db, version) => createSchema(db),
      // PERF FIX: schemaVersion 1 -> 2 adds idx_trips_service_id (see
      // createSchema below) — a missing index, not a data/column
      // change, so existing on-device databases just need that one
      // index added, not a full re-import. createSchema is idempotent
      // (every statement is IF NOT EXISTS), so calling it again here
      // is a no-op for everything except the new index.
      onUpgrade: (db, oldVersion, newVersion) => createSchema(db),
    );
    return _database!;
  }

  /// AUDIT ADD (prepared-database architecture — route-search-latency
  /// investigation): copies a REAL, pre-populated SQLite database
  /// (built at DEVELOPMENT time by `tool/prepare_gtfs_database.dart`
  /// from the exact same bundled feed and the exact same
  /// `createSchema`/`GtfsImportService` this app already uses — see
  /// that script's doc comment) into place instead of the on-device
  /// app parsing ~1.36M `stop_times` CSV rows itself, which measured
  /// ~574s on a real device. MUST be called BEFORE [open] — it works
  /// entirely at the file-system level (no `Database`/SQLite
  /// connection open yet), so it can safely replace a stale file
  /// outright.
  ///
  /// NO-OP (returns immediately) when:
  /// - an on-device database already exists AND its sidecar version
  ///   file already matches [bundledGtfsDataVersion] — nothing to do.
  /// - [preparedDatabaseAssetPath] isn't bundled at all (e.g. an
  ///   older build predating this tool) — callers fall back to the
  ///   original CSV-import path in that case; this method changes
  ///   nothing so that fallback behaves exactly as it always did.
  ///
  /// ATOMIC: the prepared bytes are written to a temporary path first
  /// and only `rename()`d into the real location once that write
  /// fully completes — a rename is atomic on the same filesystem, so
  /// a crash/interruption mid-copy can never leave a partially
  /// written file sitting at [_dbFileName]'s real path where it could
  /// be mistaken for a ready database. The version sidecar is written
  /// LAST, after the rename succeeds, so an interrupted copy also
  /// can't leave a stale-but-matching version marker next to a
  /// missing/old database.
  Future<void> installPreparedDatabaseIfNeeded() async {
    // DIAGNOSTIC INSTRUMENTATION (GTFS-path investigation — temporary,
    // not gated behind debugMode, deliberately verbose): traces every
    // decision point in this method so a real device run's logcat
    // shows EXACTLY which path was taken and why, rather than the
    // caller having to infer it from silence. See
    // GtfsDiagnostics.reportPreparedDatabaseState (called separately,
    // after open()) for the deeper on-device validation report.
    // ignore: avoid_print
    print('[GTFS-DIAG] installPreparedDatabaseIfNeeded: checking on-device version marker ...');
    if (await _preparedDatabaseAlreadyUpToDate()) {
      // ignore: avoid_print
      print('[GTFS-DIAG] on-device database already matches bundledGtfsDataVersion="$bundledGtfsDataVersion" — no-op, using existing file.');
      return;
    }
    // ignore: avoid_print
    print('[GTFS-DIAG] on-device database missing or stale — will (re)install from $preparedDatabaseAssetPath');

    final ByteData assetData;
    try {
      assetData = await rootBundle.load(preparedDatabaseAssetPath);
      // ignore: avoid_print
      print('[GTFS-DIAG] prepared asset FOUND: $preparedDatabaseAssetPath (${assetData.lengthInBytes} bytes compressed)');
    } catch (e) {
      // No prepared asset bundled — leave the filesystem exactly as
      // it was; GtfsRepository's existing CSV-import fallback handles
      // this case unchanged.
      // ignore: avoid_print
      print('[GTFS-DIAG] prepared asset NOT FOUND ($preparedDatabaseAssetPath) — error: $e — falling back to CSV import path.');
      return;
    }

    final compressedBytes = assetData.buffer.asUint8List(assetData.offsetInBytes, assetData.lengthInBytes);
    final decompressStopwatch = Stopwatch()..start();
    final List<int> decompressedBytes;
    try {
      decompressedBytes = gzip.decode(compressedBytes);
    } catch (e) {
      // ignore: avoid_print
      print('[GTFS-DIAG] gzip.decode FAILED after ${decompressStopwatch.elapsedMilliseconds}ms: $e — '
          'falling back to CSV import path (compressed asset appears corrupt).');
      return;
    }
    decompressStopwatch.stop();
    // ignore: avoid_print
    print('[GTFS-DIAG] gzip.decode succeeded in ${decompressStopwatch.elapsedMilliseconds}ms: '
        '${decompressedBytes.length} bytes decompressed (${(decompressedBytes.length / (1024 * 1024)).toStringAsFixed(1)}MB)');

    final writeStopwatch = Stopwatch()..start();
    await _installPreparedDatabaseBytes(decompressedBytes, bundledGtfsDataVersion);
    writeStopwatch.stop();
    // ignore: avoid_print
    print('[GTFS-DIAG] prepared database file written + version marker updated in ${writeStopwatch.elapsedMilliseconds}ms');
  }

  Future<bool> _preparedDatabaseAlreadyUpToDate() async {
    final directory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(directory.path, _dbFileName);
    final dbFile = File(dbPath);
    final versionFile = File('$dbPath.version');
    if (await dbFile.exists() && await versionFile.exists()) {
      final onDeviceVersion = await versionFile.readAsString();
      return onDeviceVersion.trim() == bundledGtfsDataVersion;
    }
    return false;
  }

  Future<void> _installPreparedDatabaseBytes(List<int> bytes, String version) async {
    final directory = await getApplicationDocumentsDirectory();
    final dbPath = p.join(directory.path, _dbFileName);
    final versionFile = File('$dbPath.version');

    final tempDbPath = '$dbPath.tmp-${DateTime.now().microsecondsSinceEpoch}';
    final tempDbFile = File(tempDbPath);
    await tempDbFile.writeAsBytes(bytes, flush: true);
    await tempDbFile.rename(dbPath); // atomic — see doc comment above
    await versionFile.writeAsString(version, flush: true);
  }

  /// Test-only: drives the exact same atomic copy-and-version-write
  /// logic as [installPreparedDatabaseIfNeeded] with directly supplied
  /// bytes/version, instead of loading the real bundled asset — lets
  /// tests precisely control "prepared asset content" and "declared
  /// version" (e.g. a tiny fixture DB, or an old version string to
  /// prove a version change triggers replacement) without depending
  /// on the real multi-megabyte production artifact
  /// `tool/prepare_gtfs_database.dart` builds separately.
  @visibleForTesting
  Future<void> installPreparedDatabaseBytesForTest(List<int> bytes, {required String version}) {
    return _installPreparedDatabaseBytes(bytes, version);
  }

  Future<void> close() async {
    await _database?.close();
    _database = null;
  }

  /// DIAGNOSTIC INSTRUMENTATION (GTFS-path investigation — temporary,
  /// on-device validation report). Call AFTER [open] has succeeded.
  /// Answers every question the investigation needs directly, on the
  /// REAL Android SQLite engine (not desktop sqflite_common_ffi):
  /// file exists/size, whether SQLite considers the file structurally
  /// sound (`PRAGMA integrity_check`), which required tables exist,
  /// row counts for the tables that matter for this investigation
  /// (stops/routes/trips — the ones the metro-data fix touched), and
  /// the schema/data version markers. Returns a single formatted
  /// string (not individual getters) so a caller can log it as one
  /// atomic block, easy to find in a real device's logcat.
  Future<String> diagnosticReport() async {
    final buffer = StringBuffer();
    try {
      final directory = await getApplicationDocumentsDirectory();
      final dbPath = p.join(directory.path, _dbFileName);
      final dbFile = File(dbPath);
      final versionFile = File('$dbPath.version');

      final fileExists = await dbFile.exists();
      buffer.writeln('db_file_exists=$fileExists path=$dbPath');
      if (fileExists) {
        final sizeBytes = await dbFile.length();
        buffer.writeln('db_file_size_mb=${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)}');
      }
      final versionExists = await versionFile.exists();
      buffer.writeln('version_marker_exists=$versionExists');
      if (versionExists) {
        buffer.writeln('version_marker_value="${(await versionFile.readAsString()).trim()}" '
            '(expected "$bundledGtfsDataVersion")');
      }

      final db = _database;
      if (db == null) {
        buffer.writeln('database_open=false — cannot run further checks');
        return buffer.toString();
      }
      buffer.writeln('database_open=true');

      try {
        final integrity = await db.rawQuery('PRAGMA integrity_check');
        buffer.writeln('integrity_check="${integrity.first.values.first}"');
      } catch (e) {
        buffer.writeln('integrity_check FAILED: $e');
      }

      try {
        final userVersion = await db.rawQuery('PRAGMA user_version');
        buffer.writeln('schema_user_version=${userVersion.first.values.first} (expected $schemaVersion)');
      } catch (e) {
        buffer.writeln('user_version check FAILED: $e');
      }

      final requiredTables = ['agency', 'stops', 'routes', 'trips', 'stop_times', 'calendar', 'shapes'];
      try {
        final tableRows = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'");
        final tableNames = tableRows.map((r) => r['name'] as String).toSet();
        for (final t in requiredTables) {
          buffer.writeln('table_exists[$t]=${tableNames.contains(t)}');
        }
      } catch (e) {
        buffer.writeln('table existence check FAILED: $e');
      }

      for (final table in ['stops', 'routes', 'trips', 'stop_times']) {
        try {
          final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
          buffer.writeln('row_count[$table]=${rows.first['c']}');
        } catch (e) {
          buffer.writeln('row_count[$table] FAILED: $e');
        }
      }

      try {
        // AUDIT FIX (Southern Railway suburban-rail data merge): was
        // `route_type IN (1,2)` — route_type=2 now means real,
        // unrelated SRR suburban-rail routes (763 of them), not a
        // second metro variant, so this diagnostic line would silently
        // misreport "766 metro routes" to anyone reading the log.
        // Split into two separate, honestly-labeled counts.
        final metroRoutes = await db.rawQuery("SELECT COUNT(*) AS c FROM routes WHERE route_type = 1");
        buffer.writeln('metro_route_count=${metroRoutes.first['c']} (expect 3 if the metro-data fix is active)');
        final railRoutes = await db.rawQuery("SELECT COUNT(*) AS c FROM routes WHERE route_type = 2");
        buffer.writeln('suburban_rail_route_count=${railRoutes.first['c']} (expect 763 if the SRR merge is active)');
      } catch (e) {
        buffer.writeln('metro_route_count check FAILED: $e');
      }
    } catch (e, st) {
      buffer.writeln('diagnosticReport ITSELF FAILED: $e\n$st');
    }
    return buffer.toString();
  }

  /// Creates every GTFS table + index. Idempotent via `IF NOT EXISTS`
  /// so it's also safe to call defensively before a re-import (see
  /// `GtfsImportService.resetAndImport`, which additionally drops
  /// everything first for a clean re-import rather than relying on
  /// idempotency alone).
  /// Takes [DatabaseExecutor], not [Database] — both [Database] and
  /// [Transaction] implement it, so this can run either as a
  /// standalone call (via `open()`'s `onCreate`) or, more importantly,
  /// from INSIDE `GtfsImportService`'s transaction (a `Transaction`,
  /// not a `Database`) so schema drop/recreate participates in the
  /// same atomic import — see that file's doc comment on why this
  /// must stay one transaction.
  Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS agency (
        agency_id TEXT PRIMARY KEY,
        agency_name TEXT NOT NULL,
        agency_url TEXT NOT NULL,
        agency_timezone TEXT NOT NULL,
        agency_lang TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS stops (
        stop_id TEXT PRIMARY KEY,
        stop_name TEXT NOT NULL,
        stop_lat REAL NOT NULL,
        stop_lon REAL NOT NULL,
        location_type INTEGER,
        parent_station TEXT,
        wheelchair_boarding INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS routes (
        route_id TEXT PRIMARY KEY,
        agency_id TEXT,
        route_short_name TEXT,
        route_long_name TEXT,
        route_type INTEGER NOT NULL,
        route_color TEXT,
        route_text_color TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS trips (
        trip_id TEXT PRIMARY KEY,
        route_id TEXT NOT NULL,
        service_id TEXT NOT NULL,
        direction_id INTEGER,
        trip_headsign TEXT,
        shape_id TEXT
      )
    ''');

    // Composite primary key (trip_id, stop_sequence): GTFS defines
    // stop order within a trip by stop_sequence, and the combination
    // is unique per the spec — this also gives us a free, automatic
    // index with trip_id as its leading column, covering "all
    // stop_times for trip X ordered by sequence" without a separate
    // index.
    await db.execute('''
      CREATE TABLE IF NOT EXISTS stop_times (
        trip_id TEXT NOT NULL,
        arrival_time TEXT NOT NULL,
        departure_time TEXT NOT NULL,
        stop_id TEXT NOT NULL,
        stop_sequence INTEGER NOT NULL,
        pickup_type INTEGER,
        drop_off_type INTEGER,
        PRIMARY KEY (trip_id, stop_sequence)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS calendar (
        service_id TEXT PRIMARY KEY,
        monday INTEGER NOT NULL,
        tuesday INTEGER NOT NULL,
        wednesday INTEGER NOT NULL,
        thursday INTEGER NOT NULL,
        friday INTEGER NOT NULL,
        saturday INTEGER NOT NULL,
        sunday INTEGER NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS calendar_dates (
        service_id TEXT NOT NULL,
        date TEXT NOT NULL,
        exception_type INTEGER NOT NULL,
        PRIMARY KEY (service_id, date)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS shapes (
        shape_id TEXT NOT NULL,
        shape_pt_sequence INTEGER NOT NULL,
        shape_pt_lat REAL NOT NULL,
        shape_pt_lon REAL NOT NULL,
        shape_dist_traveled REAL,
        PRIMARY KEY (shape_id, shape_pt_sequence)
      )
    ''');

    // Requested indexes (stop_id, route_id, trip_id) plus one bonus
    // composite index — see doc comment below.
    await db.execute('CREATE INDEX IF NOT EXISTS idx_stop_times_stop_id ON stop_times (stop_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_stop_times_trip_id ON stop_times (trip_id)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_trips_route_id ON trips (route_id)');

    // PERF FIX (schemaVersion 2): GtfsQueryService.getTimetableRows —
    // the query that loads the day's whole active-service timetable
    // for RaptorRouter, run fresh every time GtfsTimetableCache is
    // cold — joins stop_times (1.36M rows) to trips filtered by
    // `t.service_id IN (...)`. Every other column that query touches
    // was already indexed (stop_times.trip_id, trips.route_id) except
    // this one, the actual WHERE-clause filter column, which forced a
    // full scan of `trips` to find the day's active rows before the
    // trip_id index into stop_times could even be used.
    await db.execute('CREATE INDEX IF NOT EXISTS idx_trips_service_id ON trips (service_id)');

    // Bonus: getUpcomingTrips() needs "stop_times at this stop, ordered
    // by time" — a composite index on (stop_id, departure_time) makes
    // that a direct index scan instead of a stop_id-filtered table
    // scan, which matters at 1.36M rows.
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_stop_times_stop_departure ON stop_times (stop_id, departure_time)');
  }

  /// Drops every GTFS table. Used by `GtfsImportService` at the start
  /// of a re-import, wrapped in the SAME transaction as the import
  /// itself (see that file) — so if the import fails partway through,
  /// the whole transaction (drop + recreate + insert) rolls back and
  /// the PREVIOUS data is left exactly as it was, never a half-empty
  /// database.
  Future<void> dropSchema(DatabaseExecutor db) async {
    for (final table in [
      'stop_times',
      'trips',
      'routes',
      'stops',
      'agency',
      'calendar',
      'calendar_dates',
      'shapes',
    ]) {
      await db.execute('DROP TABLE IF EXISTS $table');
    }
  }

  /// AUDIT ADD (route-search-latency investigation, Phase 3 —
  /// precomputed RAPTOR patterns): the ADDITIONAL, OPTIONAL tables
  /// holding a build-time-precomputed, RAPTOR-ready representation of
  /// the whole feed's trip patterns — see
  /// `lib/services/journey/raptor/raptor_pattern_store.dart`'s doc
  /// comment for the full "why": reading these ~thousands of rows at
  /// runtime replaces `GtfsQueryService.getTimetableRows` reading
  /// ~1.36M raw `stop_times` rows through sqflite's platform channel
  /// (measured 20+ minutes on a real device vs ~11s for the identical
  /// work off-channel).
  ///
  /// DELIBERATELY NOT CALLED BY [createSchema]/[open]'s `onCreate`: a
  /// device using the CSV-import fallback path (no prepared-database
  /// asset bundled, or an older build predating this feature) never
  /// gets these tables — `GtfsTimetableLoader.load()` detects their
  /// absence via `GtfsQueryService.getRaptorPatternSchemaInfo()`
  /// returning null and transparently uses the original row-by-row
  /// path, exactly like [installPreparedDatabaseIfNeeded]'s own
  /// no-asset-bundled fallback. Only `tool/prepare_gtfs_database.dart`
  /// (build time) and this investigation's routing-equivalence test
  /// call this method.
  ///
  /// `raptor_patterns`: one row per pattern (a route_id + exact
  /// ordered-stop-sequence — see `GtfsPattern`'s doc comment for why
  /// patterns, not raw route_id), covering EVERY trip in the whole
  /// feed (NOT filtered by service_id/date — that filtering happens in
  /// Dart at read time against the small `service_ids` array, so one
  /// build covers every possible date without needing to predict which
  /// calendar combinations will be active in the future).
  /// `arrival_seconds`/`departure_seconds` are packed little-endian
  /// Int32 arrays (see the store file for the exact byte layout), not
  /// JSON, purely for compactness/decode speed at this row count;
  /// `stop_ids`/`trip_ids`/`service_ids` are JSON arrays (small enough
  /// per pattern that JSON's simplicity/robustness outweighs the
  /// marginal size cost).
  ///
  /// `raptor_pattern_schema`: single-row metadata —
  /// [raptorPatternSchemaVersion] and the pattern count at write time,
  /// checked before ANY `raptor_patterns` row is trusted.
  Future<void> createRaptorPatternSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raptor_patterns (
        pattern_id TEXT PRIMARY KEY,
        route_id TEXT NOT NULL,
        num_stops INTEGER NOT NULL,
        num_trips INTEGER NOT NULL,
        stop_ids TEXT NOT NULL,
        trip_ids TEXT NOT NULL,
        service_ids TEXT NOT NULL,
        arrival_seconds BLOB NOT NULL,
        departure_seconds BLOB NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS raptor_pattern_schema (
        schema_version INTEGER NOT NULL,
        pattern_count INTEGER NOT NULL,
        built_at TEXT NOT NULL
      )
    ''');
  }

  /// Counterpart to [createRaptorPatternSchema] — used by the build
  /// script to guarantee a clean rebuild (drop-then-recreate) rather
  /// than relying on `DELETE FROM` leaving stale autoincrement/rowid
  /// state, matching this file's existing [dropSchema]/[createSchema]
  /// convention for the core GTFS tables.
  Future<void> dropRaptorPatternSchema(DatabaseExecutor db) async {
    await db.execute('DROP TABLE IF EXISTS raptor_patterns');
    await db.execute('DROP TABLE IF EXISTS raptor_pattern_schema');
  }
}
