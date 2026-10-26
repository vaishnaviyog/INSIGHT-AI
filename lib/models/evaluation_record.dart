/// A single research evaluation record — one row of the CSV/JSON
/// export. Represents one detected-hazard episode from detection
/// through the user's response (if any).
///
/// This model intentionally duplicates data already tracked elsewhere
/// (e.g. risk score, which RiskAssessmentService also produces) rather
/// than referencing those objects directly. That's deliberate: this
/// module must survive independently of live app state (it's
/// persisted and exported later, possibly long after a session ends),
/// so it captures plain, stable values rather than holding references
/// into other services' live objects.
class EvaluationRecord {
  final String recordId;
  final String sessionId;

  final DateTime detectionTimestamp;
  final String objectType;
  final double detectionConfidence;
  final String detectorSource;
  final double riskScore;
  final String riskLevel;

  /// Null if AdaptiveGuidanceService decided not to speak a warning
  /// for this detection (e.g. suppressed by verbosity rules).
  final DateTime? voiceWarningTimestamp;

  /// AUDIT FIX (P0-5 — research-integrity semantics): this is NOT a
  /// measured human reaction time. It is the timestamp at which the
  /// hazard-detection pipeline stopped detecting the hazard that
  /// triggered this record (i.e. `HazardTemporalFilter` no longer
  /// confirms it present) — a warning-to-clearance latency, not a
  /// captured user response. It was previously named
  /// `userResponseTimestamp` / exposed as `reactionTimeSeconds`, which
  /// claimed more than the app can actually measure (there is no
  /// sensor confirming the user actually reacted, only that the
  /// object left detection range). Null if the hazard never cleared
  /// during observation (e.g. the session ended first) — a legitimate
  /// "no clearance recorded" data point for analysis, not a
  /// missing-data error.
  final DateTime? hazardClearanceTimestamp;

  final double? walkingSpeedMetersPerSecond;
  final double? gpsLatitude;
  final double? gpsLongitude;
  final double? routeFamiliarityScore;

  /// Compact summary of the behaviour profile AT THE TIME this record
  /// completed — not a live reference, so historical records stay
  /// accurate as the profile keeps evolving.
  final String behaviourProfileSummary;

  /// Active language at the time of this detection (Milestone 6).
  final String language;

  /// AdaptiveGuidanceService's verbosity/urgency decision for this
  /// warning, as a compact string (e.g. "standard/normal").
  final String adaptiveGuidanceMode;

  /// Count of emergency events (any status) logged during this
  /// session up to this record's timestamp — a coarse but real signal
  /// of how often SOS was triggered around hazard episodes.
  final int emergencyEventCount;

  /// Time in milliseconds the hazard-detection call itself took,
  /// measured at the call site in navigation_screen.dart (NOT inside
  /// HazardDetectionService, to avoid modifying a completed
  /// milestone's file). Null if not captured.
  final double? processingLatencyMs;

  /// Bounding box at detection time, as fractions (0..1) of the frame
  /// — same convention as `DetectedHazard.boundingBox` post-rewrite.
  /// All four null together if no box was available.
  final double? boundingBoxLeft;
  final double? boundingBoxTop;
  final double? boundingBoxWidth;
  final double? boundingBoxHeight;

  /// Monocular distance estimate in meters at detection time (see
  /// `DistanceEstimationConfig`). Null when the label had no
  /// configured known height.
  final double? estimatedDistanceMeters;

  const EvaluationRecord({
    required this.recordId,
    required this.sessionId,
    required this.detectionTimestamp,
    required this.objectType,
    required this.detectionConfidence,
    required this.detectorSource,
    required this.riskScore,
    required this.riskLevel,
    required this.behaviourProfileSummary,
    required this.language,
    required this.adaptiveGuidanceMode,
    required this.emergencyEventCount,
    this.voiceWarningTimestamp,
    this.hazardClearanceTimestamp,
    this.walkingSpeedMetersPerSecond,
    this.gpsLatitude,
    this.gpsLongitude,
    this.routeFamiliarityScore,
    this.processingLatencyMs,
    this.boundingBoxLeft,
    this.boundingBoxTop,
    this.boundingBoxWidth,
    this.boundingBoxHeight,
    this.estimatedDistanceMeters,
  });

  EvaluationRecord copyWith({
    DateTime? voiceWarningTimestamp,
    DateTime? hazardClearanceTimestamp,
    double? walkingSpeedMetersPerSecond,
    double? gpsLatitude,
    double? gpsLongitude,
    double? routeFamiliarityScore,
    String? behaviourProfileSummary,
    String? language,
    String? adaptiveGuidanceMode,
    int? emergencyEventCount,
    double? processingLatencyMs,
  }) =>
      EvaluationRecord(
        recordId: recordId,
        sessionId: sessionId,
        detectionTimestamp: detectionTimestamp,
        objectType: objectType,
        detectionConfidence: detectionConfidence,
        detectorSource: detectorSource,
        riskScore: riskScore,
        riskLevel: riskLevel,
        voiceWarningTimestamp: voiceWarningTimestamp ?? this.voiceWarningTimestamp,
        hazardClearanceTimestamp: hazardClearanceTimestamp ?? this.hazardClearanceTimestamp,
        walkingSpeedMetersPerSecond: walkingSpeedMetersPerSecond ?? this.walkingSpeedMetersPerSecond,
        gpsLatitude: gpsLatitude ?? this.gpsLatitude,
        gpsLongitude: gpsLongitude ?? this.gpsLongitude,
        routeFamiliarityScore: routeFamiliarityScore ?? this.routeFamiliarityScore,
        behaviourProfileSummary: behaviourProfileSummary ?? this.behaviourProfileSummary,
        language: language ?? this.language,
        adaptiveGuidanceMode: adaptiveGuidanceMode ?? this.adaptiveGuidanceMode,
        emergencyEventCount: emergencyEventCount ?? this.emergencyEventCount,
        processingLatencyMs: processingLatencyMs ?? this.processingLatencyMs,
      );

  /// Warning-to-clearance latency in seconds, if both timestamps are
  /// present — see [hazardClearanceTimestamp]'s doc comment for why
  /// this is explicitly NOT called a reaction time. A convenience
  /// getter for analysis, not stored separately.
  double? get hazardClearanceLatencySeconds {
    if (voiceWarningTimestamp == null || hazardClearanceTimestamp == null) return null;
    return hazardClearanceTimestamp!.difference(voiceWarningTimestamp!).inMilliseconds / 1000.0;
  }

  Map<String, dynamic> toMap() => {
        'recordId': recordId,
        'sessionId': sessionId,
        'detectionTimestamp': detectionTimestamp.toIso8601String(),
        'objectType': objectType,
        'detectionConfidence': detectionConfidence,
        'detectorSource': detectorSource,
        'riskScore': riskScore,
        'riskLevel': riskLevel,
        'voiceWarningTimestamp': voiceWarningTimestamp?.toIso8601String(),
        'hazardClearanceTimestamp': hazardClearanceTimestamp?.toIso8601String(),
        'walkingSpeedMetersPerSecond': walkingSpeedMetersPerSecond,
        'gpsLatitude': gpsLatitude,
        'gpsLongitude': gpsLongitude,
        'routeFamiliarityScore': routeFamiliarityScore,
        'behaviourProfileSummary': behaviourProfileSummary,
        'language': language,
        'adaptiveGuidanceMode': adaptiveGuidanceMode,
        'emergencyEventCount': emergencyEventCount,
        'processingLatencyMs': processingLatencyMs,
        'boundingBoxLeft': boundingBoxLeft,
        'boundingBoxTop': boundingBoxTop,
        'boundingBoxWidth': boundingBoxWidth,
        'boundingBoxHeight': boundingBoxHeight,
        'estimatedDistanceMeters': estimatedDistanceMeters,
      };

  factory EvaluationRecord.fromMap(Map<dynamic, dynamic> map) => EvaluationRecord(
        recordId: map['recordId'] as String,
        sessionId: map['sessionId'] as String,
        detectionTimestamp: DateTime.parse(map['detectionTimestamp'] as String),
        objectType: map['objectType'] as String,
        detectionConfidence: (map['detectionConfidence'] as num).toDouble(),
        detectorSource: map['detectorSource'] as String,
        riskScore: (map['riskScore'] as num).toDouble(),
        riskLevel: map['riskLevel'] as String? ?? 'unknown',
        voiceWarningTimestamp: map['voiceWarningTimestamp'] != null
            ? DateTime.parse(map['voiceWarningTimestamp'] as String)
            : null,
        // Reads BOTH the new key and the old pre-rename key, so a
        // record persisted before this fix still loads correctly
        // rather than silently losing its clearance timestamp.
        hazardClearanceTimestamp: (map['hazardClearanceTimestamp'] ?? map['userResponseTimestamp']) != null
            ? DateTime.parse((map['hazardClearanceTimestamp'] ?? map['userResponseTimestamp']) as String)
            : null,
        walkingSpeedMetersPerSecond: (map['walkingSpeedMetersPerSecond'] as num?)?.toDouble(),
        gpsLatitude: (map['gpsLatitude'] as num?)?.toDouble(),
        gpsLongitude: (map['gpsLongitude'] as num?)?.toDouble(),
        routeFamiliarityScore: (map['routeFamiliarityScore'] as num?)?.toDouble(),
        behaviourProfileSummary: map['behaviourProfileSummary'] as String? ?? '',
        language: map['language'] as String? ?? 'english',
        adaptiveGuidanceMode: map['adaptiveGuidanceMode'] as String? ?? 'unknown',
        emergencyEventCount: map['emergencyEventCount'] as int? ?? 0,
        processingLatencyMs: (map['processingLatencyMs'] as num?)?.toDouble(),
        boundingBoxLeft: (map['boundingBoxLeft'] as num?)?.toDouble(),
        boundingBoxTop: (map['boundingBoxTop'] as num?)?.toDouble(),
        boundingBoxWidth: (map['boundingBoxWidth'] as num?)?.toDouble(),
        boundingBoxHeight: (map['boundingBoxHeight'] as num?)?.toDouble(),
        estimatedDistanceMeters: (map['estimatedDistanceMeters'] as num?)?.toDouble(),
      );

  /// CSV header row, in the same order as [toCsvRow].
  static const List<String> csvHeader = [
    'record_id',
    'session_id',
    'detection_timestamp',
    'object_type',
    'detection_confidence',
    'detector_source',
    'risk_score',
    'risk_level',
    'voice_warning_timestamp',
    'hazard_clearance_timestamp',
    'hazard_clearance_latency_seconds',
    'walking_speed_mps',
    'gps_latitude',
    'gps_longitude',
    'route_familiarity_score',
    'behaviour_profile_summary',
    'language',
    'adaptive_guidance_mode',
    'emergency_event_count',
    'processing_latency_ms',
    'bounding_box_left',
    'bounding_box_top',
    'bounding_box_width',
    'bounding_box_height',
    'estimated_distance_meters',
  ];

  /// CSV field-escaping rule (RFC 4180-style): a field containing a
  /// comma, double-quote, or newline is wrapped in quotes with any
  /// internal quote doubled. Used by [EvaluationService.exportToCsv]
  /// for every header/row cell — kept here (not private to that
  /// service) specifically so it's a plain, dependency-free function
  /// unit-testable without Hive/path_provider/File, which
  /// `EvaluationService` itself needs just to construct.
  static String csvEscape(String field) {
    if (field.contains(',') || field.contains('"') || field.contains('\n')) {
      return '"${field.replaceAll('"', '""')}"';
    }
    return field;
  }

  /// One CSV row matching [csvHeader]'s column order. Fields are
  /// plain values (ISO 8601 timestamps, decimals) chosen specifically
  /// to be directly readable by Python (pandas.read_csv), R
  /// (read.csv), and Excel without any preprocessing.
  List<String> toCsvRow() => [
        recordId,
        sessionId,
        detectionTimestamp.toIso8601String(),
        objectType,
        detectionConfidence.toStringAsFixed(4),
        detectorSource,
        riskScore.toStringAsFixed(4),
        riskLevel,
        voiceWarningTimestamp?.toIso8601String() ?? '',
        hazardClearanceTimestamp?.toIso8601String() ?? '',
        hazardClearanceLatencySeconds?.toStringAsFixed(3) ?? '',
        walkingSpeedMetersPerSecond?.toStringAsFixed(3) ?? '',
        gpsLatitude?.toStringAsFixed(6) ?? '',
        gpsLongitude?.toStringAsFixed(6) ?? '',
        routeFamiliarityScore?.toStringAsFixed(4) ?? '',
        behaviourProfileSummary,
        language,
        adaptiveGuidanceMode,
        emergencyEventCount.toString(),
        processingLatencyMs?.toStringAsFixed(1) ?? '',
        boundingBoxLeft?.toStringAsFixed(4) ?? '',
        boundingBoxTop?.toStringAsFixed(4) ?? '',
        boundingBoxWidth?.toStringAsFixed(4) ?? '',
        boundingBoxHeight?.toStringAsFixed(4) ?? '',
        estimatedDistanceMeters?.toStringAsFixed(2) ?? '',
      ];
}
