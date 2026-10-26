import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/transit/camera_status_effect.dart';
import 'package:vaishnavi/services/transit/transit_session_state.dart';

/// Phase NEXT (camera visibility/status honesty) regression coverage
/// for the pure start/stop-detection -> UI-state/spoken-phrase mapping
/// consumed by `TransitJourneyGuideScreen._processTransitEvents`.
void main() {
  group('cameraStatusEffectFor', () {
    test('startDetection turns the camera on and speaks nothing', () {
      final effect = cameraStatusEffectFor(CameraDetectionCommand.startDetection);
      expect(effect.cameraActive, isTrue);
      expect(effect.spokenPhrase, isNull);
    });

    test('stopDetection turns the camera off and speaks the pause phrase exactly once', () {
      final effect = cameraStatusEffectFor(CameraDetectionCommand.stopDetection);
      expect(effect.cameraActive, isFalse);
      expect(effect.spokenPhrase, hazardDetectionPausedPhrase);
    });

    test('the spoken pause phrase never implies detection is still active', () {
      final effect = cameraStatusEffectFor(CameraDetectionCommand.stopDetection);
      expect(effect.spokenPhrase!.toLowerCase(), contains('paused'));
    });

    test('is a pure function: same input always yields an equal effect', () {
      expect(
        cameraStatusEffectFor(CameraDetectionCommand.startDetection),
        cameraStatusEffectFor(CameraDetectionCommand.startDetection),
      );
      expect(
        cameraStatusEffectFor(CameraDetectionCommand.stopDetection),
        cameraStatusEffectFor(CameraDetectionCommand.stopDetection),
      );
    });

    test('start and stop never produce the same effect', () {
      expect(
        cameraStatusEffectFor(CameraDetectionCommand.startDetection),
        isNot(equals(cameraStatusEffectFor(CameraDetectionCommand.stopDetection))),
      );
    });
  });
}
