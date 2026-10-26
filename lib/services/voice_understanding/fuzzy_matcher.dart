/// Classic Levenshtein edit distance + best-match lookup — corrects
/// common STT mistakes (e.g. "Tambram"/"Gundy"/"Kindy" for
/// "Tambaram"/"Guindy") by finding the closest known alias, not by any
/// learned model.
class FuzzyMatcher {
  FuzzyMatcher._();

  static int levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;

    var previousRow = List<int>.generate(b.length + 1, (i) => i);
    var currentRow = List<int>.filled(b.length + 1, 0);

    for (int i = 0; i < a.length; i++) {
      currentRow[0] = i + 1;
      for (int j = 0; j < b.length; j++) {
        final deletionCost = previousRow[j + 1] + 1;
        final insertionCost = currentRow[j] + 1;
        final substitutionCost = previousRow[j] + (a[i] == b[j] ? 0 : 1);
        currentRow[j + 1] = [deletionCost, insertionCost, substitutionCost].reduce((x, y) => x < y ? x : y);
      }
      final swap = previousRow;
      previousRow = currentRow;
      currentRow = swap;
    }
    return previousRow[b.length];
  }

  /// Best match for [input] among [candidates] (case-insensitive),
  /// returned with its edit distance — null if [candidates] is empty.
  /// Callers decide what edit distance counts as "close enough"; see
  /// `DestinationResolver` for the threshold used there.
  static ({String match, int distance})? bestMatch(String input, List<String> candidates) {
    if (candidates.isEmpty) return null;
    final normalizedInput = input.toLowerCase().trim();
    String? best;
    int bestDistance = 1 << 30;
    for (final candidate in candidates) {
      final distance = levenshtein(normalizedInput, candidate.toLowerCase().trim());
      if (distance < bestDistance) {
        bestDistance = distance;
        best = candidate;
      }
    }
    return best == null ? null : (match: best, distance: bestDistance);
  }

  /// Levenshtein distance over WHOLE WORDS (whitespace-split tokens),
  /// not characters — insert/delete/substitute cost 1 per DIFFERING
  /// token, an exact token match costs 0, case-insensitive.
  ///
  /// AUDIT ADD (real-device validation — "tambaram west bus stop"
  /// investigation): character-level distance can pick the WRONG real
  /// place when speech-to-text swaps one whole distinguishing word for
  /// another real word of similar length — reproduced live: "tambaram
  /// west bus stop" sits at character-distance 2 from the unrelated
  /// "Tambaram East Bus Stop" (only "w"/"e" and "e"/"a" differ) but
  /// character-distance 3 from the actually-correct "Tambaram West Bus
  /// Stand" ("stop"/"stand" differ by more letters than "west"/"east"
  /// does) — character counting has no notion that "west" being RIGHT
  /// matters more than "stop" being character-similar to "stand". At
  /// the WORD level, both differ from the query by exactly one token
  /// (east<->west vs stand<->stop) — a genuine tie a character-only
  /// metric can't see, which is exactly the signal
  /// `GtfsLocalityResolver._resolveByFuzzyIndexMatch` needs to know
  /// "these two real, different places are equally plausible
  /// text-wise — let GPS decide," instead of confidently (and
  /// wrongly) committing to whichever happens to share more raw
  /// characters.
  static int wordLevelDistance(String a, String b) {
    final tokensA = a.toLowerCase().trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    final tokensB = b.toLowerCase().trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    if (tokensA.isEmpty) return tokensB.length;
    if (tokensB.isEmpty) return tokensA.length;

    var previousRow = List<int>.generate(tokensB.length + 1, (i) => i);
    var currentRow = List<int>.filled(tokensB.length + 1, 0);

    for (int i = 0; i < tokensA.length; i++) {
      currentRow[0] = i + 1;
      for (int j = 0; j < tokensB.length; j++) {
        final deletionCost = previousRow[j + 1] + 1;
        final insertionCost = currentRow[j] + 1;
        final substitutionCost = previousRow[j] + (tokensA[i] == tokensB[j] ? 0 : 1);
        currentRow[j + 1] = [deletionCost, insertionCost, substitutionCost].reduce((x, y) => x < y ? x : y);
      }
      final swap = previousRow;
      previousRow = currentRow;
      currentRow = swap;
    }
    return previousRow[tokensB.length];
  }
}
