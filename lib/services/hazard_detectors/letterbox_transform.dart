import 'dart:ui';

/// Aspect-ratio-preserving letterbox geometry — the scale + padding
/// needed to fit an `originalWidth`x`originalHeight` image into a
/// `targetWidth`x`targetHeight` canvas WITHOUT stretching it, plus the
/// inverse mapping needed to bring a detection box computed in that
/// padded canvas back to fractional (0..1) coordinates of the
/// ORIGINAL image.
///
/// AUDIT ADD (BLOCKER 10): replaces `YoloTfliteHazardDetector`'s
/// previous `img.copyResize(image, width: _inputWidth, height:
/// _inputHeight)`, which stretched the frame to the model's input
/// aspect ratio whenever that ratio didn't match the camera's own
/// (the normal case — a 640x640 model input against a ~4:3 or 16:9
/// camera frame) — distorting every object's apparent width/height,
/// which measurably affects both classification and this app's own
/// height-based distance estimation. Kept as a SEPARATE, pure,
/// dependency-free class (no `dart:io`, no `image` package, no
/// `CameraImage`) specifically so its geometry can be unit-tested
/// without a camera, a model, or Flutter's test bindings — see
/// `test/unit/letterbox_transform_test.dart`.
class LetterboxTransform {
  /// Uniform scale factor applied to the original image before
  /// padding — the SAME factor for both width and height, which is
  /// exactly what "aspect-ratio-preserving" means here.
  final double scale;

  /// Pixels of padding added on the LEFT edge of the target canvas
  /// (the same amount is implicitly on the right — padding is always
  /// centered).
  final double padX;

  /// Pixels of padding added on the TOP edge of the target canvas
  /// (same amount implicitly on the bottom).
  final double padY;

  final int originalWidth;
  final int originalHeight;
  final int targetWidth;
  final int targetHeight;

  const LetterboxTransform({
    required this.scale,
    required this.padX,
    required this.padY,
    required this.originalWidth,
    required this.originalHeight,
    required this.targetWidth,
    required this.targetHeight,
  });

  /// The original image's size AFTER scaling (before padding) —
  /// always `<= targetWidth`/`<= targetHeight` in both dimensions,
  /// since this is a "fit inside" scale, not a "fill/crop" one.
  int get scaledWidth => (originalWidth * scale).round();
  int get scaledHeight => (originalHeight * scale).round();

  /// Computes the letterbox geometry for fitting
  /// `originalWidth`x`originalHeight` into
  /// `targetWidth`x`targetHeight`. Degenerate inputs (zero/negative
  /// width or height on either side) return an identity-ish transform
  /// (scale 1, no padding) rather than dividing by zero or producing
  /// NaN/Infinity — callers should treat that as "letterboxing could
  /// not be computed" if it matters, but it's a safe, non-crashing
  /// fallback either way.
  factory LetterboxTransform.compute({
    required int originalWidth,
    required int originalHeight,
    required int targetWidth,
    required int targetHeight,
  }) {
    if (originalWidth <= 0 || originalHeight <= 0 || targetWidth <= 0 || targetHeight <= 0) {
      return LetterboxTransform(
        scale: 1.0,
        padX: 0.0,
        padY: 0.0,
        originalWidth: originalWidth,
        originalHeight: originalHeight,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
    }
    // "Fit inside" scale — the SMALLER of the two axis ratios, so the
    // scaled image never exceeds the target canvas on either axis.
    final scaleX = targetWidth / originalWidth;
    final scaleY = targetHeight / originalHeight;
    final scale = scaleX < scaleY ? scaleX : scaleY;

    final scaledW = (originalWidth * scale).round();
    final scaledH = (originalHeight * scale).round();
    final padX = (targetWidth - scaledW) / 2.0;
    final padY = (targetHeight - scaledH) / 2.0;

    return LetterboxTransform(
      scale: scale,
      padX: padX,
      padY: padY,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
      targetWidth: targetWidth,
      targetHeight: targetHeight,
    );
  }

  /// Maps a box given in MODEL-CANVAS PIXEL coordinates (i.e. already
  /// in the `targetWidth`x`targetHeight` padded space — left/top/
  /// width/height, NOT center-form) back to FRACTIONAL (0..1)
  /// coordinates of the ORIGINAL image. Clips to [0, 1] — a box whose
  /// raw recovered coordinates fall inside the padding bars (which can
  /// legitimately happen for a box near the letterboxed edge) is
  /// clamped to the original image's actual bounds, never returned as
  /// a negative or >1 fraction.
  Rect mapModelPixelBoxToOriginalFraction({
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    if (scale <= 0 || originalWidth <= 0 || originalHeight <= 0) {
      return const Rect.fromLTWH(0, 0, 0, 0);
    }
    // Undo padding, then undo scale — the exact inverse of `compute`'s
    // forward transform (scale first, then pad).
    final origLeftPx = (left - padX) / scale;
    final origTopPx = (top - padY) / scale;
    final origWidthPx = width / scale;
    final origHeightPx = height / scale;

    final leftFraction = (origLeftPx / originalWidth).clamp(0.0, 1.0);
    final topFraction = (origTopPx / originalHeight).clamp(0.0, 1.0);
    // Clip the FAR edge too (right/bottom), not just the near edge —
    // a box that starts in-bounds but extends past the original
    // image's edge (e.g. straddling the letterbox padding) must not
    // report a width/height that overshoots 1.0 fraction.
    final rightFraction = ((origLeftPx + origWidthPx) / originalWidth).clamp(0.0, 1.0);
    final bottomFraction = ((origTopPx + origHeightPx) / originalHeight).clamp(0.0, 1.0);

    final clippedWidth = (rightFraction - leftFraction).clamp(0.0, 1.0);
    final clippedHeight = (bottomFraction - topFraction).clamp(0.0, 1.0);

    return Rect.fromLTWH(leftFraction, topFraction, clippedWidth, clippedHeight);
  }
}
