import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/audio_service.dart';

/// PHASE C3 — TTS/detection concurrency fix.
///
/// Verifies the NEW behavior added to [AudioService.speak]/
/// [AudioService.stopSpeaking]: since `navigation_screen.dart`'s
/// hazard-warning call site no longer `await`s [AudioService.speak]
/// before continuing (see that call site's own comment — it used to
/// block ALL camera-frame/detection processing for the full spoken
/// duration), concurrent callers can now genuinely overlap in time.
/// This file proves that overlap is handled SAFELY: calls to the
/// underlying `flutter_tts` platform channel's `speak` method are
/// never made concurrently (which would be undefined/garbled native
/// audio), and an interrupting [AudioService.stopSpeaking] correctly
/// lets a subsequent urgent call skip ahead of stale queued speech.
///
/// Uses a controllable mock for the `flutter_tts` platform channel
/// (same technique as `voice_onboarding_text_fallback_test.dart`) so
/// the exact moment each `speak` platform call resolves can be driven
/// by the test, which is the only way to deterministically observe
/// "did call B's platform speak fire before call A's resolved."
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');

  late List<String> nativeSpeakCalls;
  late Map<String, Completer<dynamic>> pendingNativeSpeaks;

  setUp(() {
    nativeSpeakCalls = [];
    pendingNativeSpeaks = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        if (call.method == 'speak') {
          final text = call.arguments as String;
          nativeSpeakCalls.add(text);
          final completer = Completer<dynamic>();
          pendingNativeSpeaks[text] = completer;
          // Mirrors the real platform's behavior with
          // awaitSpeakCompletion(true): the native `speak` call does
          // not resolve until playback actually finishes -- the test
          // controls exactly when that happens via `completer`.
          return completer.future;
        }
        if (call.method == 'stop') {
          // Real platforms resolve any in-flight speak's completion
          // (as an interruption) when stop() is called -- mirror that
          // so AudioService's own await on `_flutterTts.speak()`
          // unblocks, exactly as it would on a real device.
          for (final c in pendingNativeSpeaks.values) {
            if (!c.isCompleted) c.complete(1);
          }
          return 1;
        }
        return 1; // benign success for setup calls (awaitSpeakCompletion, setLanguage, etc.)
      },
    );
  });

  group('AudioService TTS queueing (Phase C3)', () {
    test('two concurrent speak() calls never reach the native platform simultaneously', () async {
      final audio = AudioService();
      await Future<void>.delayed(Duration.zero); // let constructor's fire-and-forget _initTts settle

      final futureA = audio.speak('first message');
      final futureB = audio.speak('second message');

      // Give both calls a chance to run their microtasks.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Only the FIRST call should have reached the native platform --
      // the second must still be queued behind it in AudioService's
      // own chain, not racing it.
      expect(nativeSpeakCalls, ['first message'], reason: 'the second speak() must not reach the native platform until the first completes');

      // Resolve the first native call -- this should unblock the queue.
      pendingNativeSpeaks['first message']!.complete(1);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(nativeSpeakCalls, ['first message', 'second message'], reason: 'the second call proceeds only after the first genuinely finished');

      pendingNativeSpeaks['second message']!.complete(1);
      await futureA;
      await futureB;
    });

    test('stopSpeaking() lets a subsequent urgent call skip ahead of stale queued speech', () async {
      final audio = AudioService();
      await Future<void>.delayed(Duration.zero);

      // Queue up two ROUTINE messages (mirrors two ordinary navigation
      // instructions firing before an urgent hazard is detected).
      final futureA = audio.speak('routine A');
      final futureB = audio.speak('routine B');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(nativeSpeakCalls, ['routine A']);

      // An urgent hazard interrupts.
      await audio.stopSpeaking(); // stops "routine A" (fulfills its native completer) AND drops the queue pointer
      final urgentFuture = audio.speak('URGENT stop');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        nativeSpeakCalls.last,
        'URGENT stop',
        reason: 'the urgent call must not wait behind "routine B", which was still queued when stopSpeaking() was called',
      );

      // Clean up remaining completers so the test doesn't hang.
      for (final c in pendingNativeSpeaks.values) {
        if (!c.isCompleted) c.complete(1);
      }
      await futureA;
      // "routine B" is still chained behind the ORIGINAL (now-abandoned)
      // pointer and will complete once its own native call eventually
      // resolves -- it's simply no longer on the path new callers wait on.
      await futureB;
      await urgentFuture;
    });

    test('isSpeaking accurately reflects whichever call is currently on the native platform', () async {
      final audio = AudioService();
      await Future<void>.delayed(Duration.zero);
      expect(audio.isSpeaking, isFalse);

      final future = audio.speak('message');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(audio.isSpeaking, isTrue);

      pendingNativeSpeaks['message']!.complete(1);
      await future;
      expect(audio.isSpeaking, isFalse);
    });
  });
}
