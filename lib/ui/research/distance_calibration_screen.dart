import 'package:flutter/material.dart';

import '../../models/detected_hazard.dart';
import '../../services/hazard_detectors/distance_estimator.dart';

/// AUDIT ADD (engineering-hardening phase — Priority 2, distance/TTC
/// reliability): [DistanceEstimationConfig] already contains a real,
/// runnable calibration formula (`calibrateFocalLengthPixels`) and is
/// explicitly documented as UNCALIBRATED (`isCalibrated = false`) —
/// but nothing in the app ever exposed a way to actually RUN that
/// procedure. Someone wanting to calibrate it had to read bounding-box
/// heights out of logcat and do the arithmetic by hand. This screen is
/// that missing tool, nothing more.
///
/// READ-ONLY INTO THE DETECTION PIPELINE, SAME DISCIPLINE AS
/// [DebugDashboardScreen]: this screen never touches
/// [HazardDetectionService]/[YoloTfliteHazardDetector] directly — it
/// only reads the same already-public, already-live
/// [NavigationScreen._currentFrameHazards] list via an injected
/// getter, exactly like the debug dashboard's `getSnapshot` pattern.
/// It cannot change detection, risk, or navigation behavior in any
/// way — it only helps a human collect the ONE real-world measurement
/// [DistanceEstimationConfig.focalLengthPixels] has never had.
///
/// HOW TO USE (see [DistanceEstimationConfig]'s own doc comment for
/// the full procedure this implements):
///   1. Place a known object (e.g. a person of known height) at a
///      known, measured distance from the camera.
///   2. Point the camera at it so the live NavigationScreen feed
///      detects it — this screen shows the label/confidence/computed
///      calibration-space bounding-box height of the most recent
///      matching detection automatically, live.
///   3. Enter the real measured distance in the field below and tap
///      "Record sample."
///   4. Repeat at 2-3 different distances (per the class doc comment's
///      own recommendation that a single measurement is a starting
///      point, not a robust calibration) — this screen averages every
///      recorded sample and shows the result to copy into
///      [DistanceEstimationConfig.focalLengthPixels] by hand. This
///      screen deliberately does NOT write that constant itself —
///      changing a safety-relevant constant is a decision a person
///      should make deliberately, in a code review, not something a
///      debug tool does silently at runtime.
class DistanceCalibrationScreen extends StatefulWidget {
  final List<DetectedHazard> Function() getLiveHazards;

  const DistanceCalibrationScreen({super.key, required this.getLiveHazards});

  @override
  State<DistanceCalibrationScreen> createState() => _DistanceCalibrationScreenState();
}

class _CalibrationSample {
  final String label;
  final double knownDistanceMeters;
  final double boundingBoxHeightCalibrationPixels;
  final double impliedFocalLengthPixels;

  const _CalibrationSample({
    required this.label,
    required this.knownDistanceMeters,
    required this.boundingBoxHeightCalibrationPixels,
    required this.impliedFocalLengthPixels,
  });
}

class _DistanceCalibrationScreenState extends State<DistanceCalibrationScreen> {
  static const double _calibrationReferenceSize = 300.0; // must match YoloTfliteHazardDetector's own reference

  final TextEditingController _distanceController = TextEditingController();
  final List<_CalibrationSample> _samples = [];
  DetectedHazard? _latestHazard;

  @override
  void dispose() {
    _distanceController.dispose();
    super.dispose();
  }

  DetectedHazard? _mostConfidentCurrentHazard() {
    final hazards = widget.getLiveHazards();
    if (hazards.isEmpty) return null;
    final withBox = hazards.where((h) => h.boundingBox != null).toList();
    if (withBox.isEmpty) return null;
    withBox.sort((a, b) => b.confidence.compareTo(a.confidence));
    return withBox.first;
  }

  void _refresh() {
    setState(() => _latestHazard = _mostConfidentCurrentHazard());
  }

  void _recordSample() {
    final hazard = _latestHazard;
    if (hazard == null || hazard.boundingBox == null) {
      _showMessage('No detected object with a bounding box right now — point the camera at the calibration object first.');
      return;
    }
    final distanceMeters = double.tryParse(_distanceController.text.trim());
    if (distanceMeters == null || distanceMeters <= 0) {
      _showMessage('Enter the real measured distance in meters (e.g. 2.0).');
      return;
    }
    final bboxHeightPixels = hazard.boundingBox!.height * _calibrationReferenceSize;
    final implied = DistanceEstimationConfig.calibrateFocalLengthPixels(
      knownObjectHeightMeters: DistanceEstimationConfig.knownObjectHeightsMeters[hazard.label] ?? 0,
      distanceMeters: distanceMeters,
      boundingBoxHeightPixels: bboxHeightPixels,
    );
    if (implied == null) {
      _showMessage('"${hazard.label}" has no configured known height — cannot calibrate from this class.');
      return;
    }
    setState(() {
      _samples.add(_CalibrationSample(
        label: hazard.label,
        knownDistanceMeters: distanceMeters,
        boundingBoxHeightCalibrationPixels: bboxHeightPixels,
        impliedFocalLengthPixels: implied,
      ));
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  double? get _averageFocalLength {
    if (_samples.isEmpty) return null;
    return _samples.map((s) => s.impliedFocalLengthPixels).reduce((a, b) => a + b) / _samples.length;
  }

  @override
  Widget build(BuildContext context) {
    final average = _averageFocalLength;
    return Scaffold(
      appBar: AppBar(title: const Text('Distance Calibration')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Current default: focalLengthPixels = ${DistanceEstimationConfig.focalLengthPixels} '
            '(isCalibrated = ${DistanceEstimationConfig.isCalibrated}) — an uncalibrated, order-of-magnitude guess.',
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 20),
          ElevatedButton.icon(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
            label: const Text('Read current live detection'),
          ),
          const SizedBox(height: 12),
          if (_latestHazard != null) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Detected: ${_latestHazard!.label} (confidence ${(_latestHazard!.confidence * 100).toStringAsFixed(0)}%)'),
                    Text('Bounding-box height (calibration space): '
                        '${(_latestHazard!.boundingBox!.height * _calibrationReferenceSize).toStringAsFixed(1)} px'),
                    if (DistanceEstimationConfig.knownObjectHeightsMeters[_latestHazard!.label] == null)
                      const Text('No configured known height for this class — cannot calibrate from it.',
                          style: TextStyle(color: Colors.orange)),
                  ],
                ),
              ),
            ),
          ] else
            const Text('No detected object with a bounding box right now.', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 20),
          TextField(
            controller: _distanceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Real measured distance (meters)',
              hintText: 'e.g. 2.0',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(onPressed: _recordSample, child: const Text('Record sample')),
          const Divider(height: 40),
          Text('Recorded samples (${_samples.length})', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),
          ..._samples.map((s) => ListTile(
                dense: true,
                title: Text('${s.label} @ ${s.knownDistanceMeters}m'),
                subtitle: Text('bbox=${s.boundingBoxHeightCalibrationPixels.toStringAsFixed(1)}px -> '
                    'implied focal length=${s.impliedFocalLengthPixels.toStringAsFixed(1)}px'),
              )),
          if (average != null) ...[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(border: Border.all(color: Colors.deepPurpleAccent), borderRadius: BorderRadius.circular(8)),
              child: Text(
                'Average implied focalLengthPixels across ${_samples.length} sample(s): ${average.toStringAsFixed(1)}\n\n'
                'Per DistanceEstimationConfig\'s own doc comment: 2-3 samples at different distances is the '
                'recommended minimum before treating this as a real calibration, not just a starting point. '
                'This screen does NOT write the constant automatically — replace focalLengthPixels in '
                'distance_estimator.dart by hand, set isCalibrated = true, and document the device/measurement '
                'details in that file\'s comment, per its existing convention.',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
