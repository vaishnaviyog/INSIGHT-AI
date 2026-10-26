import 'dart:math' as math;

/// Descriptive-statistics summary for one numeric sample, computed
/// ENTIRELY from the values passed in — no external assumptions, no
/// synthetic/interpolated data points.
///
/// CONFIDENCE INTERVAL METHOD: uses the normal approximation
/// (mean ± 1.96 * standardError), which is the standard large-sample
/// approximation for a 95% CI. For small samples (n < 30) this is a
/// documented approximation, not an exact Student-t interval — see
/// [StatisticsUtils.studentTCriticalValueApprox] for why an exact
/// per-df t-table was deliberately avoided (it would require a large
/// hardcoded critical-value table for arbitrary df, which is a worse
/// source of silent inaccuracy than a clearly-labeled approximation).
class StatSummary {
  final int n;
  final double mean;
  final double median;
  final double standardDeviation;
  final double variance;
  final double min;
  final double max;
  final double confidenceIntervalLower;
  final double confidenceIntervalUpper;

  const StatSummary({
    required this.n,
    required this.mean,
    required this.median,
    required this.standardDeviation,
    required this.variance,
    required this.min,
    required this.max,
    required this.confidenceIntervalLower,
    required this.confidenceIntervalUpper,
  });

  /// A summary representing "no data collected" — every field is 0,
  /// and callers MUST check [n] == 0 before treating any other field
  /// as meaningful. This exists so downstream export code never has
  /// to null-check a whole StatSummary, while still making it
  /// impossible to mistake "no data" for "a real zero value" as long
  /// as n is checked.
  factory StatSummary.empty() => const StatSummary(
        n: 0,
        mean: 0,
        median: 0,
        standardDeviation: 0,
        variance: 0,
        min: 0,
        max: 0,
        confidenceIntervalLower: 0,
        confidenceIntervalUpper: 0,
      );

  Map<String, dynamic> toMap() => {
        'n': n,
        'mean': n == 0 ? null : mean,
        'median': n == 0 ? null : median,
        'standard_deviation': n == 0 ? null : standardDeviation,
        'variance': n == 0 ? null : variance,
        'min': n == 0 ? null : min,
        'max': n == 0 ? null : max,
        'ci_95_lower': n == 0 ? null : confidenceIntervalLower,
        'ci_95_upper': n == 0 ? null : confidenceIntervalUpper,
      };
}

/// Result of comparing two paired samples of equal length.
class PairedComparisonResult {
  final int n;
  final double meanDifference;
  final double tStatistic;
  final int degreesOfFreedom;
  final double pValueTwoTailed;
  final double cohensD;

  const PairedComparisonResult({
    required this.n,
    required this.meanDifference,
    required this.tStatistic,
    required this.degreesOfFreedom,
    required this.pValueTwoTailed,
    required this.cohensD,
  });

  Map<String, dynamic> toMap() => {
        'n_pairs': n,
        'mean_difference': meanDifference,
        // NaN (the degenerate "every pair had an identical difference"
        // case — see StatisticsUtils.pairedComparison) is not valid
        // JSON and cannot be formatted with toStringAsFixed, so it is
        // reported as null here rather than as a raw NaN value.
        't_statistic': tStatistic.isNaN ? null : tStatistic,
        'degrees_of_freedom': degreesOfFreedom,
        'p_value_two_tailed': pValueTwoTailed.isNaN ? null : pValueTwoTailed,
        'cohens_d': cohensD.isNaN ? null : cohensD,
      };
}

/// Pure, dependency-free statistics functions. Every function operates
/// only on the numeric list(s) passed to it — nothing here invents,
/// interpolates, or defaults a data point that wasn't actually
/// supplied by the caller.
class StatisticsUtils {
  StatisticsUtils._();

  static StatSummary summarize(List<double> values) {
    if (values.isEmpty) return StatSummary.empty();
    final n = values.length;
    final sorted = [...values]..sort();
    final mean = values.reduce((a, b) => a + b) / n;

    final double median;
    final mid = n ~/ 2;
    if (n.isOdd) {
      median = sorted[mid];
    } else {
      median = (sorted[mid - 1] + sorted[mid]) / 2.0;
    }

    // Sample variance (N-1 denominator) — the standard choice when
    // the collected values are treated as a sample of a larger
    // population of possible runs, not the entire population itself.
    double variance = 0.0;
    if (n > 1) {
      final sumSquaredDiff = values.fold<double>(0.0, (sum, v) => sum + math.pow(v - mean, 2));
      variance = sumSquaredDiff / (n - 1);
    }
    final stdDev = math.sqrt(variance);

    // 95% CI via normal approximation: mean ± 1.96 * (stdDev / sqrt(n)).
    double ciLower = mean;
    double ciUpper = mean;
    if (n > 1) {
      final standardError = stdDev / math.sqrt(n);
      const zFor95Percent = 1.96;
      ciLower = mean - zFor95Percent * standardError;
      ciUpper = mean + zFor95Percent * standardError;
    }

    return StatSummary(
      n: n,
      mean: mean,
      median: median,
      standardDeviation: stdDev,
      variance: variance,
      min: sorted.first,
      max: sorted.last,
      confidenceIntervalLower: ciLower,
      confidenceIntervalUpper: ciUpper,
    );
  }

  /// Paired t-test + Cohen's d for two equal-length samples measuring
  /// the SAME quantity under two conditions (e.g. the same metric from
  /// two different testing sessions). Returns null — rather than a
  /// fabricated result — when:
  ///  - either list is empty,
  ///  - the two lists have different lengths (a paired test requires
  ///    one difference per pair; mismatched lengths mean the samples
  ///    are not actually paired), or
  ///  - fewer than 2 pairs are available (a standard deviation of
  ///    differences is undefined for a single pair).
  static PairedComparisonResult? pairedComparison(List<double> a, List<double> b) {
    if (a.isEmpty || b.isEmpty || a.length != b.length || a.length < 2) return null;

    final n = a.length;
    final differences = List<double>.generate(n, (i) => a[i] - b[i]);
    final meanDiff = differences.reduce((x, y) => x + y) / n;

    final sumSquaredDiff =
        differences.fold<double>(0.0, (sum, d) => sum + math.pow(d - meanDiff, 2));
    final varianceDiff = sumSquaredDiff / (n - 1);
    final sdDiff = math.sqrt(varianceDiff);

    if (sdDiff == 0) {
      // Every pair had an identical difference — t is undefined
      // (division by zero standard error). This is a legitimate
      // degenerate case, not an error; report it plainly.
      return PairedComparisonResult(
        n: n,
        meanDifference: meanDiff,
        tStatistic: double.nan,
        degreesOfFreedom: n - 1,
        pValueTwoTailed: double.nan,
        cohensD: double.nan,
      );
    }

    final standardError = sdDiff / math.sqrt(n);
    final tStatistic = meanDiff / standardError;
    final degreesOfFreedom = n - 1;
    final pValue = _twoTailedPValueFromT(tStatistic, degreesOfFreedom);

    // Cohen's d for paired samples: mean difference divided by the
    // standard deviation of the differences.
    final cohensD = meanDiff / sdDiff;

    return PairedComparisonResult(
      n: n,
      meanDifference: meanDiff,
      tStatistic: tStatistic,
      degreesOfFreedom: degreesOfFreedom,
      pValueTwoTailed: pValue,
      cohensD: cohensD,
    );
  }

  // -----------------------------------------------------------------
  // Student's t two-tailed p-value, via the regularized incomplete
  // beta function: P(|T| > t) = I_{df/(df+t^2)}(df/2, 1/2).
  // Implementation follows the standard continued-fraction method
  // (Lentz's algorithm), the same technique used by most numerical
  // libraries (e.g. Numerical Recipes' betai/betacf) — included here
  // directly so this module has no external statistics package
  // dependency.
  // -----------------------------------------------------------------

  static double _twoTailedPValueFromT(double t, int degreesOfFreedom) {
    if (t.isNaN || degreesOfFreedom < 1) return double.nan;
    final df = degreesOfFreedom.toDouble();
    final x = df / (df + t * t);
    return _regularizedIncompleteBeta(x, df / 2.0, 0.5);
  }

  static double _logGamma(double x) {
    // Lanczos approximation (g=7, n=9 coefficients) — standard,
    // widely-used, accurate to ~15 significant digits.
    const g = 7;
    const coefficients = [
      0.99999999999980993,
      676.5203681218851,
      -1259.1392167224028,
      771.32342877765313,
      -176.61502916214059,
      12.507343278686905,
      -0.13857109526572012,
      9.9843695780195716e-6,
      1.5056327351493116e-7,
    ];
    if (x < 0.5) {
      return math.log(math.pi / math.sin(math.pi * x)) - _logGamma(1 - x);
    }
    final xx = x - 1;
    double a = coefficients[0];
    final t = xx + g + 0.5;
    for (int i = 1; i < g + 2; i++) {
      a += coefficients[i] / (xx + i);
    }
    return 0.5 * math.log(2 * math.pi) + (xx + 0.5) * math.log(t) - t + math.log(a);
  }

  static double _betacf(double a, double b, double x) {
    const maxIterations = 200;
    const epsilon = 3.0e-9;
    const fpMin = 1.0e-30;

    final qab = a + b;
    final qap = a + 1.0;
    final qam = a - 1.0;
    double c = 1.0;
    double d = 1.0 - qab * x / qap;
    if (d.abs() < fpMin) d = fpMin;
    d = 1.0 / d;
    double h = d;

    for (int m = 1; m <= maxIterations; m++) {
      final m2 = 2 * m;
      var aa = m * (b - m) * x / ((qam + m2) * (a + m2));
      d = 1.0 + aa * d;
      if (d.abs() < fpMin) d = fpMin;
      c = 1.0 + aa / c;
      if (c.abs() < fpMin) c = fpMin;
      d = 1.0 / d;
      h *= d * c;

      aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2));
      d = 1.0 + aa * d;
      if (d.abs() < fpMin) d = fpMin;
      c = 1.0 + aa / c;
      if (c.abs() < fpMin) c = fpMin;
      d = 1.0 / d;
      final del = d * c;
      h *= del;

      if ((del - 1.0).abs() < epsilon) break;
    }
    return h;
  }

  static double _regularizedIncompleteBeta(double x, double a, double b) {
    if (x <= 0.0) return 0.0;
    if (x >= 1.0) return 1.0;

    final logBeta =
        _logGamma(a + b) - _logGamma(a) - _logGamma(b) + a * math.log(x) + b * math.log(1 - x);
    final front = math.exp(logBeta);

    if (x < (a + 1.0) / (a + b + 2.0)) {
      return front * _betacf(a, b, x) / a;
    } else {
      return 1.0 - front * _betacf(b, a, 1 - x) / b;
    }
  }
}
