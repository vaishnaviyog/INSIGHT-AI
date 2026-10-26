import 'package:flutter_test/flutter_test.dart';
import 'package:vaishnavi/services/metrics/statistics_utils.dart';

void main() {
  group('StatisticsUtils.summarize — insufficient/empty data', () {
    test('an empty list returns StatSummary.empty(), not a fabricated zero-sample stat', () {
      final result = StatisticsUtils.summarize([]);
      expect(result.n, 0);
      expect(result.mean, 0);
      expect(result.standardDeviation, 0);
    });

    test('toMap() reports every field as null (not 0) when n == 0', () {
      final map = StatSummary.empty().toMap();
      expect(map['n'], 0);
      expect(map['mean'], isNull);
      expect(map['standard_deviation'], isNull);
      expect(map['ci_95_lower'], isNull);
      expect(map['ci_95_upper'], isNull);
    });

    test('a single value has zero variance/standard deviation and a degenerate (zero-width) CI', () {
      final result = StatisticsUtils.summarize([5.0]);
      expect(result.n, 1);
      expect(result.mean, 5.0);
      expect(result.standardDeviation, 0.0);
      expect(result.confidenceIntervalLower, 5.0);
      expect(result.confidenceIntervalUpper, 5.0);
    });
  });

  group('StatisticsUtils.summarize — known-value correctness', () {
    // [2, 4, 4, 4, 5, 5, 7, 9] — a textbook example with a well-known
    // population standard deviation of 2.0. Sample (N-1) standard
    // deviation for this set is 2.138089935... (hand-verifiable).
    const sample = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];

    test('mean is correct', () {
      final result = StatisticsUtils.summarize(sample);
      expect(result.mean, closeTo(5.0, 0.0001));
    });

    test('median is correct for an even-length sample (average of two middle values)', () {
      final result = StatisticsUtils.summarize(sample);
      expect(result.median, closeTo(4.5, 0.0001));
    });

    test('sample standard deviation (N-1 denominator) matches the known textbook value', () {
      final result = StatisticsUtils.summarize(sample);
      expect(result.standardDeviation, closeTo(2.138089935, 0.0001));
    });

    test('min and max are correct', () {
      final result = StatisticsUtils.summarize(sample);
      expect(result.min, 2.0);
      expect(result.max, 9.0);
    });

    test('95% CI is centered on the mean and widens/narrows with standard error', () {
      final result = StatisticsUtils.summarize(sample);
      final center = (result.confidenceIntervalLower + result.confidenceIntervalUpper) / 2;
      expect(center, closeTo(result.mean, 0.0001));
      expect(result.confidenceIntervalLower, lessThan(result.mean));
      expect(result.confidenceIntervalUpper, greaterThan(result.mean));
    });

    test('a larger sample with the same mean/spread pattern yields a narrower CI', () {
      // Doubling every value's frequency shouldn't change the mean or
      // population spread much, but standard error shrinks with more n.
      final doubled = [...sample, ...sample];
      final small = StatisticsUtils.summarize(sample);
      final large = StatisticsUtils.summarize(doubled);
      final smallWidth = small.confidenceIntervalUpper - small.confidenceIntervalLower;
      final largeWidth = large.confidenceIntervalUpper - large.confidenceIntervalLower;
      expect(largeWidth, lessThan(smallWidth));
    });
  });

  group('StatisticsUtils.pairedComparison — insufficient-data guards', () {
    test('returns null for two empty lists', () {
      expect(StatisticsUtils.pairedComparison([], []), isNull);
    });

    test('returns null when the two samples have different lengths (not actually paired)', () {
      expect(StatisticsUtils.pairedComparison([1.0, 2.0, 3.0], [1.0, 2.0]), isNull);
    });

    test('returns null for a single pair (standard deviation of differences undefined)', () {
      expect(StatisticsUtils.pairedComparison([1.0], [2.0]), isNull);
    });
  });

  group('StatisticsUtils.pairedComparison — degenerate case', () {
    test('identical differences across every pair report NaN t/p/d rather than crashing or dividing by zero', () {
      // "after" is always exactly 1.0 less than "before" — zero
      // variance in the differences.
      final before = [5.0, 6.0, 7.0, 8.0];
      final after = [4.0, 5.0, 6.0, 7.0];
      final result = StatisticsUtils.pairedComparison(before, after);
      expect(result, isNotNull);
      expect(result!.n, 4);
      expect(result.meanDifference, closeTo(1.0, 0.0001));
      expect(result.tStatistic.isNaN, isTrue);
      expect(result.pValueTwoTailed.isNaN, isTrue);
      expect(result.cohensD.isNaN, isTrue);
    });

    test('toMap() reports NaN statistics as null, never as an unparseable raw NaN', () {
      final result = StatisticsUtils.pairedComparison([5.0, 6.0], [4.0, 5.0])!;
      final map = result.toMap();
      expect(map['t_statistic'], isNull);
      expect(map['p_value_two_tailed'], isNull);
      expect(map['cohens_d'], isNull);
      expect(map['mean_difference'], closeTo(1.0, 0.0001));
    });
  });

  group('StatisticsUtils.pairedComparison — before-vs-after personalization scenario', () {
    test('a consistent improvement across pairs yields a large positive effect size', () {
      // "before personalization" reaction times vs "after" — after is
      // consistently faster (lower), with a little natural variance
      // so the difference isn't perfectly constant (avoids the
      // degenerate zero-variance case above).
      final beforePersonalization = [3.2, 3.5, 3.1, 3.8, 3.4, 3.6];
      final afterPersonalization = [2.1, 2.4, 2.0, 2.6, 2.3, 2.5];
      final result = StatisticsUtils.pairedComparison(beforePersonalization, afterPersonalization);

      expect(result, isNotNull);
      expect(result!.meanDifference, greaterThan(0)); // before - after > 0 => got faster
      expect(result.tStatistic.isNaN, isFalse);
      expect(result.cohensD.isNaN, isFalse);
      // A very consistent ~1.1s improvement across all 6 pairs should
      // register as a large effect (Cohen's convention: |d| >= 0.8).
      expect(result.cohensD.abs(), greaterThan(0.8));
      // Such a consistent difference should also be statistically
      // significant at the conventional 0.05 level.
      expect(result.pValueTwoTailed, lessThan(0.05));
    });

    test('no real difference between before/after yields a small effect size and a high p-value', () {
      final beforePersonalization = [3.0, 3.4, 2.8, 3.6, 3.1, 3.3];
      final afterPersonalization = [3.1, 3.2, 3.0, 3.3, 3.0, 3.4]; // noisy, no consistent direction
      final result = StatisticsUtils.pairedComparison(beforePersonalization, afterPersonalization);

      expect(result, isNotNull);
      expect(result!.pValueTwoTailed, greaterThan(0.05));
    });
  });
}
