package com.project1.vaishnavi

import android.os.BatteryManager
import android.os.Build
import android.os.Debug
import android.os.PowerManager
import android.os.Process
import android.os.SystemClock
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Adds ONE method channel, used exclusively by the Model Benchmark
/// Harness (see lib/services/benchmark/) to read runtime metrics
/// while timing candidate TFLite models: native heap, process CPU
/// time, battery discharge current, and thermal status/headroom.
/// None of these are used by any production feature — every call
/// site on the Dart side (`NativeMetricsChannel`) already treats a
/// failed/unsupported call as "unavailable," never a crash, so this
/// channel is safe to leave in place outside of active benchmarking.
class MainActivity : FlutterActivity() {
    private val benchmarkMetricsChannel = "com.project1.vaishnavi/benchmark_metrics"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, benchmarkMetricsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getNativeHeapAllocatedSize" -> result.success(Debug.getNativeHeapAllocatedSize())

                    // android.os.Process.getElapsedCpuTime() already returns
                    // milliseconds of CPU time consumed by this process since
                    // it started (across all cores) — no manual /proc/stat
                    // parsing or clock-tick conversion needed.
                    "getProcessCpuTimeMs" -> result.success(Process.getElapsedCpuTime())

                    "getElapsedRealtimeMs" -> result.success(SystemClock.elapsedRealtime())

                    "getCpuCoreCount" -> result.success(Runtime.getRuntime().availableProcessors())

                    // Instantaneous battery discharge current, in microamps.
                    // SIGN CONVENTION IS NOT UNIVERSALLY GUARANTEED ACROSS
                    // OEMs (most report negative while discharging, but this
                    // is documented as manufacturer-dependent) — the Dart
                    // side reports the raw signed value and leaves
                    // interpretation to whoever reads the exported CSV,
                    // rather than assuming a sign and silently flipping it.
                    "getBatteryCurrentNowMicroAmps" -> {
                        try {
                            val batteryManager = getSystemService(BATTERY_SERVICE) as BatteryManager
                            result.success(batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW))
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }

                    // Battery charge percentage (0-100), used for the
                    // continuous/sustained battery-drain test — unlike
                    // instantaneous current, a percentage drop is only
                    // meaningful over a genuinely long window (the harness's
                    // 15-minute continuous mode), which is why this exists
                    // alongside, not instead of, current-now sampling.
                    "getBatteryPercentage" -> {
                        try {
                            val batteryManager = getSystemService(BATTERY_SERVICE) as BatteryManager
                            result.success(batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                        } catch (e: Exception) {
                            result.success(null)
                        }
                    }

                    // Thermal status is API 29+ (Android 10). On this app's
                    // minSdk 24, older devices report null (unavailable),
                    // never a fabricated "not throttled" value.
                    "getThermalStatus" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val powerManager = getSystemService(POWER_SERVICE) as PowerManager
                            result.success(powerManager.currentThermalStatus)
                        } else {
                            result.success(null)
                        }
                    }

                    // Thermal headroom forecast is API 30+ (Android 11).
                    "getThermalHeadroom" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                            try {
                                val powerManager = getSystemService(POWER_SERVICE) as PowerManager
                                val forecastSeconds = (call.arguments as? Int) ?: 10
                                val headroom = powerManager.getThermalHeadroom(forecastSeconds)
                                // NaN means "not currently available" per the
                                // platform docs — pass that through as null
                                // rather than a misleading 0.0.
                                if (headroom.isNaN()) result.success(null) else result.success(headroom.toDouble())
                            } catch (e: Exception) {
                                result.success(null)
                            }
                        } else {
                            result.success(null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}
