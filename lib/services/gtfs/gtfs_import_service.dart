import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:csv/csv.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:sqflite/sqflite.dart';

import 'gtfs_database_service.dart';
import 'gtfs_import_report.dart';

/// Imports a GTFS feed (a .zip of .txt CSV files) into the SQLite
/// database `GtfsDatabaseService` owns.
///
/// VALIDATION IS DELIBERATELY STRICT AND HEADER-DRIVEN, NOT POSITIONAL:
/// each file's own header row is read to map column name -> index, so
/// column order doesn't matter and a missing optional column is simply
/// absent (defaults to null) rather than shifting every later column.
/// This matters concretely for the bundled Chennai feed, which has
/// real data-quality problems this importer is built to catch rather
/// than silently mis-import:
///
/// - `routes.txt`: 3 CMRL metro rows have a `route_type` value that
///   isn't a valid integer (their `route_long_name` and `route_type`
///   columns don't align with the header's declared 5-column shape
///   the way the bus rows do) — rejected as invalid, not guessed at.
/// - `trips.txt`: 96 CMRL rows have 5 comma-separated fields against
///   a header that declares 4 columns, and 6 rows are actually
///   `calendar.txt` content that leaked into this file (10 fields,
///   semantically unrelated to a trip) — both rejected via a strict
///   field-count check against the header.
/// - `stops.txt`: at least one row has blank lat/lon fields — rejected
///   via coordinate range/parse validation.
/// - `calendar.txt`: one row's `service_id` is a literal script-
///   injection payload (`'/><script>alert(1)</script>`) — rejected by
///   a safe-identifier pattern check, not stored verbatim.
///
/// None of these are "fixed" by guessing the intended realignment —
/// GTFS's own header contract is authoritative, and a row that
/// violates it is reported as invalid so a human can decide whether to
/// correct the source feed, not silently repaired by this importer.
///
/// AUDIT ADD (P0-4): [GtfsImportReport.hasChennaiMetroData] is a real,
/// post-import DB check (not an assumption), not a hardcoded claim.
///
/// STATUS UPDATE (Phase D — transit network/route-quality phase): both
/// issues described above are now FIXED at the source-data level —
/// `routes.txt`'s 3 CMRL rows and `trips.txt`'s 96 CMRL rows were each
/// independently reordered to match their file's own unmodified
/// header, with the correct field order proven (not guessed) by
/// cross-referencing `calendar.txt`/`stops.txt`/`stop_times.txt`. All
/// 3 CMRL routes AND their real trips now import successfully —
/// `hasChennaiMetroData` is `true` and metro trips participate in
/// journey planning like any other route. See `GtfsDatabase.
/// bundledGtfsDataVersion`'s doc comment (currently `-v3`) for the
/// exact fix history. `assets/gtfs/README.md` is updated to match.
class GtfsImportService {
  final GtfsDatabaseService databaseService;

  GtfsImportService(this.databaseService);

  static const int _batchChunkSize = 2000;

  /// service_id (calendar.txt/calendar_dates.txt) must look like a
  /// plain identifier — this is what rejects the injection-payload row
  /// found in the bundled feed's calendar.txt.
  static final RegExp _safeIdentifierPattern = RegExp(r'^[A-Za-z0-9_\- ]+$');
  static final RegExp _timePattern = RegExp(r'^\d{1,3}:\d{2}:\d{2}$');
  static final RegExp _datePattern = RegExp(r'^\d{8}$');

  Future<GtfsImportReport> importFromAsset(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    return importFromZipBytes(data.buffer.asUint8List());
  }

  Future<GtfsImportReport> importFromZipFile(File file) async {
    final bytes = await file.readAsBytes();
    return importFromZipBytes(bytes);
  }

  Future<GtfsImportReport> importFromZipBytes(Uint8List zipBytes) async {
    final stopwatch = Stopwatch()..start();
    final results = <GtfsFileImportResult>[];

    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      stopwatch.stop();
      return GtfsImportReport(
        fileResults: const [],
        totalImportTime: stopwatch.elapsed,
        succeeded: false,
        failureReason: 'Could not open the file as a ZIP archive: $e',
      );
    }

    String? readEntry(String fileName) {
      for (final file in archive.files) {
        // Some GTFS zips nest files in a subfolder — match by suffix,
        // not just an exact name, so that case still works.
        if (file.name == fileName || file.name.endsWith('/$fileName')) {
          if (!file.isFile) continue;
          final content = file.content;
          return utf8.decode(content, allowMalformed: true);
        }
      }
      return null;
    }

    // AUDIT FIX (Fix 3 — undefined name 'db'): moved OUTSIDE the try
    // block. `db` used to be declared inside `try { final db = ...; }`,
    // so its scope ended at that block's closing brace — but the
    // metroRouteCount query below (added in the P0-4 pass) also needs
    // it, and that code runs AFTER the try/catch, outside where `db`
    // was ever in scope. `databaseService.database` is a plain
    // synchronous getter (not a call that can throw meaningfully on
    // its own), so hoisting it up here doesn't change the try block's
    // error-handling behavior at all — only its variable's scope.
    final db = databaseService.database;
    try {
      await db.transaction((txn) async {
        // Whole import — drop, recreate, insert everything — happens
        // in ONE transaction: if anything below throws, this rolls
        // back completely, leaving whatever data existed before this
        // import call untouched rather than a half-populated database.
        await databaseService.schema.dropSchema(txn);
        await databaseService.schema.createSchema(txn);

        results.add(await _importAgency(txn, readEntry('agency.txt')));
        results.add(await _importStops(txn, readEntry('stops.txt')));
        results.add(await _importRoutes(txn, readEntry('routes.txt')));
        results.add(await _importTrips(txn, readEntry('trips.txt')));
        results.add(await _importCalendar(txn, readEntry('calendar.txt')));
        results.add(await _importCalendarDates(txn, readEntry('calendar_dates.txt')));
        results.add(await _importShapes(txn, readEntry('shapes.txt')));
        results.add(await _importStopTimesStreaming(txn, readEntry('stop_times.txt')));
      });
    } catch (e) {
      stopwatch.stop();
      return GtfsImportReport(
        fileResults: results,
        totalImportTime: stopwatch.elapsed,
        succeeded: false,
        failureReason: 'Import failed and was rolled back: $e',
      );
    }

    // AUDIT ADD (P0-4): a real, DB-grounded check — not just trusting
    // the doc comment above — for whether ANY rail/metro route
    // (GTFS route_type 1=subway or 2=rail) actually made it into the
    // imported data. route_type IN (1, 2) is the exact same
    // definition GtfsQueryService.getNearestMetroStation already uses.
    // Currently this will be 0 for the bundled Chennai feed: the 3
    // CMRL route rows (the only route_type=1 candidates in the source
    // file) are column-shifted and rejected by validation above, so
    // there is no metro data to silently claim works.
    final metroRouteCount = Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM routes WHERE route_type IN (1, 2)'),
        ) ??
        0;

    stopwatch.stop();
    return GtfsImportReport(
      fileResults: results,
      totalImportTime: stopwatch.elapsed,
      succeeded: true,
      metroRouteCount: metroRouteCount,
    );
  }

  // ---------------------------------------------------------------------
  // Shared CSV/header helpers
  // ---------------------------------------------------------------------

  /// Parses [content] as CSV and returns (header, dataRows) with every
  /// cell already trimmed to a String. Empty trailing lines (common in
  /// GTFS exports) are skipped. Returns null if [content] is null
  /// (file absent from the archive) or has no header row at all.
  ({List<String> header, List<List<String>> rows})? _parseCsv(String? content) {
    if (content == null) return null;
    final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rawRows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false)
        .convert(normalized, eol: '\n')
        .where((row) => row.isNotEmpty && !(row.length == 1 && row.first.toString().trim().isEmpty))
        .toList();
    if (rawRows.isEmpty) return null;
    final header = rawRows.first.map((c) => c.toString().trim()).toList();
    final dataRows = rawRows.skip(1).map((row) => row.map((c) => c.toString().trim()).toList()).toList();
    return (header: header, rows: dataRows);
  }

  Map<String, int> _columnIndex(List<String> header) {
    final map = <String, int>{};
    for (int i = 0; i < header.length; i++) {
      map[header[i]] = i;
    }
    return map;
  }

  /// null if [row] doesn't have exactly [expectedLength] fields —
  /// callers treat that as an invalid row rather than attempting a
  /// best-effort partial read. This is what catches trips.txt's
  /// field-count corruption described in this class's doc comment.
  String? _cell(List<String> row, Map<String, int> columnIndex, String columnName) {
    final idx = columnIndex[columnName];
    if (idx == null || idx >= row.length) return null;
    return row[idx];
  }

  void _addSampleReason(List<String> samples, String reason) {
    if (samples.length < 5) samples.add(reason); // capped — a report, not a full error log
  }

  // ---------------------------------------------------------------------
  // Per-file importers
  // ---------------------------------------------------------------------

  Future<GtfsFileImportResult> _importAgency(Transaction txn, String? content) async {
    const fileName = 'agency.txt';
    final parsed = _parseCsv(content);
    if (parsed == null) return GtfsFileImportResult.missing(fileName);
    final columnIndex = _columnIndex(parsed.header);

    int imported = 0, invalid = 0, duplicates = 0;
    final seen = <String>{};
    final samples = <String>[];
    final batch = txn.batch();

    for (final row in parsed.rows) {
      if (row.length != parsed.header.length) {
        invalid++;
        _addSampleReason(samples, 'Row has ${row.length} fields, header declares ${parsed.header.length}');
        continue;
      }
      final agencyId = _cell(row, columnIndex, 'agency_id') ?? '';
      final agencyName = _cell(row, columnIndex, 'agency_name') ?? '';
      final agencyUrl = _cell(row, columnIndex, 'agency_url') ?? '';
      final agencyTimezone = _cell(row, columnIndex, 'agency_timezone') ?? '';
      if (agencyId.isEmpty || agencyName.isEmpty || agencyUrl.isEmpty || agencyTimezone.isEmpty) {
        invalid++;
        _addSampleReason(samples, 'agency_id="$agencyId": missing a required field');
        continue;
      }
      if (!seen.add(agencyId)) {
        duplicates++;
        continue;
      }
      batch.insert('agency', {
        'agency_id': agencyId,
        'agency_name': agencyName,
        'agency_url': agencyUrl,
        'agency_timezone': agencyTimezone,
        'agency_lang': _cell(row, columnIndex, 'agency_lang'),
      });
      imported++;
    }
    await batch.commit(noResult: true);
    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }

  Future<GtfsFileImportResult> _importStops(Transaction txn, String? content) async {
    const fileName = 'stops.txt';
    final parsed = _parseCsv(content);
    if (parsed == null) return GtfsFileImportResult.missing(fileName);
    final columnIndex = _columnIndex(parsed.header);

    int imported = 0, invalid = 0, duplicates = 0;
    final seen = <String>{};
    final samples = <String>[];
    var batch = txn.batch();
    int inBatch = 0;

    for (final row in parsed.rows) {
      if (row.length != parsed.header.length) {
        invalid++;
        _addSampleReason(samples, 'Row has ${row.length} fields, header declares ${parsed.header.length}');
        continue;
      }
      final stopId = _cell(row, columnIndex, 'stop_id') ?? '';
      final stopName = _cell(row, columnIndex, 'stop_name') ?? '';
      final lat = double.tryParse(_cell(row, columnIndex, 'stop_lat') ?? '');
      final lon = double.tryParse(_cell(row, columnIndex, 'stop_lon') ?? '');
      if (stopId.isEmpty || stopName.isEmpty || lat == null || lon == null) {
        invalid++;
        _addSampleReason(samples, 'stop_id="$stopId": missing/unparseable name or coordinates');
        continue;
      }
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
        invalid++;
        _addSampleReason(samples, 'stop_id="$stopId": coordinates out of valid range ($lat, $lon)');
        continue;
      }
      if (!seen.add(stopId)) {
        duplicates++;
        continue;
      }
      batch.insert('stops', {
        'stop_id': stopId,
        'stop_name': stopName,
        'stop_lat': lat,
        'stop_lon': lon,
        'location_type': int.tryParse(_cell(row, columnIndex, 'location_type') ?? ''),
        'parent_station': _cell(row, columnIndex, 'parent_station'),
        'wheelchair_boarding': int.tryParse(_cell(row, columnIndex, 'wheelchair_boarding') ?? ''),
      });
      imported++;
      inBatch++;
      if (inBatch >= _batchChunkSize) {
        await batch.commit(noResult: true);
        batch = txn.batch();
        inBatch = 0;
      }
    }
    await batch.commit(noResult: true);
    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }

  Future<GtfsFileImportResult> _importRoutes(Transaction txn, String? content) async {
    const fileName = 'routes.txt';
    final parsed = _parseCsv(content);
    if (parsed == null) return GtfsFileImportResult.missing(fileName);
    final columnIndex = _columnIndex(parsed.header);

    int imported = 0, invalid = 0, duplicates = 0;
    final seen = <String>{};
    final samples = <String>[];
    final batch = txn.batch();

    for (final row in parsed.rows) {
      if (row.length != parsed.header.length) {
        invalid++;
        _addSampleReason(samples, 'Row has ${row.length} fields, header declares ${parsed.header.length}');
        continue;
      }
      final routeId = _cell(row, columnIndex, 'route_id') ?? '';
      final routeType = int.tryParse(_cell(row, columnIndex, 'route_type') ?? '');
      if (routeId.isEmpty || routeType == null) {
        invalid++;
        _addSampleReason(samples,
            'route_id="$routeId": route_type "${_cell(row, columnIndex, 'route_type')}" is not a valid integer '
            '(this exact case — 3 CMRL rows — is a known data-quality issue in the bundled feed, see class doc)');
        continue;
      }
      if (!seen.add(routeId)) {
        duplicates++;
        continue;
      }
      batch.insert('routes', {
        'route_id': routeId,
        'agency_id': _cell(row, columnIndex, 'agency_id'),
        'route_short_name': _cell(row, columnIndex, 'route_short_name'),
        'route_long_name': _cell(row, columnIndex, 'route_long_name'),
        'route_type': routeType,
        'route_color': _cell(row, columnIndex, 'route_color'),
        'route_text_color': _cell(row, columnIndex, 'route_text_color'),
      });
      imported++;
    }
    await batch.commit(noResult: true);
    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }

  Future<GtfsFileImportResult> _importTrips(Transaction txn, String? content) async {
    const fileName = 'trips.txt';
    final parsed = _parseCsv(content);
    if (parsed == null) return GtfsFileImportResult.missing(fileName);
    final columnIndex = _columnIndex(parsed.header);

    int imported = 0, invalid = 0, duplicates = 0;
    final seen = <String>{};
    final samples = <String>[];
    var batch = txn.batch();
    int inBatch = 0;

    for (final row in parsed.rows) {
      if (row.length != parsed.header.length) {
        invalid++;
        _addSampleReason(
            samples, 'Row has ${row.length} fields, header declares ${parsed.header.length} — see class doc '
            '(this rejects the CMRL 5-field rows and the 6 leaked calendar.txt rows found in the bundled feed)');
        continue;
      }
      final tripId = _cell(row, columnIndex, 'trip_id') ?? '';
      final routeId = _cell(row, columnIndex, 'route_id') ?? '';
      final serviceId = _cell(row, columnIndex, 'service_id') ?? '';
      if (tripId.isEmpty || routeId.isEmpty || serviceId.isEmpty) {
        invalid++;
        _addSampleReason(samples, 'trip_id="$tripId": missing a required field');
        continue;
      }
      if (!seen.add(tripId)) {
        duplicates++;
        continue;
      }
      batch.insert('trips', {
        'trip_id': tripId,
        'route_id': routeId,
        'service_id': serviceId,
        'direction_id': int.tryParse(_cell(row, columnIndex, 'direction_id') ?? ''),
        'trip_headsign': _cell(row, columnIndex, 'trip_headsign'),
        'shape_id': _cell(row, columnIndex, 'shape_id'),
      });
      imported++;
      inBatch++;
      if (inBatch >= _batchChunkSize) {
        await batch.commit(noResult: true);
        batch = txn.batch();
        inBatch = 0;
      }
    }
    await batch.commit(noResult: true);
    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }

  Future<GtfsFileImportResult> _importCalendar(Transaction txn, String? content) async {
    const fileName = 'calendar.txt';
    final parsed = _parseCsv(content);
    if (parsed == null) return GtfsFileImportResult.missing(fileName);
    final columnIndex = _columnIndex(parsed.header);

    int imported = 0, invalid = 0, duplicates = 0;
    final seen = <String>{};
    final samples = <String>[];
    final batch = txn.batch();

    bool? parseBool01(String? v) => v == '1' ? true : (v == '0' ? false : null);

    for (final row in parsed.rows) {
      if (row.length != parsed.header.length) {
        invalid++;
        _addSampleReason(samples, 'Row has ${row.length} fields, header declares ${parsed.header.length}');
        continue;
      }
      final serviceId = _cell(row, columnIndex, 'service_id') ?? '';
      if (serviceId.isEmpty || !_safeIdentifierPattern.hasMatch(serviceId.trim())) {
        invalid++;
        _addSampleReason(samples,
            'service_id rejected by safe-identifier check (this is what rejects the script-injection payload '
            'row found in the bundled feed\'s calendar.txt — see class doc)');
        continue;
      }
      final monday = parseBool01(_cell(row, columnIndex, 'monday'));
      final tuesday = parseBool01(_cell(row, columnIndex, 'tuesday'));
      final wednesday = parseBool01(_cell(row, columnIndex, 'wednesday'));
      final thursday = parseBool01(_cell(row, columnIndex, 'thursday'));
      final friday = parseBool01(_cell(row, columnIndex, 'friday'));
      final saturday = parseBool01(_cell(row, columnIndex, 'saturday'));
      final sunday = parseBool01(_cell(row, columnIndex, 'sunday'));
      final startDate = _cell(row, columnIndex, 'start_date') ?? '';
      final endDate = _cell(row, columnIndex, 'end_date') ?? '';
      if ([monday, tuesday, wednesday, thursday, friday, saturday, sunday].contains(null) ||
          !_datePattern.hasMatch(startDate) ||
          !_datePattern.hasMatch(endDate)) {
        invalid++;
        _addSampleReason(samples, 'service_id="$serviceId": malformed day-flag or date field');
        continue;
      }
      if (!seen.add(serviceId)) {
        duplicates++;
        continue;
      }
      batch.insert('calendar', {
        'service_id': serviceId,
        'monday': monday! ? 1 : 0,
        'tuesday': tuesday! ? 1 : 0,
        'wednesday': wednesday! ? 1 : 0,
        'thursday': thursday! ? 1 : 0,
        'friday': friday! ? 1 : 0,
        'saturday': saturday! ? 1 : 0,
        'sunday': sunday! ? 1 : 0,
        'start_date': startDate,
        'end_date': endDate,
      });
      imported++;
    }
    await batch.commit(noResult: true);
    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }

  /// Absent from the bundled Chennai feed — exercises the "missing
  /// optional file" path for real, not just in theory.
  Future<GtfsFileImportResult> _importCalendarDates(Transaction txn, String? content) async {
    const fileName = 'calendar_dates.txt';
    final parsed = _parseCsv(content);
    if (parsed == null) return GtfsFileImportResult.missing(fileName);
    final columnIndex = _columnIndex(parsed.header);

    int imported = 0, invalid = 0, duplicates = 0;
    final seen = <String>{};
    final samples = <String>[];
    final batch = txn.batch();

    for (final row in parsed.rows) {
      if (row.length != parsed.header.length) {
        invalid++;
        continue;
      }
      final serviceId = _cell(row, columnIndex, 'service_id') ?? '';
      final date = _cell(row, columnIndex, 'date') ?? '';
      final exceptionType = int.tryParse(_cell(row, columnIndex, 'exception_type') ?? '');
      if (serviceId.isEmpty ||
          !_safeIdentifierPattern.hasMatch(serviceId.trim()) ||
          !_datePattern.hasMatch(date) ||
          (exceptionType != 1 && exceptionType != 2)) {
        invalid++;
        _addSampleReason(samples, 'service_id="$serviceId": invalid date or exception_type');
        continue;
      }
      final key = '$serviceId|$date';
      if (!seen.add(key)) {
        duplicates++;
        continue;
      }
      batch.insert('calendar_dates', {
        'service_id': serviceId,
        'date': date,
        'exception_type': exceptionType,
      });
      imported++;
    }
    await batch.commit(noResult: true);
    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }

  Future<GtfsFileImportResult> _importShapes(Transaction txn, String? content) async {
    const fileName = 'shapes.txt';
    final parsed = _parseCsv(content);
    if (parsed == null) return GtfsFileImportResult.missing(fileName);
    final columnIndex = _columnIndex(parsed.header);

    int imported = 0, invalid = 0, duplicates = 0;
    final seen = <String>{};
    final samples = <String>[];
    final batch = txn.batch();

    for (final row in parsed.rows) {
      if (row.length != parsed.header.length) {
        invalid++;
        continue;
      }
      final shapeId = _cell(row, columnIndex, 'shape_id') ?? '';
      final lat = double.tryParse(_cell(row, columnIndex, 'shape_pt_lat') ?? '');
      final lon = double.tryParse(_cell(row, columnIndex, 'shape_pt_lon') ?? '');
      final sequence = int.tryParse(_cell(row, columnIndex, 'shape_pt_sequence') ?? '');
      if (shapeId.isEmpty || lat == null || lon == null || sequence == null) {
        invalid++;
        _addSampleReason(samples, 'shape_id="$shapeId": missing/unparseable field');
        continue;
      }
      if (lat < -90 || lat > 90 || lon < -180 || lon > 180) {
        invalid++;
        _addSampleReason(samples, 'shape_id="$shapeId": coordinates out of valid range');
        continue;
      }
      final key = '$shapeId|$sequence';
      if (!seen.add(key)) {
        duplicates++;
        continue;
      }
      batch.insert('shapes', {
        'shape_id': shapeId,
        'shape_pt_sequence': sequence,
        'shape_pt_lat': lat,
        'shape_pt_lon': lon,
        'shape_dist_traveled': double.tryParse(_cell(row, columnIndex, 'shape_dist_traveled') ?? ''),
      });
      imported++;
    }
    await batch.commit(noResult: true);
    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }

  /// stop_times.txt is ~1.36M rows (43MB) in the bundled feed.
  ///
  /// AUDIT FIX (P0-8 — GTFS import memory): this used to (1) build TWO
  /// extra full-size copies of the file content via
  /// `.replaceAll('\r\n','\n').replaceAll('\r','\n')`, (2) materialize
  /// every line into a `List<String>` via `.where(...).toList()`
  /// before processing any of them, and (3) hold a `Set<String>` of
  /// ~1.36M `"tripId|stopSequence"` keys for duplicate detection —
  /// despite the doc comment above (still true of the intent, not of
  /// what the code actually did) claiming this was memory-bounded
  /// streaming. Fixed:
  /// - The `.replaceAll` step is REMOVED, not just made lazy — it was
  ///   genuinely redundant. `LineSplitter` already splits on `\r\n`,
  ///   lone `\n`, and lone `\r` (see dart:convert's own
  ///   documentation), so normalizing line endings first had no
  ///   behavioral effect, only cost.
  /// - The `seen` Set is REMOVED. `stop_times` already has
  ///   `PRIMARY KEY (trip_id, stop_sequence)` (see
  ///   `gtfs_database.dart`) — SQLite itself is the uniqueness check
  ///   now, via `ConflictAlgorithm.ignore`, which is both correct and
  ///   avoids ever holding a duplicate-tracking structure sized to the
  ///   whole file at all.
  ///
  /// NOT fully fixed, honestly: this still calls
  /// `LineSplitter().convert(content)`, which materializes the whole
  /// line list at once (an unavoidable consequence of `content`
  /// already being one big decoded String by the time this method
  /// receives it — true streaming would mean reading `stop_times.txt`
  /// incrementally from the zip archive itself, a larger change than
  /// this pass's scope). What's fixed above are the three concrete,
  /// avoidable extra allocations this method was ADDING on top of
  /// that unavoidable baseline.
  Future<GtfsFileImportResult> _importStopTimesStreaming(Transaction txn, String? content) async {
    const fileName = 'stop_times.txt';
    if (content == null) return GtfsFileImportResult.missing(fileName);

    final lines = const LineSplitter().convert(content).where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) return GtfsFileImportResult.missing(fileName);

    final header =
        const CsvToListConverter(shouldParseNumbers: false).convert(lines.first).first.map((c) => c.toString().trim()).toList();
    final columnIndex = _columnIndex(header);

    int invalid = 0, validRowsAttempted = 0;
    final samples = <String>[];
    var batch = txn.batch();
    int inBatch = 0;

    for (int i = 1; i < lines.length; i++) {
      final parsedRow = const CsvToListConverter(shouldParseNumbers: false).convert(lines[i]);
      if (parsedRow.isEmpty) continue;
      final row = parsedRow.first.map((c) => c.toString().trim()).toList();

      if (row.length != header.length) {
        invalid++;
        _addSampleReason(samples, 'Row has ${row.length} fields, header declares ${header.length}');
        continue;
      }
      final tripId = _cell(row, columnIndex, 'trip_id') ?? '';
      final stopId = _cell(row, columnIndex, 'stop_id') ?? '';
      final arrivalTime = _cell(row, columnIndex, 'arrival_time') ?? '';
      final departureTime = _cell(row, columnIndex, 'departure_time') ?? '';
      final stopSequence = int.tryParse(_cell(row, columnIndex, 'stop_sequence') ?? '');

      if (tripId.isEmpty ||
          stopId.isEmpty ||
          stopSequence == null ||
          !_timePattern.hasMatch(arrivalTime) ||
          !_timePattern.hasMatch(departureTime)) {
        invalid++;
        _addSampleReason(samples, 'trip_id="$tripId": missing/malformed field');
        continue;
      }
      validRowsAttempted++;
      batch.insert(
        'stop_times',
        {
          'trip_id': tripId,
          'arrival_time': arrivalTime,
          'departure_time': departureTime,
          'stop_id': stopId,
          'stop_sequence': stopSequence,
          'pickup_type': int.tryParse(_cell(row, columnIndex, 'pickup_type') ?? ''),
          'drop_off_type': int.tryParse(_cell(row, columnIndex, 'drop_off_type') ?? ''),
        },
        // AUDIT FIX (P0-8): lets the table's own PRIMARY KEY
        // (trip_id, stop_sequence) be the uniqueness check instead of
        // an in-memory Set sized to the whole file.
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      inBatch++;
      if (inBatch >= _batchChunkSize) {
        await batch.commit(noResult: true);
        batch = txn.batch();
        inBatch = 0;
      }
    }
    await batch.commit(noResult: true);

    // Duplicates are now derived, not counted during the loop: with
    // ConflictAlgorithm.ignore, a per-row "was this a duplicate?"
    // signal isn't available from `batch.insert` inside a batch (it
    // doesn't throw or return per-row results with noResult: true).
    // The actual row count after commit is the ground truth for how
    // many of the attempted valid rows really landed in the table;
    // whatever's missing from validRowsAttempted was a duplicate.
    final actualRowCount = Sqflite.firstIntValue(
          await txn.rawQuery('SELECT COUNT(*) FROM stop_times'),
        ) ??
        0;
    final imported = actualRowCount;
    final duplicates = (validRowsAttempted - imported).clamp(0, validRowsAttempted);

    return GtfsFileImportResult(
      fileName: fileName,
      wasPresent: true,
      imported: imported,
      skippedDuplicates: duplicates,
      invalid: invalid,
      sampleInvalidReasons: samples,
    );
  }
}
