import 'package:flutter/services.dart';

/// Reads runtime metrics from the Android side that Dart has no
/// direct access to: native heap allocation, process CPU time,
/// battery discharge current, and thermal status/headroom. Used only
/// by the Model Benchmark Harness — see
/// `android/.../MainActivity.kt`'s `configureFlutterEngine` for the
/// platform-side handler.
///
/// EVERY METHOD RETURNS NULL, NEVER A FABRICATED VALUE, when a metric
/// is unavailable — unsupported Android version (thermal APIs are
/// 29+/30+), unsupported OS entirely (iOS isn't implemented for any
/// of these), or the platform call throwing for any other reason.
/// Callers must treat null as "not measured on this run," and the
/// harness's UI/CSV export must show that honestly rather than a zero
/// or a dash that could be misread as "no cost."
class NativeMetricsChannel {
  static const MethodChannel _channel =
      MethodChannel('com.project1.vaishnavi/benchmark_metrics');

  static Future<int?> readNativeHeapBytes() => _invokeInt('getNativeHeapAllocatedSize');

  /// Milliseconds of CPU time this process has consumed since it
  /// started, summed across all cores (Android's
  /// `Process.getElapsedCpuTime()`). Two calls (before/after a timed
  /// window) and a subtraction gives CPU time consumed BY that
  /// window — see `ModelBenchmarkService`'s CPU% calculation for how
  /// this is combined with wall-clock time and core count.
  static Future<int?> readProcessCpuTimeMs() => _invokeInt('getProcessCpuTimeMs');

  static Future<int?> readElapsedRealtimeMs() => _invokeInt('getElapsedRealtimeMs');

  static Future<int?> readCpuCoreCount() => _invokeInt('getCpuCoreCount');

  /// Instantaneous battery discharge current in microamps. SIGN IS
  /// MANUFACTURER-DEPENDENT (most devices report negative while
  /// discharging, but this isn't guaranteed for every OEM) — reported
  /// as-is, not normalized, so treat the sign per-device rather than
  /// assuming.
  static Future<int?> readBatteryCurrentNowMicroAmps() => _invokeInt('getBatteryCurrentNowMicroAmps');

  /// Battery charge percentage (0-100). Only meaningful as a
  /// before/after DELTA over a genuinely long (minutes, not seconds)
  /// window — see `ModelBenchmarkService`'s continuous-mode doc
  /// comment.
  static Future<int?> readBatteryPercentage() => _invokeInt('getBatteryPercentage');

  /// Android's `PowerManager` thermal status enum (0 = NONE, 1 = LIGHT,
  /// 2 = MODERATE, 3 = SEVERE, 4 = CRITICAL, 5 = EMERGENCY,
  /// 6 = SHUTDOWN). Null on Android < 10 or non-Android.
  static Future<int?> readThermalStatus() => _invokeInt('getThermalStatus');

  /// Forecasted thermal headroom (0.0 = nominal, 1.0 = throttling
  /// threshold, can exceed 1.0) [forecastSeconds] ahead. Null on
  /// Android < 11, non-Android, or when the platform reports "not
  /// currently available" (surfaced as NaN on the native side, mapped
  /// to null here rather than a misleading 0.0).
  static Future<double?> readThermalHeadroom({int forecastSeconds = 10}) async {
    try {
      final result =
          await _channel.invokeMethod<double>('getThermalHeadroom', forecastSeconds);
      return result;
    } catch (e) {
      // ignore: avoid_print
      print('NativeMetricsChannel: getThermalHeadroom failed (non-fatal): $e');
      return null;
    }
  }

  static Future<int?> _invokeInt(String method) async {
    try {
      return await _channel.invokeMethod<int>(method);
    } catch (e) {
      // ignore: avoid_print
      print('NativeMetricsChannel: $method failed (non-fatal): $e');
      return null;
    }
  }
}
