/// Per-file counts from one GTFS import — what actually happened,
/// not a pass/fail summary. A file with a high `invalid` count next
/// to a normal `imported` count usually means a real data-quality
/// issue in the source feed (see `GtfsImportService`'s doc comment
/// for concrete examples found in the bundled Chennai feed), not an
/// importer bug — that's exactly why this is reported per-file rather
/// than only as an aggregate success/failure.
class GtfsFileImportResult {
  final String fileName;
  final bool wasPresent;
  final int imported;
  final int skippedDuplicates;
  final int invalid;
  final List<String> sampleInvalidReasons; // capped, see GtfsImportService

  const GtfsFileImportResult({
    required this.fileName,
    required this.wasPresent,
    required this.imported,
    required this.skippedDuplicates,
    required this.invalid,
    required this.sampleInvalidReasons,
  });

  static GtfsFileImportResult missing(String fileName) => GtfsFileImportResult(
        fileName: fileName,
        wasPresent: false,
        imported: 0,
        skippedDuplicates: 0,
        invalid: 0,
        sampleInvalidReasons: const [],
      );
}

class GtfsImportReport {
  final List<GtfsFileImportResult> fileResults;
  final Duration totalImportTime;
  final bool succeeded;
  final String? failureReason;

  /// AUDIT ADD (P0-4): count of routes with route_type IN (1, 2)
  /// (subway/metro or rail) that actually made it into the imported
  /// database — a real, DB-grounded check, not an assumption from the
  /// per-file `invalid` counts above. Null if the import failed before
  /// this could be computed (see [failureReason] in that case); 0 is a
  /// real, meaningful result (see [hasChennaiMetroData]), not a
  /// missing-value placeholder.
  final int? metroRouteCount;

  const GtfsImportReport({
    required this.fileResults,
    required this.totalImportTime,
    required this.succeeded,
    this.failureReason,
    this.metroRouteCount,
  });

  /// False whenever [metroRouteCount] is 0 or the import didn't
  /// succeed — meaning Chennai Metro (CMRL) routing cannot currently
  /// work AT ALL, regardless of how much bus data imported
  /// successfully. See `GtfsImportService`'s class doc comment and
  /// `assets/gtfs/README.md` for why (the bundled feed's 3 CMRL route
  /// rows are column-shifted/malformed) and where to get a corrected
  /// feed. Journey-planning code and UI that could plausibly claim
  /// metro support should check this rather than assuming.
  bool get hasChennaiMetroData => succeeded && (metroRouteCount ?? 0) > 0;

  int get totalImported => fileResults.fold(0, (sum, r) => sum + r.imported);
  int get totalSkippedDuplicates => fileResults.fold(0, (sum, r) => sum + r.skippedDuplicates);
  int get totalInvalid => fileResults.fold(0, (sum, r) => sum + r.invalid);

  String toReadableSummary() {
    final buffer = StringBuffer();
    buffer.writeln(succeeded ? 'GTFS import succeeded.' : 'GTFS import FAILED: $failureReason');
    buffer.writeln('Total time: ${totalImportTime.inSeconds}s (${totalImportTime.inMilliseconds}ms)');
    buffer.writeln('Totals — imported: $totalImported, skipped duplicates: $totalSkippedDuplicates, '
        'invalid: $totalInvalid');
    if (succeeded && !hasChennaiMetroData) {
      buffer.writeln();
      buffer.writeln('*** CHENNAI METRO (CMRL) DATA UNAVAILABLE ***');
      buffer.writeln('0 rail/metro routes (route_type 1 or 2) were imported. The bundled feed\'s');
      buffer.writeln('CMRL route/trip rows are malformed (column-shifted) and were correctly');
      buffer.writeln('rejected by validation, not silently guessed at — see the invalid counts');
      buffer.writeln('for routes.txt/trips.txt below. Metro journey planning is NOT functional');
      buffer.writeln('until a corrected feed is imported. See assets/gtfs/README.md — the');
      buffer.writeln('intended replacement source is CUMTA\'s official portal: https://opendata.cumta.org/');
    }
    buffer.writeln();
    for (final r in fileResults) {
      if (!r.wasPresent) {
        buffer.writeln('${r.fileName}: NOT PRESENT in feed (skipped gracefully)');
        continue;
      }
      buffer.writeln('${r.fileName}: imported ${r.imported}, skipped duplicates ${r.skippedDuplicates}, '
          'invalid ${r.invalid}');
      for (final reason in r.sampleInvalidReasons) {
        buffer.writeln('  - $reason');
      }
    }
    return buffer.toString();
  }
}
