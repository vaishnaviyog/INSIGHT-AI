/// Pure yes/no interpretation for spoken confirmation exchanges —
/// deliberately separated from `AudioService`/`flutter_tts`/
/// `speech_to_text` so it can be unit-tested without any platform
/// channel (the codebase's own established pattern — see
/// `DestinationResolver`, `FuzzyMatcher`).
///
/// PHASE E (safety/responsiveness hardening) ADD: previously, every
/// confirmation call site in this app individually decided what counted
/// as "yes" (usually: anything that ISN'T an explicit "no" — see
/// `navigation_screen.dart`'s old "Did you mean X?" flow). That is
/// unsafe for a user who can't see the screen to catch a
/// misinterpretation: silence, a garbled STT result, or an unrelated
/// utterance would all have been treated as acceptance. This requires
/// an EXPLICIT affirmative signal instead — anything that isn't clearly
/// yes or clearly no is [VoiceConfirmationOutcome.ambiguous], and every
/// call site must handle that case by asking again rather than
/// proceeding.
enum VoiceConfirmationOutcome { affirmative, negative, ambiguous }

/// Checked in this exact order, each one short-circuiting:
/// 1. Negative — a contradictory or confused answer ("yes, no,
///    wait...") must never be treated as acceptance.
/// 2. Uncertainty ("not sure", "I don't know", "maybe") — checked
///    BEFORE affirmative specifically because "not sure" contains the
///    word "sure," which alone is a valid affirmative. Without this
///    ordering, uncertainty would be misread as acceptance — a real
///    bug this file's own test caught before it ever reached
///    production. Uncertainty is [VoiceConfirmationOutcome.ambiguous],
///    not negative — the caller should ask again, not treat it as a
///    rejection.
/// 3. Affirmative.
/// When in doubt, this errs toward "ask again," not "assume yes."
VoiceConfirmationOutcome interpretYesNoAnswer(String? answer) {
  if (answer == null || answer.trim().isEmpty) return VoiceConfirmationOutcome.ambiguous;
  final normalized = answer.trim().toLowerCase();

  final negative = RegExp(r'\b(no|nope|nah|wrong|incorrect|not\s+right|not\s+correct)\b').hasMatch(normalized);
  if (negative) return VoiceConfirmationOutcome.negative;

  final uncertain =
      RegExp(r"\b(not\s+sure|unsure|don'?t\s+know|no\s+idea|not\s+certain|maybe|i\s+think\s+so)\b").hasMatch(normalized);
  if (uncertain) return VoiceConfirmationOutcome.ambiguous;

  final affirmative =
      RegExp(r"\b(yes|yeah|yep|yup|correct|confirm(ed)?|right|that's\s+right|sure|ok|okay)\b").hasMatch(normalized);
  if (affirmative) return VoiceConfirmationOutcome.affirmative;

  return VoiceConfirmationOutcome.ambiguous;
}

/// Outcome of the Phase E3 boarding-verification exchange — layered on
/// top of [interpretYesNoAnswer] with one addition: a spoken route
/// number/name that matches the expected route is ALSO accepted as
/// confirmation (the user may answer by reading the number off the
/// bus rather than saying a bare "yes").
enum BoardingVerificationOutcome { confirmed, rejected, ambiguous }

BoardingVerificationOutcome interpretBoardingVerificationAnswer(
  String? answer, {
  String? expectedRouteShortName,
}) {
  if (answer != null) {
    // Boarding-specific rejection phrasing ("a different bus," "not my
    // bus") that a generic yes/no interpreter shouldn't need to know
    // about — kept local to this function rather than added to
    // [interpretYesNoAnswer]'s vocabulary, which is also used for
    // unrelated confirmations (e.g. destination confirmation) where
    // "different" doesn't reliably mean rejection.
    final boardingSpecificRejection =
        RegExp(r'\b(different\s+bus|not\s+(my|this)\s+bus|not\s+this\s+one)\b').hasMatch(answer.trim().toLowerCase());
    if (boardingSpecificRejection) return BoardingVerificationOutcome.rejected;
  }

  final yesNo = interpretYesNoAnswer(answer);
  if (yesNo == VoiceConfirmationOutcome.negative) return BoardingVerificationOutcome.rejected;
  if (yesNo == VoiceConfirmationOutcome.affirmative) return BoardingVerificationOutcome.confirmed;

  if (answer != null && expectedRouteShortName != null && expectedRouteShortName.trim().isNotEmpty) {
    final normalizedExpected = expectedRouteShortName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    final normalizedAnswer = answer.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (normalizedExpected.isNotEmpty && normalizedAnswer.contains(normalizedExpected)) {
      return BoardingVerificationOutcome.confirmed;
    }
  }

  return BoardingVerificationOutcome.ambiguous;
}
