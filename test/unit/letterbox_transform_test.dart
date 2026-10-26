import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/hazard_detectors/letterbox_transform.dart';

void main() {
  group('LetterboxTransform.compute — square image, square target', () {
    test('an image already matching the target aspect ratio needs no padding', () {
      final t = LetterboxTransform.compute(
        originalWidth: 640,
        originalHeight: 640,
        targetWidth: 640,
        targetHeight: 640,
      );
      expect(t.scale, closeTo(1.0, 0.0001));
      expect(t.padX, 0);
      expect(t.padY, 0);
      expect(t.scaledWidth, 640);
      expect(t.scaledHeight, 640);
    });
  });

  group('LetterboxTransform.compute — portrait image (taller than wide)', () {
    test('pads left/right (top/bottom padding is zero) and preserves aspect ratio', () {
      // 480x640 into a 640x640 target: height is the binding
      // constraint (scaleY=1.0 < scaleX=1.333), so scale=1.0.
      final t = LetterboxTransform.compute(
        originalWidth: 480,
        originalHeight: 640,
        targetWidth: 640,
        targetHeight: 640,
      );
      expect(t.scale, closeTo(1.0, 0.0001));
      expect(t.scaledWidth, 480);
      expect(t.scaledHeight, 640);
      expect(t.padX, closeTo(80.0, 0.01)); // (640-480)/2
      expect(t.padY, 0);
    });

    test('a realistic portrait camera frame (1080x1920) into a 640x640 model input', () {
      final t = LetterboxTransform.compute(
        originalWidth: 1080,
        originalHeight: 1920,
        targetWidth: 640,
        targetHeight: 640,
      );
      // scaleX = 640/1080 = 0.5926, scaleY = 640/1920 = 0.3333 — the
      // SMALLER one (height) is binding.
      expect(t.scale, closeTo(0.3333, 0.001));
      expect(t.scaledWidth, 360); // 1080 * 0.3333, rounded
      expect(t.scaledHeight, 640);
      expect(t.padX, closeTo(140.0, 1.0)); // (640-360)/2
      expect(t.padY, 0);
    });
  });

  group('LetterboxTransform.compute — landscape image (wider than tall)', () {
    test('pads top/bottom (left/right padding is zero) and preserves aspect ratio', () {
      // 640x480 into a 640x640 target: width is the binding
      // constraint (scaleX=1.0 < scaleY=1.333), so scale=1.0.
      final t = LetterboxTransform.compute(
        originalWidth: 640,
        originalHeight: 480,
        targetWidth: 640,
        targetHeight: 640,
      );
      expect(t.scale, closeTo(1.0, 0.0001));
      expect(t.scaledWidth, 640);
      expect(t.scaledHeight, 480);
      expect(t.padX, 0);
      expect(t.padY, closeTo(80.0, 0.01)); // (640-480)/2
    });
  });

  group('LetterboxTransform.compute — degenerate inputs', () {
    test('zero or negative dimensions return an identity transform, not NaN/crash', () {
      final t = LetterboxTransform.compute(
        originalWidth: 0,
        originalHeight: 100,
        targetWidth: 640,
        targetHeight: 640,
      );
      expect(t.scale, 1.0);
      expect(t.padX, 0.0);
      expect(t.padY, 0.0);
    });
  });

  group('LetterboxTransform.mapModelPixelBoxToOriginalFraction — coordinate recovery', () {
    test('a box inside the image region (portrait case) recovers to the hand-calculated fraction', () {
      // 480x640 original into 640x640 target -> scale=1.0, padX=80, padY=0.
      final t = LetterboxTransform.compute(
        originalWidth: 480,
        originalHeight: 640,
        targetWidth: 640,
        targetHeight: 640,
      );
      final rect = t.mapModelPixelBoxToOriginalFraction(left: 130, top: 100, width: 100, height: 200);
      // origLeft=(130-80)/1=50 -> 50/480=0.10417
      // origTop=(100-0)/1=100 -> 100/640=0.15625
      // right=(50+100)/480=0.3125, width=0.3125-0.10417=0.20833
      // bottom=(100+200)/640=0.46875, height=0.46875-0.15625=0.3125
      expect(rect.left, closeTo(0.10417, 0.001));
      expect(rect.top, closeTo(0.15625, 0.001));
      expect(rect.width, closeTo(0.20833, 0.001));
      expect(rect.height, closeTo(0.3125, 0.001));
    });

    test('a box entirely within the padding bar recovers as clipped to zero, not negative', () {
      final t = LetterboxTransform.compute(
        originalWidth: 480,
        originalHeight: 640,
        targetWidth: 640,
        targetHeight: 640,
      );
      // Entirely in the left padding bar (padX=80) — e.g. left=10, width=30 (ends at 40, still < 80).
      final rect = t.mapModelPixelBoxToOriginalFraction(left: 10, top: 100, width: 30, height: 50);
      expect(rect.left, 0.0);
      expect(rect.width, 0.0);
    });

    test('a box straddling the right edge of the actual image clips width, does not overshoot 1.0', () {
      final t = LetterboxTransform.compute(
        originalWidth: 480,
        originalHeight: 640,
        targetWidth: 640,
        targetHeight: 640,
      );
      // Actual image right edge in model-pixel space is padX + scaledWidth = 80 + 480 = 560.
      // This box starts at 500 (inside) and extends to 600 (past 560, into the right pad bar).
      final rect = t.mapModelPixelBoxToOriginalFraction(left: 500, top: 0, width: 100, height: 10);
      // origLeft=(500-80)/1=420 -> 420/480=0.875
      // origRight=(600-80)/1=520 -> 520/480=1.0833 -> clamped to 1.0
      expect(rect.left, closeTo(0.875, 0.001));
      expect(rect.right, closeTo(1.0, 0.001));
      // Recovered width (0.125) must be LESS than the naive (unclipped)
      // 100/480=0.2083 — proving the clip actually shortened it.
      expect(rect.width, closeTo(0.125, 0.001));
      expect(rect.width, lessThan(100 / 480));
    });

    test('every recovered fraction stays within [0, 1] even for a wildly out-of-canvas box', () {
      final t = LetterboxTransform.compute(
        originalWidth: 480,
        originalHeight: 640,
        targetWidth: 640,
        targetHeight: 640,
      );
      final rect = t.mapModelPixelBoxToOriginalFraction(left: -500, top: -500, width: 2000, height: 2000);
      expect(rect.left, greaterThanOrEqualTo(0.0));
      expect(rect.top, greaterThanOrEqualTo(0.0));
      expect(rect.right, lessThanOrEqualTo(1.0));
      expect(rect.bottom, lessThanOrEqualTo(1.0));
    });

    test('scale=1, no padding (square case) recovers coordinates unchanged', () {
      final t = LetterboxTransform.compute(
        originalWidth: 640,
        originalHeight: 640,
        targetWidth: 640,
        targetHeight: 640,
      );
      final rect = t.mapModelPixelBoxToOriginalFraction(left: 64, top: 128, width: 64, height: 64);
      expect(rect.left, closeTo(0.1, 0.001)); // 64/640
      expect(rect.top, closeTo(0.2, 0.001)); // 128/640
      expect(rect.width, closeTo(0.1, 0.001));
      expect(rect.height, closeTo(0.1, 0.001));
    });
  });
}
