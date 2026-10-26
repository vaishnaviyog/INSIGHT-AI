import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../../models/gtfs/stop.dart';
import '../../repositories/gtfs_repository.dart';
import '../voice_understanding/fuzzy_matcher.dart';

/// Resolves a destination QUERY TEXT (already filler-stripped by
/// `DestinationResolver`/`VoiceUnderstandingLayer`, or a raw address
/// string) against the on-device GTFS stop corpus.
///
/// EXTRACTED, NOT REWRITTEN: this is the exact same substring-match /
/// fuzzy-index-fallback / best-candidate-ranking algorithm that
/// previously lived as `NavigationScreen`'s private
/// `_resolveGtfsStopForQuery`/`_pickBestCandidate`/
/// `_resolveGtfsStopByFuzzyIndexMatch` methods — moved here UNCHANGED
/// (same thresholds, same ranking, same fallback order) so it can be
/// exercised directly by tests against the real bundled GTFS data,
/// which a `StatefulWidget` State class's private (leading-underscore)
/// methods cannot be — Dart's library privacy makes them unreachable
/// from any other file, including test files.
///
/// AUDIT FIX (destination-resolution correctness — the "Tambaram,
/// Chennai" investigation): the ONE behavioral change from the
/// original logic is [stripTrailingCityQualifier], applied as a new
/// first step before either GTFS-matching stage runs. See that
/// method's own doc comment for the full reasoning. Everything else —
/// `searchStops` substring matching, the fuzzy whole-name fallback,
/// and `_pickBestCandidate`'s length-closeness/GPS-proximity/
/// Levenshtein-sanity-check ranking — is identical to before.
class GtfsLocalityResolver {
  final GtfsRepository gtfsRepository;

  const GtfsLocalityResolver(this.gtfsRepository);

  /// Strips a trailing geocoder-oriented city/locality qualifier
  /// (", Chennai" or " Chennai") from [query] before it is used to
  /// match against the LOCAL, single-city GTFS stop corpus.
  ///
  /// WHY THIS IS THE ROOT-CAUSE FIX, NOT A WORKAROUND: a single-city
  /// GTFS feed's own `stops.txt` never carries a city-name suffix on
  /// its stop names — that suffix exists purely to help an ONLINE
  /// geocoder (which searches a global address space) disambiguate a
  /// place name. Left in the query, it silently defeats an otherwise-
  /// confident LOCAL match: "Tambaram, Chennai" cannot substring- or
  /// fuzzy-match any real stop, because every real Tambaram-area stop
  /// is named "Tambaram <something>" (Railway Station, West Bus
  /// Stand, Depot, Sanatorium B.T, ...) — none contain the literal
  /// text ", Chennai" — so resolution previously fell through to
  /// Nominatim geocoding, which (for this specific ambiguous, broad
  /// locality name) returned a point ~2.5km from the real transit
  /// hub cluster, confirmed against the bundled GTFS data.
  ///
  /// GENERIC, NOT A TAMBARAM SPECIAL CASE: the identical
  /// "<Place Name>, Chennai" pattern is used by more than a dozen
  /// other `DestinationAliasDictionary` entries — Guindy, Anna Nagar,
  /// Adyar, Egmore Railway Station, T Nagar, Velachery, Saidapet,
  /// Marina Beach, Phoenix MarketCity, Express Avenue Mall, LIC
  /// Building, Government General Hospital, Chennai Central Railway
  /// Station — and applies equally to any future locality added the
  /// same way, or to a query built from arbitrary spoken/typed text
  /// that happens to end the same way. This method has no knowledge
  /// of any specific place name; it only recognizes the qualifier
  /// shape itself.
  ///
  /// DELIBERATELY NARROW — PRESERVES USER SPECIFICITY: only strips a
  /// recognized trailing city name, never touches anything else in
  /// the query. A MORE specific request like "Tambaram Railway
  /// Station" (no city suffix) passes through byte-for-byte
  /// unchanged, so it still resolves to that specific station rather
  /// than being diluted toward a generic locality pick — "Tambaram
  /// Railway Station" stays strictly more specific than "Tambaram".
  ///
  /// The ORIGINAL, un-stripped [query] remains what a caller should
  /// send to the online geocoder if GTFS matching still fails — the
  /// city qualifier is genuinely useful there, so this method's
  /// output is only ever used for the LOCAL match attempt, never as a
  /// replacement for the text handed to geocoding.
  static String stripTrailingCityQualifier(String query) {
    const citySuffixes = [', Chennai', ' Chennai'];
    final result = query.trim();
    for (final suffix in citySuffixes) {
      if (result.toLowerCase().endsWith(suffix.toLowerCase())) {
        final stripped = result.substring(0, result.length - suffix.length).trim();
        if (stripped.isNotEmpty) return stripped;
      }
    }
    return result;
  }

  /// Same contract as the original `_resolveGtfsStopForQuery`: null
  /// means "no confident local match — fall back to online geocoding
  /// with the ORIGINAL query," never a guess. [currentPosition], if
  /// available, breaks length-closeness ties by GPS proximity (same
  /// as before).
  Future<GtfsStop?> resolve(String query, {Position? currentPosition}) async {
    final trimmed = stripTrailingCityQualifier(query);
    if (trimmed.length < 4) return null;

    List<GtfsStop> candidates;
    try {
      candidates = await gtfsRepository.searchStops(trimmed, limit: 30);
    } catch (e) {
      // ignore: avoid_print
      print('[GtfsLocalityResolver] searchStops("$trimmed") failed: $e');
      return null;
    }

    if (candidates.isEmpty) {
      return _resolveByFuzzyIndexMatch(trimmed, currentPosition: currentPosition);
    }
    return _pickBestCandidate(candidates, trimmed, currentPosition: currentPosition);
  }

  /// AUDIT FIX (real-device validation phase — "Tambaram West"
  /// investigation): candidates whose distance-to-[currentPosition]
  /// differs by more than this are treated as genuinely different
  /// real-world locations, not noise — GPS ranks them. Candidates
  /// within this tolerance of each other fall through to
  /// length-closeness instead, so the near-duplicate entries this
  /// feed genuinely contains for the SAME physical stop (confirmed:
  /// several "Tambaram West Bus Stand" rows within ~50m of each
  /// other) don't flip-flop on ordinary GPS noise. 300m is well above
  /// typical smartphone GPS error (commonly single-digit to
  /// low-tens of meters) and well above the observed same-stop
  /// duplicate spread, but far below the ~1.3km gap between the two
  /// GENUINELY different stops that caused this bug.
  static const double _gpsDisambiguationToleranceMeters = 300.0;

  /// Ranks [candidates] (all already known to substring-match
  /// [trimmed]).
  ///
  /// AUDIT FIX (real-device validation phase — "Tambaram West"
  /// investigation, reproduced against this exact bundled feed): the
  /// ORIGINAL ordering ranked by length-closeness FIRST and only
  /// consulted GPS proximity when two candidates' name lengths were
  /// EXACTLY equal — which almost never happens for two genuinely
  /// different real-world stops. The bundled feed contains both
  /// "Tambaram West" (stop ids 6683/6685) and "Tambaram West Bus
  /// Stand" (stop ids 10972/6692/6693) — two real stops roughly 1.3km
  /// apart. A query of "Tambaram West" exactly matches the first
  /// name's length (length-diff 0) and always lost the second
  /// (length-diff 11) NO MATTER WHERE THE USER ACTUALLY WAS, because
  /// the length check short-circuited before GPS was ever considered
  /// — a deterministic, reproducible wrong-stop result, not
  /// GPS-noise-driven flakiness.
  ///
  /// FIX: when [currentPosition] is available (production always
  /// supplies it — see `NavigationScreen._fetchRoute`'s
  /// `_gtfsLocalityResolver.resolve(..., currentPosition: _lastPosition)`
  /// call), GPS proximity is now the PRIMARY ranking signal, with
  /// length-closeness only breaking a genuine near-tie in distance
  /// (see [_gpsDisambiguationToleranceMeters]'s doc comment for why
  /// that tolerance is safe). When [currentPosition] is null (as
  /// every existing unit test in this file calls this method), the
  /// ranking is BYTE-FOR-BYTE the original length-closeness-only
  /// behavior — this cannot regress any case that previously resolved
  /// correctly without a known position.
  GtfsStop? _pickBestCandidate(List<GtfsStop> candidates, String trimmed, {Position? currentPosition}) {
    if (candidates.isEmpty) return null;
    final sorted = [...candidates]
      ..sort((a, b) {
        if (currentPosition != null) {
          final distA = Geolocator.distanceBetween(
              currentPosition.latitude, currentPosition.longitude, a.stopLat, a.stopLon);
          final distB = Geolocator.distanceBetween(
              currentPosition.latitude, currentPosition.longitude, b.stopLat, b.stopLon);
          if ((distA - distB).abs() > _gpsDisambiguationToleranceMeters) {
            return distA.compareTo(distB);
          }
          // Genuinely close in distance (or the same physical stop
          // duplicated in the feed) — fall through to length-closeness
          // below rather than let GPS noise decide.
        }
        final lenDiffA = (a.stopName.length - trimmed.length).abs();
        final lenDiffB = (b.stopName.length - trimmed.length).abs();
        return lenDiffA.compareTo(lenDiffB);
      });

    final best = sorted.first;
    final distance = FuzzyMatcher.levenshtein(trimmed.toLowerCase(), best.stopName.toLowerCase());
    if (distance > trimmed.length * 3) return null;
    return best;
  }

  /// The general, data-driven fallback for a query that doesn't
  /// literally substring-match any stop name — unchanged from the
  /// original `NavigationScreen._resolveGtfsStopByFuzzyIndexMatch`.
  Future<GtfsStop?> _resolveByFuzzyIndexMatch(String trimmed, {Position? currentPosition}) async {
    List<String> allNames;
    try {
      allNames = await gtfsRepository.getAllDistinctStopNames();
    } catch (e) {
      // ignore: avoid_print
      print('[GtfsLocalityResolver] getAllDistinctStopNames() failed: $e');
      return null;
    }
    if (allNames.isEmpty) return null;

    // AUDIT FIX (Phase F3 — destination-matching root cause, "Chennai
    // Central" investigation): the original fixed -3/+20 length window
    // silently excluded the CORRECT match for real dictionary entries
    // whose canonicalSearchQuery is padded with Nominatim-oriented
    // words the local GTFS stop name doesn't carry — reproduced and
    // measured against the real bundled feed: "Chennai Central Railway
    // Station" (31 chars, from the "Chennai Central" dictionary entry)
    // excludes the real, correct stop "Mgr Central Railway Station"
    // (27 chars) by exactly ONE character under the old minLength=28,
    // and the fuzzy matcher instead picked "Nungambakkam Railway
    // Station" from the wrongly-narrowed pool — a real wrong-station
    // result, not a hypothetical one.
    //
    // Below, `distanceMargin` is DERIVED from the same 0.4
    // relative-distance threshold this method already uses to
    // accept/reject a match (`relativeDistance > 0.4` further down) —
    // by the standard edit-distance bound `|len(a)-len(b)| <=
    // levenshtein(a,b)`, no candidate whose length differs from
    // [trimmed] by more than `0.4 * trimmed.length` could EVER pass
    // that check anyway, so widening the pre-filter to match it can
    // only ever ADD candidates that were always eligible to win, never
    // include something the final check would reject.
    //
    // `math.max` against the ORIGINAL -3/+20 offsets guarantees this
    // window is never NARROWER than before for any query length — this
    // is a strictly monotonic widening, so it cannot regress any case
    // that already resolved correctly.
    final distanceMargin = (trimmed.length * 0.4).ceil();
    final minLength = (trimmed.length - math.max(3, distanceMargin)).clamp(1, trimmed.length);
    final maxLength = trimmed.length + math.max(20, distanceMargin);
    final narrowed = allNames.where((name) => name.length >= minLength && name.length <= maxLength).toList();
    if (narrowed.isEmpty) return null;

    final bestMatch = FuzzyMatcher.bestMatch(trimmed, narrowed);
    if (bestMatch == null) return null;

    final relativeDistance = bestMatch.distance / trimmed.length;
    if (relativeDistance > 0.4) return null;

    // AUDIT FIX (real-device validation phase — "Tambaram best bus"
    // mis-transcription investigation): previously this collapsed
    // straight to the SINGLE closest-matching name string
    // (`bestMatch.match`) and searched only for stops with that EXACT
    // name. Reproduced live, on a real device: speech recognition
    // mis-heard "Tambaram West" as "tambaram best bus"; by pure edit
    // distance, "Tambaram West" (13 chars) narrowly beat "Tambaram West
    // Bus Stand" (24 chars) as the single best-matching name, so the
    // real, GPS-nearby "Tambaram West Bus Stand" stops were excluded
    // before GPS ever got a say.
    //
    // FIRST ATTEMPT (reverted): pooling every name within a small edit-
    // distance margin of `bestMatch.distance`. Measured against this
    // exact real transcription, that pool included "Tambaram Depot" and
    // "Tambaram East Bus Stop" — genuinely DIFFERENT, unrelated places
    // that happened to tie or nearly tie in raw edit distance — and GPS
    // then picked whichever of THOSE was nearest, discarding what the
    // query actually said. Raw edit-distance slack is too coarse: it
    // can't distinguish "a closer variant of the same place" from "an
    // unrelated place that happens to be similarly misspelled."
    //
    // ACTUAL FIX: only pool names in a PREFIX-FAMILY relationship with
    // the winning match — i.e. one name is the other plus a trailing
    // qualifier ("Tambaram West" / "Tambaram West Bus Stand"), the
    // exact same real-world pattern already handled by
    // `_pickBestCandidate`'s own GPS-vs-length-closeness fix (measured
    // there: 358 such genuinely-different-place pairs exist in this
    // bundled feed). This keeps the pool scoped to competing
    // interpretations of the SAME base locality the fuzzy matcher
    // already identified, so GPS only ever disambiguates among those —
    // never among unrelated places that merely scored similarly on raw
    // text distance.
    final relatedNames = <String>{bestMatch.match};
    final bestMatchLower = bestMatch.match.toLowerCase();
    for (final name in allNames) {
      if (name == bestMatch.match) continue;
      final nameLower = name.toLowerCase();
      if (nameLower.startsWith('$bestMatchLower ') || bestMatchLower.startsWith('$nameLower ')) {
        relatedNames.add(name);
      }
    }

    // AUDIT FIX (real-device validation phase — "tambaram west bus
    // stop" investigation, a SEPARATE mis-transcription from the one
    // above): prefix-family pooling doesn't catch every real ambiguity.
    // Reproduced live: query "tambaram west bus stop" sits at
    // CHARACTER-distance 2 from the unrelated "Tambaram East Bus Stop"
    // but character-distance 3 from the actually-correct "Tambaram West
    // Bus Stand" — "west"/"east" differs by fewer LETTERS than
    // "stop"/"stand" does, so pure character counting confidently (and
    // wrongly) favors the unrelated place. Neither name is a prefix of
    // the other, so the pooling above never even considers them
    // together.
    //
    // At the WORD level, though, both differ from the query by exactly
    // ONE token (east<->west vs stand<->stop) — a genuine tie. Pool
    // every name among the already length-windowed [narrowed] set whose
    // word-level distance to [trimmed] is EXACTLY 1 — deliberately not
    // "the best distance found, whatever it is": measured against this
    // exact query, a distance-of-2 threshold additionally pooled in
    // "Tambaram Tb Hospital" (a real, unrelated place), and GPS then
    // wrongly preferred it over the correct Bus Stand — the same class
    // of false positive as the reverted raw-character-slack attempt
    // above. A single-token substitution (this method's actual target:
    // one word swapped by STT) is a precise, narrow signal; two or more
    // differing words is not — see `FuzzyMatcher.wordLevelDistance`'s
    // doc comment for the full reasoning.
    final wordTiedNames = <String>{};
    for (final name in narrowed) {
      if (FuzzyMatcher.wordLevelDistance(trimmed, name) == 1) {
        wordTiedNames.add(name);
      }
    }
    relatedNames.addAll(wordTiedNames);

    final pooledStops = <GtfsStop>[];
    final seenStopIds = <String>{};
    for (final name in relatedNames) {
      List<GtfsStop> matchedStops;
      try {
        matchedStops = await gtfsRepository.searchStops(name, limit: 30);
      } catch (e) {
        // ignore: avoid_print
        print('[GtfsLocalityResolver] searchStops("$name") failed: $e');
        continue;
      }
      for (final stop in matchedStops) {
        if (stop.stopName == name && seenStopIds.add(stop.stopId)) {
          pooledStops.add(stop);
        }
      }
    }
    if (pooledStops.isEmpty) return null;

    // AUDIT FIX: when pooling found a GENUINE TIE (more than one
    // distinctly-named real place, not just duplicate entries of ONE
    // place) and a GPS position is available, resolve directly by
    // strict nearest-distance among the POOLED stops — bypassing
    // `_pickBestCandidate`'s 300m same-place tolerance below. That
    // tolerance exists to protect against GPS noise among likely-
    // duplicate entries of a SINGLE place (see its own doc comment) —
    // it was never meant to decide between two textually-related but
    // genuinely DIFFERENT real places, and its length-closeness
    // fallback is anchored to `bestMatch.match` (the character-level
    // winner), which — for exactly this scenario — IS the wrong
    // answer, so falling through to it would silently re-introduce the
    // bug this fix targets. Reproduced live: "Tambaram West Bus Stand"
    // (correct) and "Tambaram East Bus Stop" (wrong) were only 191m
    // apart in GPS distance from the real test position — inside that
    // 300m tolerance — so without this direct check, resolution fell
    // through to length-closeness and confidently picked the wrong one
    // again.
    //
    // AUDIT FIX (Southern Railway suburban-rail data merge): originally
    // scoped to `wordTiedNames.length > 1` only — but the SAME failure
    // mode reproduces through the PREFIX-FAMILY pool too, not just the
    // word-tie one, once a new bare, short, unqualified name enters the
    // feed. Confirmed live: adding SRR's "TAMBARAM" station made IT the
    // new `bestMatch.match` winner for "tambaram best bus" (now the
    // single closest raw edit-distance match), which prefix-family-
    // pools in the correct "Tambaram West Bus Stand" (24 chars) — but
    // falling through to `_pickBestCandidate` then anchors length-
    // closeness to "TAMBARAM" (8 chars) itself, which trivially wins
    // its own length comparison against every longer name in its own
    // pool, regardless of GPS. Widened from `wordTiedNames` to
    // `relatedNames` (which already a superset — see `addAll` above) so
    // this protection covers both pooling mechanisms the same way,
    // rather than re-introducing the bug for one of the two.
    if (relatedNames.length > 1 && currentPosition != null) {
      GtfsStop? nearest;
      double? nearestDistanceMeters;
      for (final stop in pooledStops) {
        final distance = Geolocator.distanceBetween(
            currentPosition.latitude, currentPosition.longitude, stop.stopLat, stop.stopLon);
        if (nearestDistanceMeters == null || distance < nearestDistanceMeters) {
          nearestDistanceMeters = distance;
          nearest = stop;
        }
      }
      if (nearest != null) return nearest;
    }

    return _pickBestCandidate(pooledStops, bestMatch.match, currentPosition: currentPosition);
  }
}
