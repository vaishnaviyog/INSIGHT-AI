import 'package:sqflite/sqflite.dart';

import '../../database/gtfs_database.dart';

/// Thin lifecycle wrapper around [GtfsDatabase] — matches this
/// project's existing `initialize()`/`dispose()` service convention
/// (`UserProfileService`, `EmergencyService`, etc.) so
/// `GtfsImportService` and `GtfsQueryService` can depend on this one
/// service rather than each managing their own connection.
class GtfsDatabaseService {
  final GtfsDatabase _gtfsDatabase = GtfsDatabase();
  Database? _database;

  Future<void> initialize() async {
    _database = await _gtfsDatabase.open();
  }

  /// The open connection — throws a clear error if [initialize] wasn't
  /// called first, rather than a null-check failure with no context.
  Database get database {
    final db = _database;
    if (db == null) {
      throw StateError('GtfsDatabaseService.initialize() must be called before use.');
    }
    return db;
  }

  GtfsDatabase get schema => _gtfsDatabase;

  Future<void> dispose() async {
    await _gtfsDatabase.close();
    _database = null;
  }
}
