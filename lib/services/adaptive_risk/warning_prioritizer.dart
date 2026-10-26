import '../../models/detected_hazard.dart';

enum WarningUrgency { immediate, high, low, ignore }

/// Result of prioritizing/merging a frame's hazard list into ONE
/// natural warning — never more than one utterance queued per frame,
/// per this phase's "avoid repetitive speech" / "merge warnings"
/// requirement.
class PrioritizedWarning {
  final String mergedMessage;
  final WarningUrgency urgency;
  final bool interrupt;
  final List<DetectedHazard> includedHazards;

  const PrioritizedWarning({
    required this.mergedMessage,
    required this.urgency,
    required this.interrupt,
    required this.includedHazards,
  });

  static const PrioritizedWarning none = PrioritizedWarning(
    mergedMessage: '',
    urgency: WarningUrgency.ignore,
    interrupt: false,
    includedHazards: [],
  );
}

/// Decides which of a frame's detected hazards are actually worth
/// speaking about, and merges several into one sentence instead of
/// queuing separate utterances — the piece that was genuinely missing
/// before this phase: `NavigationScreen`'s existing loop only ever
/// looked at `hazards.first` (see that file), so a second
/// simultaneously-detected hazard was silently never spoken about at
/// all, merged or otherwise.
///
/// "OBJECT BEHIND USER" — this app's camera is forward-facing only
/// (see `HorizontalPosition`'s own doc comment: "there is no 'behind
/// you' — the camera only sees forward"), so a hazard can't be
/// literally detected behind the user. What this requirement maps to
/// concretely here: a hazard that's far away AND only informational
/// priority (a bench, a static object) contributes negligible
/// wayfinding value once already announced once — treated as
/// [WarningUrgency.ignore], not spoken repeatedly. A hazard that
/// stops being detected at all (the user has walked past it) already
/// stops being warned about via `HazardTemporalFilter`'s existing
/// per-frame reset — nothing new needed there.
class WarningPrioritizer {
  // AUDIT ADD (Phase C2 — TTC/approaching-hazard safety): matches the
  // codebase's EXISTING definition of "approaching" — both
  // RiskAssessmentService's broader TTC boost tier and
  // AdaptiveGuidanceService's own "Approaching quickly." spoken phrase
  // already fire at `ttc <= 3.0`. Deliberately NOT the tighter 1.5s
  // tier those two use for their highest boost/urgency: at ~8 m/s
  // closing speed (a plausible urban vehicle), 1.5s leaves a blind
  // pedestrian almost no reaction buffer once a warning is even
  // spoken — reusing the already-considered 3.0s "approaching"
  // definition is the more protective, still-consistent choice.
  static const double _urgentTtcThresholdSeconds = 3.0;

  /// A non-null [DetectedHazard.timeToCollisionSeconds] reaching this
  /// class has ALREADY been vetted by [CollisionTimeEstimator] as
  /// fresh (this confirmed-frame cycle only, never stale), physically
  /// plausible (closing speed capped — see that class's own doc
  /// comment), and genuinely closing (never negative/infinite/from a
  /// stationary or receding object). This confidence floor is this
  /// class's OWN, additional margin specifically against letting a
  /// borderline-confidence detection alone drive an interrupting
  /// [WarningUrgency.immediate]/high warning.
  static const double _ttcUrgencyMinConfidence = 0.5;

  PrioritizedWarning prioritize(List<DetectedHazard> hazards) {
    if (hazards.isEmpty) return PrioritizedWarning.none;

    final relevant = hazards.where((h) => _urgencyFor(h) != WarningUrgency.ignore).toList()
      ..sort((a, b) => _urgencyScore(b).compareTo(_urgencyScore(a)));

    if (relevant.isEmpty) return PrioritizedWarning.none;

    final topUrgency = _urgencyFor(relevant.first);

    // Merge up to 3 distinct-label hazards worth mentioning into one
    // natural sentence, most urgent first.
    final distinctLabels = <String>{};
    final parts = <String>[];
    for (final hazard in relevant) {
      if (parts.length >= 3) break;
      if (distinctLabels.add(hazard.label)) parts.add(_describe(hazard));
    }

    final message = switch (parts.length) {
      0 => '',
      1 => parts.first,
      _ => '${parts.sublist(0, parts.length - 1).join(", ")}, and ${parts.last}',
    };

    return PrioritizedWarning(
      mergedMessage: message,
      urgency: topUrgency,
      interrupt: topUrgency == WarningUrgency.immediate,
      includedHazards: relevant.take(parts.length).toList(),
    );
  }

  /// Ordering key ONLY — not the spoken urgency tier itself (see
  /// [_urgencyFor] for that). Weighted so a critical, very-near hazard
  /// always sorts above a caution-tier one regardless of confidence.
  double _urgencyScore(DetectedHazard h) {
    final priorityScore = switch (h.priority) {
      HazardPriority.critical => 3.0,
      HazardPriority.caution => 2.0,
      HazardPriority.informational => 1.0,
    };
    final distanceScore = switch (h.distanceBand) {
      DistanceBand.veryNear => 3.0,
      DistanceBand.near => 2.0,
      DistanceBand.far => 1.0,
      DistanceBand.unknown => 1.5,
    };
    return priorityScore * 2 + distanceScore + h.confidence;
  }

  /// True when [h] carries a short, credible, already-vetted TTC — see
  /// [_ttcUrgencyMinConfidence]'s doc comment for exactly what
  /// "already-vetted" means and why this method trusts a non-null
  /// value rather than re-deriving plausibility itself.
  bool _hasUrgentCredibleTtc(DetectedHazard h) =>
      h.timeToCollisionSeconds != null &&
      h.timeToCollisionSeconds! <= _urgentTtcThresholdSeconds &&
      h.confidence >= _ttcUrgencyMinConfidence;

  WarningUrgency _urgencyFor(DetectedHazard h) {
    // "Moving vehicle approaching" -> highest priority: critical +
    // close enough to matter right now.
    if (h.priority == HazardPriority.critical &&
        (h.distanceBand == DistanceBand.veryNear || h.distanceBand == DistanceBand.near)) {
      return WarningUrgency.immediate;
    }
    // AUDIT FIX (Phase C2 — TTC/approaching-hazard safety): a critical
    // hazard still classified "far" by raw distance/bbox size can be
    // closing distance fast enough to be MORE urgent than a near,
    // stationary one — e.g. a car 20m away closing at 8 m/s (TTC
    // ~2.5s), reproduced as genuinely reaching only WarningUrgency.high
    // before this fix. This is purely ADDITIVE: it only changes the
    // "far" case above, since "near"/"veryNear" already return
    // immediate unconditionally.
    if (h.priority == HazardPriority.critical && _hasUrgentCredibleTtc(h)) {
      return WarningUrgency.immediate;
    }
    if (h.priority == HazardPriority.critical) return WarningUrgency.high;
    if (h.priority == HazardPriority.caution && h.distanceBand != DistanceBand.far) return WarningUrgency.high;
    // AUDIT FIX (Phase C2): symmetric extension for caution-tier
    // hazards (e.g. a rapidly approaching bicycle) — same pre-vetted-
    // TTC + confidence gate as the critical-tier promotion above, but
    // only ever reaches `high` (this app's existing ceiling for
    // caution-tier hazards), never `immediate` — a fast-approaching
    // bicycle is treated as urgent, not equated with an approaching
    // vehicle.
    if (h.priority == HazardPriority.caution && _hasUrgentCredibleTtc(h)) {
      return WarningUrgency.high;
    }
    // "Static bench" (informational) far away -> ignore, per this
    // phase's explicit example.
    if (h.priority == HazardPriority.informational && h.distanceBand == DistanceBand.far) {
      return WarningUrgency.ignore;
    }
    return WarningUrgency.low;
  }

  String _describe(DetectedHazard h) {
    final proximity = switch (h.distanceBand) {
      DistanceBand.veryNear => 'very close',
      DistanceBand.near => 'nearby',
      DistanceBand.far => 'ahead',
      DistanceBand.unknown => 'ahead',
    };
    return '${h.label} $proximity';
  }
}
