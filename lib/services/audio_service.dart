import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../config/research_tools_config.dart';
import 'metrics/runtime_metrics_collector.dart';

class AudioService {
  final FlutterTts _flutterTts = FlutterTts();
  final SpeechToText _speechToText = SpeechToText();

  /// AUDIT FIX (BLOCKER 4): default listen/pause durations for
  /// [listen] — previously hardcoded at 30s/5s, which meant a
  /// completely silent or failed attempt could take up to ~35s before
  /// even reaching AudioService's own timeout branch. These are sized
  /// for a real-time, interactive voice-onboarding exchange (a short
  /// place name or yes/no answer, not open-ended dictation) — long
  /// enough for a normal spoken answer, short enough that a failed
  /// attempt doesn't leave the user waiting. Exposed as named
  /// parameters on [listen] (with these as defaults) rather than
  /// buried constants, so a caller with a genuinely different use
  /// case (e.g. free-form dictation) can override them instead of
  /// this file needing a new hardcoded value for every caller.
  static const Duration defaultListenFor = Duration(seconds: 10);
  static const Duration defaultPauseFor = Duration(seconds: 2);

  bool _isSpeechInitialized = false;

  /// Guards against the constructor's fire-and-forget `_initTts()` call
  /// still being in flight when a caller (e.g. `LanguageService.speak()`,
  /// right after onboarding sets a non-English language) invokes
  /// `setLanguage()`/`speak()`/`setVolume()` almost immediately after
  /// `AudioService()` is constructed. Without this, `_initTts()`'s own
  /// `setLanguage("en-US")` can complete AFTER the caller's real locale
  /// switch, silently reverting it back to English. Every public method
  /// below awaits this before touching `_flutterTts`.
  late final Future<void> _ready;

  AudioService() {
    _ready = _initTts();
    // AUDIT FIX (mic-permission handling): previously called
    // _initSpeech() here too, fire-and-forget, in parallel with TTS
    // init. speech_to_text's initialize() triggers the OS microphone
    // permission dialog on Android — calling it uncontrolled at
    // construction time meant that dialog could appear before ANY
    // spoken explanation had a chance to play, and before any caller
    // could know whether it was denied. STT now only initializes via
    // requestMicrophonePermission() (called explicitly, with a
    // spoken explanation first, by VoiceOnboardingController) or
    // lazily inside listen() as a defensive fallback — never eagerly
    // here.
  }

  Future<void> _initTts() async {
    await _flutterTts.awaitSpeakCompletion(true);
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
    await _flutterTts.setVolume(1.0);
    await _flutterTts.setPitch(1.0);
    // PHASE C TEMPORARY DIAGNOSTIC (warning-latency audit): fires when
    // audio playback actually begins, independent of when speak()'s
    // Future resolves (that happens on COMPLETION, since
    // awaitSpeakCompletion(true) is set above). This is the only way
    // to measure T9 (audio warning actually begins) rather than
    // approximate it from T8. Safe to remove after this phase.
    _flutterTts.setStartHandler(() {
      logLatency('T9_audioStart=${DateTime.now().toIso8601String()}');
    });
  }

  Future<void> _initSpeech() async {
    _isSpeechInitialized = await _speechToText.initialize(
      onError: (val) => print('Speech to text error: ${val.errorMsg}'),
      onStatus: (val) => print('Speech to text status: $val'),
    );
  }

  /// Explicitly requests microphone/speech-recognition availability —
  /// this is what actually triggers the OS permission dialog on
  /// Android (via `speech_to_text`'s own `initialize()`), so callers
  /// should speak an explanation of why the permission is needed
  /// BEFORE calling this, not after. Safe to call more than once
  /// (idempotent once granted; re-attempts if not). Returns whether
  /// speech recognition is actually usable right now — callers MUST
  /// check this and provide a non-voice fallback when it's false,
  /// rather than assuming `listen()` will eventually succeed.
  Future<bool> requestMicrophonePermission() async {
    if (!_isSpeechInitialized) {
      await _initSpeech();
    }
    return _isSpeechInitialized;
  }

  bool _isSpeaking = false;

  /// Read-only speaking state, added for the developer debug
  /// dashboard's "current speech status" display. Does not change
  /// speak()'s existing behavior (still awaits completion exactly as
  /// before) — just tracks it.
  bool get isSpeaking => _isSpeaking;

  /// Read-only listening state, added for the developer debug
  /// dashboard's "current speech status" display.
  bool get isListening => _speechToText.isListening;

  /// Switches the TTS engine's locale (e.g. 'ta-IN', 'hi-IN'). Added
  /// for Milestone 6 (Multilingual Accessibility) — does not change
  /// how speak()/listen() work, only which locale voice is used.
  /// Callers should await this before the next speak() call.
  ///
  /// Re-asserts `awaitSpeakCompletion(true)` immediately after the
  /// locale switch: on Android, changing the TTS engine's language can
  /// silently reset its completion-tracking registration on some
  /// OS/OEM TTS engine implementations, which otherwise makes
  /// speak()'s Future resolve as soon as text is handed to the engine
  /// rather than when audio playback actually finishes — the voice
  /// onboarding conversation would then "speak questions continuously"
  /// without truly waiting, exactly for every prompt spoken after a
  /// language switch. This was found and fixed after that symptom was
  /// reported on a real device.
  Future<void> setLanguage(String localeCode) async {
    await _ready;
    await _flutterTts.setLanguage(localeCode);
    await _flutterTts.awaitSpeakCompletion(true);
  }

  /// Sets TTS output volume, 0.0 (silent) to 1.0 (full). Added for the
  /// onboarding Voice Preview step's "Adjust Volume" control — does
  /// not change speak()'s behavior otherwise, and the default (1.0,
  /// set in `_initTts`) is unaffected unless a caller explicitly
  /// changes it.
  Future<void> setVolume(double volume) async {
    await _ready;
    _currentVolume = volume.clamp(0.0, 1.0);
    await _flutterTts.setVolume(_currentVolume);
  }

  double _currentVolume = 1.0;

  /// Read-only current volume, so the Voice Preview screen can
  /// initialize its slider to the actual current value rather than
  /// assuming 1.0.
  double get currentVolume => _currentVolume;

  // AUDIT ADD (Phase C3 — TTS/detection concurrency fix): callers
  // (specifically `navigation_screen.dart`'s per-frame hazard-warning
  // path) no longer `await` this method to completion before
  // continuing — see that call site's own comment for why (it was
  // blocking ALL camera-frame/YOLO/hazard-decision processing for the
  // full duration of every spoken utterance, confirmed via on-device
  // measurement). That means MULTIPLE `speak()` calls can now
  // genuinely overlap in time from the CALLER's perspective. Without
  // this queue, two concurrent calls would both reach
  // `_flutterTts.speak()` at once — undefined/garbled native audio
  // behavior, and `_isSpeaking`/the latency stopwatch would be
  // corrupted by whichever call's `finally` block happens to run
  // first. This chain makes concurrent callers safely ORDERED instead:
  // each call waits for whichever call was pending before it to reach
  // the native engine before starting its own, so audio is still
  // played one utterance at a time — callers just don't have to wait
  // for that ordering to finish before doing other work.
  Future<void>? _pendingSpeech;

  Future<void> speak(String text) async {
    await _ready;
    // Re-asserted here too (not just in setLanguage()) as a defensive
    // guard: this is the exact contract voice onboarding's
    // speak-then-listen sequencing depends on, so it's cheap insurance
    // against any other future code path resetting it silently.
    await _flutterTts.awaitSpeakCompletion(true);

    final previous = _pendingSpeech;
    final completer = Completer<void>();
    _pendingSpeech = completer.future;
    if (previous != null) {
      // Wait for whatever was queued ahead of this call to actually
      // reach the native engine (not necessarily finish playing —
      // see the `finally` block below, which completes as soon as
      // `_flutterTts.speak()` itself returns) before starting this one.
      await previous;
    }

    _isSpeaking = true;
    // Metrics-only instrumentation (Speech Latency): measures exactly
    // the same await this method already performs — does not add any
    // delay, retry, or change to what's spoken.
    final stopwatch = Stopwatch()..start();
    try {
      await _flutterTts.speak(text);
    } finally {
      stopwatch.stop();
      RuntimeMetricsCollector.instance.recordSpeechLatencyMs(
        stopwatch.elapsedMicroseconds / 1000.0,
      );
      _isSpeaking = false;
      completer.complete();
    }
  }

  Future<void> stopSpeaking() async {
    await _flutterTts.stop();
    // AUDIT ADD (Phase C3): also drop the queue pointer itself, not
    // just the currently-playing native utterance. Without this, an
    // URGENT interrupting `speak()` call made right after this one
    // would still `await previous` on whatever routine message was
    // queued behind the one just stopped, delaying the very warning
    // this call was meant to make immediate. Any call already
    // `await`ing the old `_pendingSpeech` future is unaffected — it
    // still resolves normally once the just-stopped utterance's own
    // `finally` block runs — this only stops NEW callers from lining
    // up behind stale queued speech.
    _pendingSpeech = null;
  }

  String _lastWords = "";

  /// AUDIT FIX (Phase 1B — confidence handling): populated with the
  /// STT engine's own confidence for the most recent FINAL result
  /// (0.0–1.0, or -1.0 on platforms/engines that don't report one —
  /// see the `speech_to_text` package docs). Read this right after a
  /// `listen()` callback fires if a caller wants to treat a
  /// low-confidence recognition differently (e.g. asking for
  /// confirmation more assertively). Reset to null at the start of
  /// every `listen()` call so a stale value from a previous question
  /// can never be misread as belonging to the current one.
  double? lastConfidence;

  /// [localeId] added for voice onboarding (Stage 1): lets a caller
  /// request speech recognition in a specific locale (e.g. 'ta-IN')
  /// instead of always using the device's default STT locale, which
  /// otherwise stays English even after `setLanguage()` switches TTS.
  /// Omit it for the original, unchanged behavior.
  Future<void> listen(
    Function(String) onResult, {
    Function(String)? onError,
    String? localeId,
    Duration listenFor = defaultListenFor,
    Duration pauseFor = defaultPauseFor,
  }) async {
    if (!_isSpeechInitialized) {
      _isSpeechInitialized = await _speechToText.initialize();
    }

    // AUDIT FIX (Phase 1B — "preventing multiple simultaneous
    // listeners" / "cancellation of stale listeners"): previously
    // nothing checked whether a PREVIOUS listen() session was still
    // active before starting a new one. If a caller ever invoked
    // listen() again in quick succession (e.g. a stale 40s timeout in
    // VoiceOnboardingController firing just as pause/resume kicks off
    // a fresh question), the old session's still-live STT engine
    // could keep recognizing speech and firing its OLD callbacks
    // concurrently with the new session's — cross-question recognition
    // leakage. Explicitly stopping any in-flight session first makes
    // "one active listener at a time" an actual invariant, not just
    // the common case.
    if (_speechToText.isListening) {
      await _speechToText.stop();
    }

    if (_isSpeechInitialized) {
      _lastWords = "";
      lastConfidence = null;
      bool hasFinished = false;

      // AUDIT FIX: statusListener/errorListener are now assigned
      // BEFORE calling `.listen(...)`, not after. Assigning them
      // afterward left a race window — on a very fast
      // error/status transition, the plugin could fire before this
      // code got a chance to attach its own handlers, silently
      // swallowing that event (the specific failure mode "empty-result
      // handling" and "timeout" fallback logic below depend on these
      // handlers actually being attached in time).
      _speechToText.statusListener = (status) {
        if (status == 'done' || status == 'notListening') {
          if (_lastWords.isNotEmpty && !hasFinished) {
            hasFinished = true;
            onResult(_lastWords);
            _lastWords = "";
          } else if (!_speechToText.isListening && !hasFinished) {
            if (onError != null) onError("timeout");
          }
        }
      };

      _speechToText.errorListener = (error) {
        if (error.errorMsg != 'error_no_match' && !hasFinished) {
          if (_lastWords.isNotEmpty) {
            hasFinished = true;
            onResult(_lastWords);
            _lastWords = "";
          } else if (onError != null) {
            onError(error.errorMsg);
          }
        }
      };

      await _speechToText.listen(
        onResult: (result) {
          if (result.recognizedWords.isNotEmpty) {
            _lastWords = result.recognizedWords;
          }
          if (result.finalResult && _lastWords.isNotEmpty && !hasFinished) {
            hasFinished = true;
            lastConfidence = result.confidence;
            onResult(_lastWords);
            _lastWords = "";
          }
        },
        listenFor: listenFor,
        pauseFor: pauseFor,
        localeId: localeId,
        listenOptions: SpeechListenOptions(
          cancelOnError: false,
          partialResults: true,
        ),
      );
    } else {
      print("Speech recognition not initialized");
    }
  }

  Future<void> stopListening() async {
    await _speechToText.stop();
  }

  /// Stops both underlying engines. Safe to call at any point in the
  /// widget lifecycle (e.g. even if construction is still in flight,
  /// or nothing is currently speaking/listening) — each stop is
  /// wrapped so one engine failing to stop can't prevent the other
  /// from being asked to. Does not change any other runtime behavior;
  /// this is cleanup only, not a new feature.
  Future<void> dispose() async {
    try {
      await _flutterTts.stop();
    } catch (e) {
      // ignore: avoid_print
      print('AudioService.dispose: flutterTts.stop failed (non-fatal): $e');
    }
    try {
      await _speechToText.stop();
    } catch (e) {
      // ignore: avoid_print
      print('AudioService.dispose: speechToText.stop failed (non-fatal): $e');
    }
  }
}
