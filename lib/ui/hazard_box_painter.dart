import 'package:flutter/material.dart';

import '../models/detected_hazard.dart';

/// Draws bounding boxes (with object name + confidence percentage)
/// over the camera preview, per requirement.
///
/// COORDINATE SPACE: expects [hazards] whose `boundingBox` is
/// FRACTIONAL (0..1, left/top/width/height as a fraction of the
/// frame) — exactly what `YoloTfliteHazardDetector` produces (see
/// its own doc comment). This painter simply multiplies those
/// fractions by its own [Size] at paint time, so it works correctly
/// regardless of the actual preview widget's pixel size.
///
/// ALIGNMENT CAVEAT (best-effort, not pixel-perfect — consistent with
/// this app's other monocular/heuristic distance signals): for boxes
/// to land in the right place, this painter must be stacked with
/// `CameraPreview` inside a SHARED `AspectRatio` sized to
/// `cameraController.value.aspectRatio`, so both share the exact same
/// coordinate space (see `navigation_screen.dart`'s `build()` for how
/// they're stacked). This is the standard, common-case approach and
/// covers this app's actual setup (portrait, rear camera); it does not
/// separately handle every possible sensor-orientation/front-camera
/// mirroring combination.
class HazardBoxPainter extends CustomPainter {
  final List<DetectedHazard> hazards;

  HazardBoxPainter(this.hazards);

  static const Map<HazardPriority, Color> _colorByPriority = {
    HazardPriority.critical: Colors.redAccent,
    HazardPriority.caution: Colors.orangeAccent,
    HazardPriority.informational: Colors.yellowAccent,
  };

  @override
  void paint(Canvas canvas, Size size) {
    for (final hazard in hazards) {
      final box = hazard.boundingBox;
      if (box == null) continue;

      final color = _colorByPriority[hazard.priority] ?? Colors.white;
      final rect = Rect.fromLTWH(
        box.left * size.width,
        box.top * size.height,
        box.width * size.width,
        box.height * size.height,
      );

      final boxPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0;
      canvas.drawRect(rect, boxPaint);

      final labelText =
          '${hazard.label} ${(hazard.confidence * 100).round()}%';
      final textPainter = TextPainter(
        text: TextSpan(
          text: labelText,
          style: TextStyle(
            color: Colors.black,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            backgroundColor: color.withOpacity(0.85),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // Label sits just above the box; if the box is near the very
      // top of the frame (no room above), place it just inside the
      // top edge instead of letting it clip off-screen.
      final labelY = rect.top - textPainter.height >= 0
          ? rect.top - textPainter.height
          : rect.top;
      textPainter.paint(canvas, Offset(rect.left, labelY));
    }
  }

  @override
  bool shouldRepaint(covariant HazardBoxPainter oldDelegate) {
    return !identical(oldDelegate.hazards, hazards);
  }
}
