import 'package:flutter/material.dart';
import '../services/audio_service.dart';
import '../services/language_service.dart';
import '../services/navigation_session_persistence_service.dart';
import 'navigation_screen.dart';
import 'profile_settings_screen.dart';
import '../main.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final AudioService _audioService = AudioService();
  final LanguageService _languageService = LanguageService();
  final NavigationSessionPersistenceService _sessionPersistenceService =
      NavigationSessionPersistenceService();
  String _statusText = "Press START to Begin";
  bool _isListening = false;
  bool _isNavigating = false;
  bool _hasStarted = false;
  bool _enableObjectDetection = true;

  /// Guards against `_startInteraction` (triggered by the user tapping
  /// START) running before `_languageService.initialize()` has
  /// actually loaded the Hive-stored language preference — without
  /// this, a fast tap right after launch could speak the very first
  /// prompt in English regardless of what was chosen during
  /// onboarding, since `LanguageService.currentLanguage` defaults to
  /// English until `initialize()` completes. Same class of race as
  /// the one fixed in `AudioService`.
  late final Future<void> _languageReady;

  @override
  void initState() {
    super.initState();
    _languageReady = _languageService.initialize();
    // AUDIT ADD (CRITICAL background state persistence fix): this
    // screen is only ever created once, at app cold-start (see
    // MyApp's `home:`) — exactly the moment a previously-active
    // navigation session (destination + route) may have just been
    // lost to an OS/OEM background process kill (confirmed live on
    // this device — see NavigationSessionPersistenceService's doc
    // comment). Runs unawaited, matching this class's existing
    // `_languageReady` pattern — initState() itself cannot be async.
    _checkForRestorableSession();
  }

  /// If a fresh (see NavigationSessionPersistenceService.maxSessionAge)
  /// saved destination exists, skips the normal START-button/voice
  /// flow entirely and goes straight to [NavigationScreen] with
  /// `isRestoredSession: true` — reusing the EXACT same construction
  /// path a normal voice-captured destination already uses, so every
  /// existing route-fetch/failure-handling behavior applies unchanged.
  /// Does nothing (leaves the normal START button showing) if nothing
  /// was saved, matching this fix's explicit scope: restore when
  /// possible, never fabricate a session that wasn't really there.
  Future<void> _checkForRestorableSession() async {
    await _sessionPersistenceService.initialize();
    final savedDestination = await _sessionPersistenceService.loadFreshActiveDestination();
    if (savedDestination == null || !mounted) return;

    await _languageReady;
    setState(() {
      _hasStarted = true;
      _statusText = "Restoring your previous navigation to $savedDestination...";
    });
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => NavigationScreen(
          destination: savedDestination,
          camera: cameras.first,
          enableObjectDetection: _enableObjectDetection,
          isRestoredSession: true,
        ),
      ),
    );
  }

  Future<void> _startInteraction() async {
    await _languageReady;
    _isNavigating = false;
    setState(() {
      _hasStarted = true;
      _statusText = "Where do you want to go?";
    });

    await _languageService.speak(_audioService, "Where do you want to go?");

    // AUDIT FIX (Phase E1D — listening feedback): previously a SILENT
    // 800ms delay separated the spoken question from the mic actually
    // starting to listen — a user who can't see the screen had no way
    // to know when to start speaking, only when the QUESTION finished.
    // A short, one-word cue replaces that silent gap: `speak()` only
    // resolves once `awaitSpeakCompletion(true)` confirms audio
    // playback has genuinely finished (see AudioService's own doc
    // comment), so this adds no new echo/self-triggering risk — it's
    // the same pause, just filled with an explicit signal instead of
    // silence.
    await _languageService.speak(_audioService, "Listening.");

    setState(() {
      _isListening = true;
      _statusText = "Listening for destination...";
    });

    await _audioService.listen(
      (recognizedWords) async {
        if (recognizedWords.isNotEmpty && !_isNavigating) {
          _isNavigating = true;
          setState(() {
            _isListening = false;
            _statusText = "Destination: $recognizedWords";
          });

          await _audioService.stopListening();
          await _languageService.speak(_audioService, "Calculating route to $recognizedWords");

          if (mounted) {
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (context) => NavigationScreen(
                  destination: recognizedWords,
                  camera: cameras.first,
                  enableObjectDetection: _enableObjectDetection,
                ),
              ),
            );
          }
        }
      },
      onError: (errorMsg) {
        if (mounted) {
          setState(() {
            _isListening = false;
            if (errorMsg == "timeout") {
              _statusText = "Didn't hear anything. Please tap Start again.";
              _hasStarted = false;
            } else {
              _statusText = "Error: $errorMsg";
              _hasStarted = false;
            }
          });
        }
      },
      // AUDIT NOTE (Phase E1C — STT timing investigation): the
      // default `pauseFor` (2s, see AudioService.defaultPauseFor) is
      // tuned for a short, single-beat answer (a yes/no, a one-word
      // place name). This is specifically the DESTINATION-CAPTURE
      // call — the one place a genuinely multi-word answer ("Anna
      // Nagar," "Chennai Central," "Vandalur Zoo") is expected, where
      // a natural mid-phrase pause is most likely to be mistaken for
      // end-of-speech and finalize the recognition early. Extended to
      // 3s here ONLY — not changed globally, and not "something huge"
      // — a modest, bounded increase (+1s worst-case latency) rather
      // than a guess at a large number with no evidence behind it.
      // IMPORTANT: this does not, by itself, prove or disprove the
      // reported "Anna Nagar" -> "Anna" truncation — that could not be
      // reproduced anywhere in the destination-TEXT pipeline (see
      // destination_resolver.dart's doc comment and the read-only
      // audit), so it may be exactly this class of premature-
      // finalization instead. Real confirmation requires a live
      // microphone test, which this environment cannot perform — this
      // is a reasoned, low-risk mitigation, not a verified fix.
      pauseFor: const Duration(seconds: 3),
    );
  }

  @override
  void dispose() {
    _audioService.dispose();
    _languageService.dispose();
    // Deliberately NOT closing _sessionPersistenceService's Hive box
    // here: this dispose() fires on the normal pushReplacement to
    // NavigationScreen too (not just a genuine app teardown), and
    // NavigationScreen opens the SAME box by name moments later — Hive
    // boxes are long-lived, app-scoped resources (same pattern already
    // used by EmergencyService/BehaviourLearningService elsewhere in
    // this app), so there is nothing to gain from closing it here and
    // a real (if small) race to avoid by not doing so.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: !_hasStarted
          ? AppBar(
              backgroundColor: Colors.transparent,
              elevation: 0,
              actions: [
                Semantics(
                  button: true,
                  label: 'Profile and Preferences settings',
                  child: IconButton(
                    icon: const Icon(Icons.settings),
                    onPressed: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const ProfileSettingsScreen()),
                      );
                    },
                  ),
                ),
              ],
            )
          : null,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (!_hasStarted) ...[
              SizedBox(
                width: 250,
                height: 250,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepPurpleAccent,
                    shape: const CircleBorder(),
                  ),
                  onPressed: _startInteraction,
                  child: const Text('START', style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 30),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text(
                    "Enable Extra object detection",
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 10),
                  Switch(
                    value: _enableObjectDetection,
                    activeColor: Colors.deepPurpleAccent,
                    onChanged: (val) {
                      setState(() {
                        _enableObjectDetection = val;
                      });
                    },
                  ),
                ],
              )
            ] else ...[
              Icon(
                _isListening ? Icons.mic : Icons.mic_none,
                size: 100,
                color: _isListening ? Colors.redAccent : Colors.grey,
              ),
              const SizedBox(height: 30),
              Padding(
                padding: const EdgeInsets.all(20.0),
                child: Text(
                  _statusText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
