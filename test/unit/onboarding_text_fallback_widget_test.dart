import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/onboarding/onboarding_screen.dart';
import 'package:vaishnavi/onboarding/voice/voice_onboarding_controller.dart';

/// P0 regression tests for the onboarding voice->text fallback gap,
/// at the widget layer: once
/// [VoiceOnboardingController.isTextFallbackActive] is true, the user
/// must actually SEE and be able to USE a text field — this is what
/// was missing before the fix (the controller correctly announced
/// "please type your answer" with nothing rendered to type into).
///
/// Uses [OnboardingScreen]'s test-only `controller` injection point
/// (`@visibleForTesting`) to drive the widget with manually-set
/// controller state and skip the real `start()` sequence, which needs
/// real Hive/permission/speech-plugin services this test process
/// doesn't have — see OnboardingScreen's doc comment on that
/// constructor parameter.
void main() {
  group('OnboardingScreen — text fallback (P0)', () {
    testWidgets('a TextField and submit button appear once text fallback is active', (tester) async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});
      controller.isTextFallbackActive = true;
      controller.displayText = 'Please type your answer.';

      await tester.pumpWidget(MaterialApp(home: OnboardingScreen(controller: controller)));
      await tester.pump();

      expect(find.byType(TextField), findsOneWidget);
      expect(find.byIcon(Icons.send), findsOneWidget);
    });

    testWidgets('the text field receives focus when fallback activates', (tester) async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});
      controller.isTextFallbackActive = true;

      await tester.pumpWidget(MaterialApp(home: OnboardingScreen(controller: controller)));
      // One extra pump for the post-frame focus callback to run.
      await tester.pump();
      await tester.pump();

      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.focusNode!.hasFocus, isTrue);
    });

    testWidgets('no TextField is shown when fallback is inactive', (tester) async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});
      controller.isTextFallbackActive = false;

      await tester.pumpWidget(MaterialApp(home: OnboardingScreen(controller: controller)));
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('no TextField is shown while paused, even if fallback is active', (tester) async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});
      controller.isTextFallbackActive = true;
      controller.isPaused = true;

      await tester.pumpWidget(MaterialApp(home: OnboardingScreen(controller: controller)));
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('tap choices take priority over the text field when both are present', (tester) async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});
      controller.isTextFallbackActive = true;
      controller.tapChoices = {'Yes': true, 'No': false};

      await tester.pumpWidget(MaterialApp(home: OnboardingScreen(controller: controller)));
      await tester.pump();

      expect(find.byType(TextField), findsNothing);
      expect(find.text('Yes'), findsOneWidget);
      expect(find.text('No'), findsOneWidget);
    });

    testWidgets('typing an answer and tapping submit calls submitTypedAnswer through the controller', (tester) async {
      final controller = VoiceOnboardingController(onOnboardingComplete: () {});
      controller.isTextFallbackActive = true;

      await tester.pumpWidget(MaterialApp(home: OnboardingScreen(controller: controller)));
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'Guindy');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();

      // submitTypedAnswer with no pending completer is a safe no-op
      // (see the controller-level tests for the completer-routing
      // behavior); this test only verifies the WIDGET wiring — that
      // tapping submit actually reaches the controller and clears the
      // field, instead of being an inert button.
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, isEmpty);
    });
  });
}
