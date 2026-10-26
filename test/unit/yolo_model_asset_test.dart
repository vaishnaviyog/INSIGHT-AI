import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/hazard_detectors/yolo_label_config.dart';
import 'package:vaishnavi/services/hazard_detectors/yolo_tflite_hazard_detector.dart';

/// Verifies the bundled YOLOv8n model/label ASSETS themselves, added
/// after restoring `assets/ml_models/yolov8n.tflite` (previously
/// missing — see AUDIT_REPORT.md Part K). Complements
/// `yolo_detector_health_test.dart`, which only covers the pure
/// `computeInferenceReady` formula with synthetic check maps — these
/// tests exercise the REAL bundled files.
///
/// Model provenance: a standard Ultralytics YOLOv8n COCO export
/// (`yolo export model=yolov8n.pt format=onnx imgsz=640`, then
/// ONNX->TensorFlow->TFLite via `onnx2tf`, since Ultralytics' own
/// direct TFLite/LiteRT export only supports Linux x86 and macOS, not
/// Windows — see the export log). Generic COCO weights, NOT
/// custom-trained or safety-certified for this app — see this file's
/// own test assertions for exactly what is and isn't verified.
void main() {
  group('Bundled label file (assets/ml_models/yolov8n_labels.txt)', () {
    test('contains exactly 80 non-empty class names, in standard COCO order', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final raw = await rootBundle.loadString('assets/ml_models/yolov8n_labels.txt');
      final labels = raw.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      expect(labels, hasLength(80));
      // Spot-check the well-known standard Ultralytics/COCO ordering
      // (index 0 = person, no leading background/placeholder row) —
      // the exact order YoloTfliteHazardDetector's label-index mapping
      // depends on.
      expect(labels[0], 'person');
      expect(labels[1], 'bicycle');
      expect(labels[2], 'car');
      expect(labels[3], 'motorcycle');
      expect(labels[5], 'bus');
      expect(labels[7], 'truck');
      expect(labels[9], 'traffic light');
      expect(labels[11], 'stop sign');
      expect(labels[13], 'bench');
      expect(labels[79], 'toothbrush');
    });

    test('every class name used in YoloLabelConfig.hazardPriorities exists in the label file', () async {
      final raw = await rootBundle.loadString('assets/ml_models/yolov8n_labels.txt');
      final labels = raw.split('\n').map((l) => l.trim().toLowerCase()).where((l) => l.isNotEmpty).toSet();
      for (final hazardLabel in YoloLabelConfig.hazardPriorities.keys) {
        expect(labels.contains(hazardLabel), isTrue,
            reason: '"$hazardLabel" is in the hazard allowlist but missing from the bundled label file');
      }
    });
  });

  group('Bundled model asset (assets/ml_models/yolov8n.tflite)', () {
    test('the asset exists and is loadable as raw bytes (does not assert native inference)', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final data = await rootBundle.load('assets/ml_models/yolov8n.tflite');
      // A real YOLOv8n float32 TFLite export is on the order of
      // several MB, not a few bytes (which would indicate an empty
      // placeholder rather than a real model).
      expect(data.lengthInBytes, greaterThan(1000000),
          reason: 'expected a real, multi-megabyte YOLOv8n TFLite model, not a placeholder');
    });

    test('YoloTfliteHazardDetector.initialize() runs against the real bundled asset', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final detector = YoloTfliteHazardDetector();
      await detector.initialize();
      // NOTE: this test intentionally does NOT hard-assert
      // `isAvailable == true`. Loading a real TFLite model via
      // `Interpreter.fromAsset` requires the native tensorflowlite_c
      // library for the platform `flutter test` actually runs on
      // (the Dart VM host, e.g. Windows desktop here) — that native
      // library is normally produced by Flutter's platform BUILD step
      // (`flutter build apk` / `flutter run`), not by `flutter test`,
      // which does not go through that native build pipeline. So:
      //   - if the native runtime IS resolvable on this host, this
      //     asserts real success (isAvailable true, every prerequisite
      //     check passed, matching the production decoder's exact
      //     [1,640,640,3] float32 in / [1,84,8400] float32 out
      //     contract).
      //   - if it is NOT resolvable here, this test still proves the
      //     asset itself loads and initialize() fails SOFTLY (no
      //     crash, `isAvailable` false with a clear `health.failureReason`)
      //     rather than throwing — the documented IHazardDetector
      //     contract — and is not treated as a hard failure of this
      //     test suite.
      // Real on-device inference is verified separately via a release
      // APK on physical Android hardware, per this repository's
      // verification process — that is the authoritative check for
      // "does inference actually run," not this desktop test.
      if (detector.isAvailable) {
        expect(detector.health.allPassed, isTrue);
        expect(detector.health.checks[YoloDetectorCheck.modelFileFound], isTrue);
        expect(detector.health.checks[YoloDetectorCheck.modelLoaded], isTrue);
        expect(detector.health.checks[YoloDetectorCheck.labelFileFound], isTrue);
        expect(detector.health.checks[YoloDetectorCheck.labelsLoaded], isTrue);
        expect(detector.health.checks[YoloDetectorCheck.inputShapeValid], isTrue);
        expect(detector.health.checks[YoloDetectorCheck.outputShapeValid], isTrue);
      } else {
        // Soft-fail path — still meaningful: confirms the detector
        // never throws even when native inference can't run here, and
        // reports a specific, non-null reason (never a silent false).
        expect(detector.health.failureReason, isNotNull);
        // ignore: avoid_print
        print('YoloTfliteHazardDetector not available in this test host '
            '(expected on a desktop `flutter test` run without the native '
            'tflite runtime built): ${detector.health.failureReason}');
      }
      detector.dispose();
    });
  });
}
