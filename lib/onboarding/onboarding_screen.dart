import 'package:flutter/material.dart';

import '../ui/home_screen.dart';
import '../ui/permission_gate_screen.dart';
import 'voice/voice_onboarding_controller.dart';

/// One-time first-launch setup — now a voice conversation, not a
/// PageView. ALL conversation/persistence logic lives in
/// [VoiceOnboardingController] (requirement 11); this widget only
/// renders the controller's current state and forwards tap events
/// back to it. Same hand-off as before: on completion, replaces
/// itself with the SAME `PermissionGateScreen(child: HomeScreen())`
/// every subsequent launch already uses.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, @visibleForTesting this.controller});

  /// Exposed ONLY so widget tests can inject a controller with
  /// manually-set state and skip the real [VoiceOnboardingController.start]
  /// sequence (which needs real Hive/permission/speech-plugin services
  /// with no test doubles). Production call sites always omit this
  /// and get the normal internally-constructed, auto-started
  /// controller — see [_OnboardingScreenState.initState].
  @visibleForTesting
  final VoiceOnboardingController? controller;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  late final VoiceOnboardingController _controller;
  late final bool _shouldAutoStart;
  bool _hasNavigated = false;
  bool _hasStarted = false;
  final TextEditingController _typedAnswerController = TextEditingController();
  final FocusNode _typedAnswerFocusNode = FocusNode();

  /// AUDIT FIX (P0 — onboarding text-fallback keyboard gap): tracks
  /// the PREVIOUS value of [VoiceOnboardingController.isTextFallbackActive]
  /// so focus is requested only on the false->true transition (a new
  /// question entering fallback), not on every rebuild while already
  /// in fallback — repeatedly stealing focus on each keystroke/rebuild
  /// would fight the user and could reopen a keyboard they just
  /// dismissed (violates "user can still continue normally").
  bool _wasTextFallbackActive = false;

  @override
  void initState() {
    super.initState();
    _shouldAutoStart = widget.controller == null;
    _controller = widget.controller ?? VoiceOnboardingController(onOnboardingComplete: _onComplete);
    _controller.addListener(_onControllerChanged);
  }

  void _onControllerChanged() {
    if (!mounted) return;
    final isActive = _controller.isTextFallbackActive;
    if (isActive && !_wasTextFallbackActive) {
      // Just entered text-fallback for this question (either the mic
      // is unavailable at all, or voice failed 3 times on THIS
      // question) — requestFocus after this frame so the field exists
      // in the tree first; on a real device this also opens the
      // on-screen keyboard, matching a focused TextField's normal
      // behavior.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _typedAnswerFocusNode.requestFocus();
      });
    }
    _wasTextFallbackActive = isActive;
    setState(() {});
  }

  void _onComplete() {
    if (_hasNavigated || !mounted) return;
    _hasNavigated = true;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const PermissionGateScreen(child: HomeScreen())),
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _typedAnswerController.dispose();
    _typedAnswerFocusNode.dispose();
    super.dispose();
  }

  void _submitTypedAnswer() {
    final text = _typedAnswerController.text;
    _typedAnswerController.clear();
    _controller.submitTypedAnswer(text);
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasStarted) {
      _hasStarted = true;
      if (_shouldAutoStart) {
        // Started post-frame so the first build can render the initial
        // "loading" state before speech begins.
        WidgetsBinding.instance.addPostFrameCallback((_) => _controller.start());
      }
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            LinearProgressIndicator(value: _controller.progress),
            if (_controller.errorMessage != null)
              Container(
                width: double.infinity,
                color: Colors.red.withOpacity(0.15),
                padding: const EdgeInsets.all(12),
                child: Text(_controller.errorMessage!, style: const TextStyle(color: Colors.redAccent)),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      _controller.isPaused
                          ? Icons.pause_circle_outline
                          : (_controller.isSpeaking ? Icons.volume_up : Icons.mic),
                      size: 72,
                      color: Colors.deepPurpleAccent,
                    ),
                    const SizedBox(height: 24),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _controller.displayText,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 22, height: 1.4),
                      ),
                    ),
                    if (_controller.lastHeardText != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        'You said: "${_controller.lastHeardText}"',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 15, color: Colors.grey, fontStyle: FontStyle.italic),
                      ),
                    ],
                    if (_controller.tapChoices != null) ...[
                      const SizedBox(height: 32),
                      Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        alignment: WrapAlignment.center,
                        children: _controller.tapChoices!.entries
                            .map((entry) => Semantics(
                                  button: true,
                                  label: entry.key,
                                  child: ElevatedButton(
                                    onPressed: () => _controller.submitTapChoice(entry.value),
                                    child: Text(entry.key),
                                  ),
                                ))
                            .toList(),
                      ),
                    ],
                    // AUDIT FIX (P0 — onboarding text-fallback keyboard
                    // gap): shown for EVERY question — including
                    // free-text ones like name/contact details/
                    // addresses — whenever [isTextFallbackActive] is
                    // true, which covers BOTH the microphone being
                    // unavailable entirely AND this specific question
                    // having failed 3 voice attempts (previously only
                    // the former was checked, so the latter spoke
                    // "please type your answer" with no field to type
                    // into — see VoiceOnboardingController's doc
                    // comment on isTextFallbackActive). Not shown while
                    // paused (only "resume" is meaningful then) or once
                    // tap choices already cover this question (tapping
                    // already works regardless of voice-attempt count,
                    // so no fallback gap exists there), to avoid
                    // offering two redundant ways to answer.
                    if (_controller.isTextFallbackActive && !_controller.isPaused && _controller.tapChoices == null) ...[
                      const SizedBox(height: 32),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _typedAnswerController,
                              focusNode: _typedAnswerFocusNode,
                              autofocus: true,
                              textInputAction: TextInputAction.done,
                              decoration: const InputDecoration(
                                hintText: 'Type your answer',
                                border: OutlineInputBorder(),
                              ),
                              onSubmitted: (_) => _submitTypedAnswer(),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Semantics(
                            button: true,
                            label: 'Submit answer',
                            child: IconButton.filled(
                              onPressed: _submitTypedAnswer,
                              icon: const Icon(Icons.send),
                              iconSize: 28,
                              padding: const EdgeInsets.all(16),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (_controller.isPaused) ...[
                      const SizedBox(height: 32),
                      Semantics(
                        button: true,
                        label: 'Resume',
                        child: ElevatedButton.icon(
                          onPressed: () => _controller.submitTapChoice(true),
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('Resume'),
                        ),
                      ),
                    ],
                    if (_controller.isSaving) ...[
                      const SizedBox(height: 32),
                      const CircularProgressIndicator(),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
