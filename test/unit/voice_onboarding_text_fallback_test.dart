import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/onboarding/voice/voice_onboarding_controller.dart';

/// P0 regression tests for the onboarding voice->text fallback gap:
/// after [VoiceOnboardingController.maxVoiceAttemptsBeforeTextFallback]
/// failed voice attempts on a single question, the controller
/// correctly switches to a text-only wait (`forceTextOnly`) — this
/// exercises the REAL [VoiceOnboardingController] and its REAL
/// [VoiceOnboardingController.debugAwaitAnswerForTest] entry point
/// into the private answer-processing pipeline (not a re-
/// implementation of it), verifying the controller-side half of the
/// fix: [VoiceOnboardingController.isTextFallbackActive] becomes the
/// single source of truth the UI keys its TextField visibility off
/// (see OnboardingScreen), STT is not left running, and a typed/
/// tapped answer resolves through the exact same completer a spoken
/// answer would.
///
/// Deliberately only exercises the `forceTextOnly: true` path —
/// `forceTextOnly: false` calls `audioService.listen(...)`, which
/// needs a real speech-recognition platform this test process doesn't
/// have (see debugAwaitAnswerForTest's doc comment).
void main() {
  // VoiceOnboardingController's constructor creates an AudioService,
  // which constructs a FlutterTts — that touches a platform method
  // channel immediately (setMethodCallHandler), which asserts the
  // Flutter test binding is initialized. testWidgets() does this
  // automatically; plain test() blocks (used throughout this file,
  // since none of these tests need a widget tree) do not, so it's
  // done explicitly here — same pattern as
  // test/unit/voice_event_export_test.dart.
  TestWidgetsFlutterBinding.ensureInitialized();

  // AudioService's constructor also fires a fire-and-forget
  // `_initTts()` that awaits several real `flutter_tts` platform-
  // channel calls (awaitSpeakCompletion/setLanguage/setSpeechRate/
  // setVolume/setPitch) with no platform implementation registered in
  // this test process — without a mock handler those calls throw
  // MissingPluginException asynchronously, uncaught, and crash into
  // whichever test happens to be running when the fire-and-forget
  // Future settles. This stands in for the real platform exactly like
  // a device's TTS engine would, returning a benign success value (1
  // — this plugin's own convention) for every call.
  const flutterTtsChannel = MethodChannel('flutter_tts');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    flutterTtsChannel,
    (MethodCall call) async => 1,
  );

  group('VoiceOnboardingController — text fallback (P0)', () {
    test('maxVoiceAttemptsBeforeTextFallback is 3 (three failed voice attempts trigger fallback)', () {
      expect(VoiceOnboardingController.maxVoiceAttemptsBeforeTextFallback, 3);
    });

    test('a forceTextOnly wait activates text fallback and does not touch the microphone', () async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});
      expect(controller.isTextFallbackActive, isFalse);

      final future = controller.debugAwaitAnswerForTest(
        attempt: VoiceOnboardingController.maxVoiceAttemptsBeforeTextFallback,
        forceTextOnly: true,
      );
      // Let the controller's internal microtasks run up to the point
      // where it's actually waiting on the pending answer.
      await Future<void>.delayed(Duration.zero);

      expect(controller.isTextFallbackActive, isTrue, reason: 'the UI must know to show a text field here');
      expect(controller.isListening, isFalse, reason: 'STT must not be active while text fallback is shown');

      controller.submitTypedAnswer('Guindy');
      await future;
    });

    test('a typed answer during text fallback resolves through the same answer pipeline as voice/tap', () async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});

      final future = controller.debugAwaitAnswerForTest(attempt: 3, forceTextOnly: true);
      await Future<void>.delayed(Duration.zero);

      controller.submitTypedAnswer('Guindy');
      final result = await future;

      expect(result.wasTapped, isFalse);
      expect(result.text, 'Guindy');
      // Fallback clears once this question's answer has resolved.
      expect(controller.isTextFallbackActive, isFalse);
    });

    test('a tapped answer still resolves a forceTextOnly wait (choice questions keep working by tap)', () async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});

      final future = controller.debugAwaitAnswerForTest(attempt: 3, forceTextOnly: true);
      await Future<void>.delayed(Duration.zero);

      controller.submitTapChoice('some_choice_value');
      final result = await future;

      expect(result.wasTapped, isTrue);
      expect(result.tappedValue, 'some_choice_value');
    });

    test('an empty/whitespace-only typed answer does not resolve the wait (no incorrect advance)', () async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});

      final future = controller.debugAwaitAnswerForTest(attempt: 3, forceTextOnly: true);
      await Future<void>.delayed(Duration.zero);

      controller.submitTypedAnswer('   '); // whitespace-only — must be a no-op
      expect(controller.isTextFallbackActive, isTrue, reason: 'still waiting — nothing valid was submitted yet');

      controller.submitTypedAnswer('Guindy'); // now a real answer
      final result = await future;
      expect(result.text, 'Guindy');
    });

    test('submitting again after the answer already resolved is a safe no-op (no duplicate submission)', () async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});

      final future = controller.debugAwaitAnswerForTest(attempt: 3, forceTextOnly: true);
      await Future<void>.delayed(Duration.zero);

      controller.submitTypedAnswer('first answer');
      final result = await future;
      expect(result.text, 'first answer');

      // Nothing pending anymore — must not throw, and must not have
      // anywhere to route a "second" answer.
      expect(() => controller.submitTypedAnswer('second answer'), returnsNormally);
      expect(() => controller.submitTapChoice('tap'), returnsNormally);
    });

    test('each answer wait is isolated — resolving one never affects a later, separate wait', () async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});

      final first = controller.debugAwaitAnswerForTest(attempt: 3, forceTextOnly: true);
      await Future<void>.delayed(Duration.zero);
      controller.submitTypedAnswer('first answer');
      expect((await first).text, 'first answer');
      expect(controller.isTextFallbackActive, isFalse);

      // A brand-new wait for a different question — must start clean.
      final second = controller.debugAwaitAnswerForTest(attempt: 3, forceTextOnly: true);
      await Future<void>.delayed(Duration.zero);
      expect(controller.isTextFallbackActive, isTrue);

      controller.submitTypedAnswer('second answer');
      expect((await second).text, 'second answer');
    });
  });
}
