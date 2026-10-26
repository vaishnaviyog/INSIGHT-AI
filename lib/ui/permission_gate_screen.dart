import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

/// Fix 4 (Permission Handling): requests camera, location, and
/// microphone permissions and only shows [child] once all three are
/// granted. Previously the app requested permissions once in main()
/// without checking the result, so a denial surfaced later as an
/// unhandled runtime failure inside NavigationScreen rather than a
/// clear message here.
///
/// Scope note: this screen ONLY gates on permission status. It does
/// not touch HomeScreen, NavigationScreen, or any other existing
/// startup logic — camera enumeration and Hive initialization in
/// main() are unchanged.
class PermissionGateScreen extends StatefulWidget {
  final Widget child;
  const PermissionGateScreen({super.key, required this.child});

  @override
  State<PermissionGateScreen> createState() => _PermissionGateScreenState();
}

enum _GateState { checking, granted, denied, permanentlyDenied }

class _PermissionGateScreenState extends State<PermissionGateScreen> {
  static const _requiredPermissions = [
    Permission.camera,
    Permission.location,
    Permission.microphone,
  ];

  _GateState _state = _GateState.checking;

  @override
  void initState() {
    super.initState();
    _checkAndRequest();
  }

  Future<void> _checkAndRequest() async {
    setState(() => _state = _GateState.checking);

    try {
      final statuses = await _requiredPermissions.request();

      final anyPermanentlyDenied = statuses.values.any((s) => s.isPermanentlyDenied);
      final allGranted = statuses.values.every((s) => s.isGranted);

      if (allGranted) {
        setState(() => _state = _GateState.granted);
      } else if (anyPermanentlyDenied) {
        setState(() => _state = _GateState.permanentlyDenied);
      } else {
        setState(() => _state = _GateState.denied);
      }
    } catch (e) {
      // Prevent a crash: if the permission plugin itself fails
      // (platform channel error, etc.), fail into the "denied" UI
      // state with a retry option rather than propagating an
      // exception up through the widget tree.
      // ignore: avoid_print
      print('PermissionGateScreen: permission request failed: $e');
      if (mounted) setState(() => _state = _GateState.denied);
    }
  }

  @override
  Widget build(BuildContext context) {
    switch (_state) {
      case _GateState.granted:
        return widget.child;

      case _GateState.checking:
        return const Scaffold(
          body: Center(child: CircularProgressIndicator()),
        );

      case _GateState.denied:
        return _buildMessageScreen(
          message: 'Camera, location, and microphone access are required for '
              'navigation, hazard detection, and voice guidance to work.',
          buttonLabel: 'Grant Permissions',
          onPressed: _checkAndRequest,
        );

      case _GateState.permanentlyDenied:
        return _buildMessageScreen(
          message: 'One or more required permissions were permanently denied. '
              'Please enable Camera, Location, and Microphone access for this '
              'app in your device Settings.',
          buttonLabel: 'Open App Settings',
          onPressed: () async {
            await openAppSettings();
            // When the user returns from Settings, re-check rather
            // than assuming — they may or may not have granted it.
            if (mounted) _checkAndRequest();
          },
        );
    }
  }

  Widget _buildMessageScreen({
    required String message,
    required String buttonLabel,
    required VoidCallback onPressed,
  }) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.warning_amber_rounded, size: 48, color: Colors.amber),
              const SizedBox(height: 16),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 24),
              Semantics(
                button: true,
                label: buttonLabel,
                child: ElevatedButton(
                  onPressed: onPressed,
                  child: Text(buttonLabel),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
