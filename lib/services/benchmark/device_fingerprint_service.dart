import 'package:device_info_plus/device_info_plus.dart';

/// Plain snapshot of the device a benchmark run happened on. Read
/// once per benchmark session (not once per model/delegate run —
/// it can't change mid-session) and attached to every
/// [ModelBenchmarkResult] so results collected from many different
/// physical devices/testers can be told apart when the exported CSVs
/// are aggregated later.
class DeviceFingerprint {
  final String model;
  final String manufacturer;
  final String androidRelease;
  final int androidSdkInt;

  /// `Build.HARDWARE` — the closest thing to a chipset identifier
  /// available without a vendor-specific API (e.g. often something
  /// like "qcom" or a SoC codename). Best-effort, not authoritative —
  /// note in the exported CSV that this may need cross-referencing
  /// against the device model for a real chipset name.
  final String? hardware;

  const DeviceFingerprint({
    required this.model,
    required this.manufacturer,
    required this.androidRelease,
    required this.androidSdkInt,
    this.hardware,
  });

  static const DeviceFingerprint unknown = DeviceFingerprint(
    model: 'unknown',
    manufacturer: 'unknown',
    androidRelease: 'unknown',
    androidSdkInt: 0,
  );
}

class DeviceFingerprintService {
  static Future<DeviceFingerprint> current() async {
    try {
      final info = DeviceInfoPlugin();
      final androidInfo = await info.androidInfo;
      return DeviceFingerprint(
        model: androidInfo.model,
        manufacturer: androidInfo.manufacturer,
        androidRelease: androidInfo.version.release,
        androidSdkInt: androidInfo.version.sdkInt,
        hardware: androidInfo.hardware,
      );
    } catch (e) {
      // ignore: avoid_print
      print('DeviceFingerprintService: failed to read device info (non-fatal): $e');
      return DeviceFingerprint.unknown;
    }
  }
}
