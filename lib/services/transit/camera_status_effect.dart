import 'transit_session_state.dart';

/// PHASE NEXT (camera visibility/status honesty) — pure decision: given
/// a [CameraDetectionCommand] the transit state machine emitted, what
/// should the UI show and what (if anything) should be spoken.
/// Deliberately separated from `TransitJourneyGuideScreen`'s widget/
/// async orchestration so the actual DECISION — "turning hazard
/// detection off is the one transition that needs an explicit spoken
/// acknowledgment, turning it on doesn't" — is directly unit-testable,
/// matching this codebase's own established pattern (see
/// `voice_confirmation.dart`).
///
/// WHY ONLY THE OFF TRANSITION SPEAKS: turning detection OFF is a
/// silent capability downgrade unless announced — exactly what the
/// "never silently downgrade... without telling the user" safety
/// principle warns against. Turning it back ON is already followed by
/// a real spoken instruction in every real call site (`confirmAlighting`
/// speaks "Please walk toward your destination.", `reachedBoardingStop`
/// speaks the boarding instruction before this fires at all) — an
/// extra "hazard detection is back on" line there would be adding
/// speech for its own sake, not closing a real gap.
class CameraStatusEffect {
  final bool cameraActive;
  final String? spokenPhrase;
  const CameraStatusEffect({required this.cameraActive, this.spokenPhrase});

  @override
  bool operator ==(Object other) =>
      other is CameraStatusEffect && other.cameraActive == cameraActive && other.spokenPhrase == spokenPhrase;

  @override
  int get hashCode => Object.hash(cameraActive, spokenPhrase);

  @override
  String toString() => 'CameraStatusEffect(cameraActive: $cameraActive, spokenPhrase: $spokenPhrase)';
}

const String hazardDetectionPausedPhrase = 'Hazard detection is now paused while you are on board.';

CameraStatusEffect cameraStatusEffectFor(CameraDetectionCommand command) {
  if (command == CameraDetectionCommand.startDetection) {
    return const CameraStatusEffect(cameraActive: true);
  }
  return const CameraStatusEffect(cameraActive: false, spokenPhrase: hazardDetectionPausedPhrase);
}
