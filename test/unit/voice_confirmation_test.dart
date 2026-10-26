import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/voice_understanding/voice_confirmation.dart';

/// Phase E1/E3 regression coverage for the shared yes/no + boarding
/// verification interpreter. Pure logic, no platform channel — see
/// voice_confirmation.dart's own doc comment for why this is
/// deliberately separated from AudioService/STT.
void main() {
  group('interpretYesNoAnswer', () {
    test('clear affirmatives', () {
      for (final s in ['yes', 'Yes', 'yeah', 'yep', 'yup', 'correct', 'confirmed', 'confirm', "that's right", 'right', 'sure', 'ok', 'okay']) {
        expect(interpretYesNoAnswer(s), VoiceConfirmationOutcome.affirmative, reason: 'expected "$s" to be affirmative');
      }
    });

    test('clear negatives', () {
      for (final s in ['no', 'No', 'nope', 'nah', 'wrong', 'incorrect', 'not right', 'not correct']) {
        expect(interpretYesNoAnswer(s), VoiceConfirmationOutcome.negative, reason: 'expected "$s" to be negative');
      }
    });

    test('null, empty, and unrelated speech is ambiguous, never assumed affirmative', () {
      for (final s in [null, '', '   ', 'Anna Nagar', 'what time is it', 'hmm', 'maybe']) {
        expect(interpretYesNoAnswer(s), VoiceConfirmationOutcome.ambiguous,
            reason: 'expected "$s" to be ambiguous, not silently accepted');
      }
    });

    test('"know" does not false-positive match "no"', () {
      expect(interpretYesNoAnswer('I know that place'), VoiceConfirmationOutcome.ambiguous);
    });

    test('a contradictory answer containing both "yes" and "no" is treated as negative, never accepted', () {
      // Safety-biased: never silently accept an ambiguous/contradictory answer.
      expect(interpretYesNoAnswer('yes no wait'), VoiceConfirmationOutcome.negative);
    });

    test('confidence-word "right" inside an unrelated sentence still counts (documented limitation)', () {
      // "right" is a short, common word — this is a known false-positive
      // surface, accepted deliberately to keep the affirmative list broad
      // for natural speech ("that's right", "right, yes").
      expect(interpretYesNoAnswer('right'), VoiceConfirmationOutcome.affirmative);
    });

    test('REGRESSION: "not sure" is ambiguous, never affirmative (the bare word "sure" must not leak through)', () {
      expect(interpretYesNoAnswer('I am not sure'), VoiceConfirmationOutcome.ambiguous);
      expect(interpretYesNoAnswer('not sure'), VoiceConfirmationOutcome.ambiguous);
      expect(interpretYesNoAnswer("I don't know"), VoiceConfirmationOutcome.ambiguous);
      expect(interpretYesNoAnswer('maybe'), VoiceConfirmationOutcome.ambiguous);
      // "sure" alone, with no negation, is still a valid affirmative.
      expect(interpretYesNoAnswer('sure'), VoiceConfirmationOutcome.affirmative);
    });
  });

  group('interpretBoardingVerificationAnswer', () {
    test('explicit yes confirms regardless of expected route', () {
      expect(interpretBoardingVerificationAnswer('yes', expectedRouteShortName: '21G'),
          BoardingVerificationOutcome.confirmed);
    });

    test('explicit no/wrong bus rejects', () {
      expect(interpretBoardingVerificationAnswer('no', expectedRouteShortName: '21G'), BoardingVerificationOutcome.rejected);
      expect(interpretBoardingVerificationAnswer('wrong bus', expectedRouteShortName: '21G'),
          BoardingVerificationOutcome.rejected);
      expect(interpretBoardingVerificationAnswer('this is a different bus', expectedRouteShortName: '21G'),
          BoardingVerificationOutcome.rejected);
    });

    test('spoken route number matching the expected route confirms', () {
      expect(interpretBoardingVerificationAnswer('21G', expectedRouteShortName: '21G'), BoardingVerificationOutcome.confirmed);
      expect(interpretBoardingVerificationAnswer('it says 21 G on the front', expectedRouteShortName: '21G'),
          BoardingVerificationOutcome.confirmed);
      expect(interpretBoardingVerificationAnswer('twenty one g', expectedRouteShortName: '21G'),
          BoardingVerificationOutcome.ambiguous,
          reason: 'spelled-out digits are not normalized — a real limitation, not silently treated as a match');
    });

    test('a mismatched route number is ambiguous, not silently confirmed', () {
      // The user read a DIFFERENT number off the bus (45B, not 21G) —
      // this must never be treated as confirmation.
      expect(interpretBoardingVerificationAnswer('45B', expectedRouteShortName: '21G'), BoardingVerificationOutcome.ambiguous);
    });

    test('silence/timeout/unrelated speech is ambiguous, never silently confirmed', () {
      for (final s in [null, '', 'hello', 'I am not sure']) {
        expect(interpretBoardingVerificationAnswer(s, expectedRouteShortName: '21G'), BoardingVerificationOutcome.ambiguous,
            reason: 'expected "$s" to require another attempt, not silently confirm boarding');
      }
    });

    test('works with no expected route known (falls back to plain yes/no)', () {
      expect(interpretBoardingVerificationAnswer('yes', expectedRouteShortName: null), BoardingVerificationOutcome.confirmed);
      expect(interpretBoardingVerificationAnswer('21G', expectedRouteShortName: null), BoardingVerificationOutcome.ambiguous);
    });
  });
}
