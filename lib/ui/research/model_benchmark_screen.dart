import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../../main.dart';
import '../../models/benchmark_result.dart';
import '../../services/benchmark/benchmark_comparison_service.dart';
import '../../services/benchmark/benchmark_model_spec.dart';
import '../../services/benchmark/benchmark_report_service.dart';
import '../../services/benchmark/device_fingerprint_service.dart';
import '../../services/benchmark/hazard_label_canonicalizer.dart';
import '../../services/benchmark/model_benchmark_service.dart';

/// Model Benchmark Research Framework — measures FPS, latency,
/// memory, CPU, battery (instantaneous + sustained), thermal
/// stability, detection precision/recall/false-positives/false-
/// negatives, detection stability, time-to-warning, and an APK-size
/// proxy for each candidate model under each delegate — then
/// generates a weighted, ranked comparison report recommending a
/// production candidate from measured data, never a manual pick.
///
/// Nothing here is wired into the production detection pipeline (see
/// `BenchmarkModelSpec`'s doc comment) — the production detector is
/// not replaced until this framework's report is generated and
/// reviewed. Reachable from Research Menu -> "Vision Model Benchmark".
class ModelBenchmarkScreen extends StatefulWidget {
  const ModelBenchmarkScreen({super.key});

  @override
  State<ModelBenchmarkScreen> createState() => _ModelBenchmarkScreenState();
}

class _ModelBenchmarkScreenState extends State<ModelBenchmarkScreen> {
  static const int _sampleFrameCount = 8;

  CameraController? _cameraController;
  final List<CameraImage> _sampleFrames = [];
  final List<Uint8List> _frameThumbnails = [];
  bool _isCapturingFrames = false;
  bool _framesReady = false;

  late List<Set<String>> _groundTruth = List.generate(_sampleFrameCount, (_) => <String>{});

  final Set<BenchmarkModelSpec> _selectedSpecs = {};
  final Set<InferenceDelegate> _selectedDelegates = {
    InferenceDelegate.cpu,
    InferenceDelegate.nnapi,
    InferenceDelegate.gpu,
  };

  int _timedIterations = 30;
  int _enduranceMinutes = 15;

  final ModelBenchmarkService _benchmarkService = ModelBenchmarkService();
  final BenchmarkReportService _reportService = BenchmarkReportService();
  final BenchmarkComparisonService _comparisonService = BenchmarkComparisonService();

  bool _isRunning = false;
  String? _progressLabel;
  final List<ModelBenchmarkResult> _sessionResults = [];
  String? _exportedCsvPath;
  String? _reportMarkdown;
  String? _exportedReportPath;

  @override
  void initState() {
    super.initState();
    _reportService.initialize();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _reportService.dispose();
    super.dispose();
  }

  Future<void> _captureSampleFrames() async {
    if (cameras.isEmpty) {
      _showMessage('No camera available on this device.');
      return;
    }
    setState(() {
      _isCapturingFrames = true;
      _framesReady = false;
      _sampleFrames.clear();
      _frameThumbnails.clear();
      _groundTruth = List.generate(_sampleFrameCount, (_) => <String>{});
    });

    // AUDIT FIX (Phase C4 — accuracy-measurement prerequisite): was
    // ImageFormatGroup.nv21, but ModelBenchmarkService._convertCameraImageToRgb
    // unconditionally decodes Android frames as 3-plane yuv420 (see that
    // method) — the exact P0-2 format/byte-layout mismatch already found
    // and fixed in the production capture path
    // (navigation_screen.dart/YoloTfliteHazardDetector). Left unfixed
    // here, every captured benchmark frame would be decoded with the
    // wrong plane semantics — silently wrong colors at best, a
    // `RangeError` on `image.planes[2]` at worst (nv21 is frequently NOT
    // delivered as 3 separate planes) — corrupting any accuracy
    // measurement built on these frames before the model ever sees them.
    final controller = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: Platform.isAndroid ? ImageFormatGroup.yuv420 : ImageFormatGroup.bgra8888,
    );

    try {
      // AUDIT FIX (engineering-hardening phase — camera-lifecycle
      // defense-in-depth): the real app freeze this session came from
      // this exact `initialize()` call never resolving at all — a
      // second CameraController fighting NavigationScreen's own
      // controller for the same physical camera hung indefinitely,
      // with no exception ever thrown for the surrounding try/catch to
      // catch. That specific caller-ordering conflict is now prevented
      // upstream (NavigationScreen releases its camera before pushing
      // into Research Menu — see navigation_screen.dart's
      // `_releaseCameraForExternalScreen`), but nothing INSIDE this
      // screen itself previously guarded against the same failure mode
      // via any OTHER future path into it (a hypothetical new
      // navigation route, a retry, camera hardware genuinely busy for
      // an unrelated reason). A bounded timeout turns "the whole app
      // silently hangs forever" into a clear, recoverable, spoken/shown
      // error — the honest, fail-soft behavior every other camera
      // touch point in this codebase already has.
      await controller.initialize().timeout(
        const Duration(seconds: 8),
        onTimeout: () => throw StateError(
            'Camera did not respond within 8s — it may be in use by another part of the app.'),
      );
      _cameraController = controller;
      await controller.startImageStream((image) {
        if (_sampleFrames.length < _sampleFrameCount) _sampleFrames.add(image);
      });
      // Same reasoning as the initialize() timeout above — never wait
      // for camera frames indefinitely. 100ms polls, capped at 10s
      // total, is generous for 8 frames at any real camera frame rate.
      final captureDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (_sampleFrames.length < _sampleFrameCount && DateTime.now().isBefore(captureDeadline)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      await controller.stopImageStream();
      if (_sampleFrames.length < _sampleFrameCount) {
        throw StateError(
            'Only captured ${_sampleFrames.length}/$_sampleFrameCount frames before timing out.');
      }
      for (final frame in _sampleFrames) {
        _frameThumbnails.add(_buildThumbnail(frame, controller.description.sensorOrientation));
      }
    } catch (e) {
      _showMessage('Frame capture failed: $e');
    } finally {
      setState(() {
        _isCapturingFrames = false;
        _framesReady = _sampleFrames.isNotEmpty;
      });
    }
  }

  Uint8List _buildThumbnail(CameraImage image, int sensorOrientation) {
    try {
      img.Image converted;
      if (Platform.isAndroid) {
        final width = image.width, height = image.height;
        final yPlane = image.planes[0];
        final out = img.Image(width: width, height: height);
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            final v = yPlane.bytes[y * yPlane.bytesPerRow + x];
            out.setPixelRgb(x, y, v, v, v);
          }
        }
        converted = out;
      } else {
        final width = image.width, height = image.height;
        final plane = image.planes[0];
        final out = img.Image(width: width, height: height);
        for (int y = 0; y < height; y++) {
          for (int x = 0; x < width; x++) {
            final index = y * plane.bytesPerRow + x * 4;
            out.setPixelRgb(x, y, plane.bytes[index + 2], plane.bytes[index + 1], plane.bytes[index]);
          }
        }
        converted = out;
      }
      if (sensorOrientation == 90) converted = img.copyRotate(converted, angle: 90);
      if (sensorOrientation == 180) converted = img.copyRotate(converted, angle: 180);
      if (sensorOrientation == 270) converted = img.copyRotate(converted, angle: 270);
      final small = img.copyResize(converted, width: 240);
      return Uint8List.fromList(img.encodeJpg(small, quality: 70));
    } catch (e) {
      return Uint8List(0);
    }
  }

  bool get _hasAnyGroundTruth => _groundTruth.any((s) => s.isNotEmpty);

  Future<void> _runQuickBenchmarks() async {
    if (_selectedSpecs.isEmpty || _selectedDelegates.isEmpty || !_framesReady) return;
    setState(() {
      _isRunning = true;
      _sessionResults.clear();
      _exportedCsvPath = null;
      _reportMarkdown = null;
    });

    final device = await DeviceFingerprintService.current();
    final sensorOrientation = _cameraController?.description.sensorOrientation ?? 90;
    final groundTruth = _hasAnyGroundTruth ? _groundTruth : null;

    for (final spec in _selectedSpecs) {
      for (final delegate in _selectedDelegates) {
        setState(() => _progressLabel = 'Quick pass: ${spec.displayName} on ${delegate.name}...');
        final result = await _benchmarkService.runQuickBenchmark(
          spec: spec,
          delegate: delegate,
          sampleFrames: _sampleFrames,
          sensorOrientation: sensorOrientation,
          device: device,
          groundTruthByFrameIndex: groundTruth,
          timedIterations: _timedIterations,
        );
        await _reportService.record(result);
        setState(() => _sessionResults.add(result));
      }
    }
    setState(() {
      _isRunning = false;
      _progressLabel = null;
    });
  }

  Future<void> _runEnduranceTests() async {
    if (_selectedSpecs.isEmpty || _selectedDelegates.isEmpty || !_framesReady) return;
    final totalMinutes = _selectedSpecs.length * _selectedDelegates.length * _enduranceMinutes;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Run continuous endurance test?'),
        content: Text('${_selectedSpecs.length} model(s) x ${_selectedDelegates.length} delegate(s) x '
            '$_enduranceMinutes minutes each = roughly $totalMinutes minutes total, back to back. '
            'Keep the app in the foreground and the device plugged into nothing (so battery drain is '
            'real) for the duration.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Start')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _isRunning = true;
      _reportMarkdown = null;
    });

    final device = await DeviceFingerprintService.current();
    final sensorOrientation = _cameraController?.description.sensorOrientation ?? 90;

    for (final spec in _selectedSpecs) {
      for (final delegate in _selectedDelegates) {
        final result = await _benchmarkService.runContinuousEnduranceTest(
          spec: spec,
          delegate: delegate,
          sampleFrames: _sampleFrames,
          sensorOrientation: sensorOrientation,
          device: device,
          targetDuration: Duration(minutes: _enduranceMinutes),
          onProgress: (elapsed, remaining) => setState(() => _progressLabel =
              'Endurance: ${spec.displayName} on ${delegate.name} — '
              '${elapsed.inMinutes}m${elapsed.inSeconds % 60}s elapsed, ${remaining.inMinutes}m left'),
        );
        await _reportService.record(result);
        setState(() => _sessionResults.add(result));
      }
    }
    setState(() {
      _isRunning = false;
      _progressLabel = null;
    });
  }

  Future<void> _generateComparisonReport() async {
    final allResults = _reportService.allResults;
    if (allResults.isEmpty) {
      _showMessage('No stored results yet — run at least one benchmark first.');
      return;
    }
    final profiles = _comparisonService.buildProfiles(allResults);
    final ranked = _comparisonService.rank(profiles);
    final markdown = _comparisonService.generateMarkdownReport(ranked);
    final path = await _comparisonService.exportReportToFile(markdown);
    setState(() {
      _reportMarkdown = markdown;
      _exportedReportPath = path;
    });
  }

  Future<void> _exportCsv() async {
    final path = await _reportService.exportToCsv();
    setState(() => _exportedCsvPath = path);
    if (path == null) _showMessage('Nothing to export yet.');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vision Model Benchmark')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionHeader('Step 1 — Capture a shared set of test frames'),
          const Text(
            'Point the camera at a representative scene, then capture. The same frames are '
            'reused for every candidate so the comparison is fair.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _isCapturingFrames || _isRunning ? null : _captureSampleFrames,
            child: Text(_isCapturingFrames
                ? 'Capturing...'
                : _framesReady
                    ? 'Re-capture ($_sampleFrameCount frames captured)'
                    : 'Capture $_sampleFrameCount frames'),
          ),
          if (_framesReady) ...[
            const Divider(height: 32),
            _sectionHeader('Step 2 — Mark ground truth (enables precision/recall/stability/time-to-warning)'),
            const Text(
              'Check every hazard class genuinely visible in each frame, in order. Skip entirely to '
              'still get FPS/latency/memory/CPU/battery/thermal without detection-quality metrics.',
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 8),
            ..._frameThumbnails.asMap().entries.map(_frameAnnotationCard),
          ],
          const Divider(height: 32),
          _sectionHeader('Step 3 — Choose candidates'),
          const Text(
            'Only candidates whose .tflite file has been downloaded per assets/ml_models/README.md '
            'will actually run — others report a clear "asset not found" result.',
            style: TextStyle(color: Colors.grey),
          ),
          ...BenchmarkModelSpec.candidates.map((spec) => CheckboxListTile(
                value: _selectedSpecs.contains(spec),
                onChanged: _isRunning
                    ? null
                    : (checked) => setState(() {
                          if (checked == true) {
                            _selectedSpecs.add(spec);
                          } else {
                            _selectedSpecs.remove(spec);
                          }
                        }),
                title: Text(spec.displayName),
                subtitle: Text('${spec.publishedSizeNote} · ${spec.publishedMapNote}'),
              )),
          const Divider(height: 32),
          _sectionHeader('Step 4 — Choose delegates to test'),
          const Text(
            'NNAPI and GPU do not uniformly help — testing all three catches a delegate that '
            'silently regresses on a specific device.',
            style: TextStyle(color: Colors.grey),
          ),
          ...InferenceDelegate.values.map((delegate) => CheckboxListTile(
                value: _selectedDelegates.contains(delegate),
                onChanged: _isRunning
                    ? null
                    : (checked) => setState(() {
                          if (checked == true) {
                            _selectedDelegates.add(delegate);
                          } else {
                            _selectedDelegates.remove(delegate);
                          }
                        }),
                title: Text(delegate.name.toUpperCase()),
              )),
          const Divider(height: 32),
          _sectionHeader('Step 5 — Quick pass'),
          const Text(
            'FPS/latency/memory/CPU (+ detection quality/stability/time-to-warning if annotated). '
            'Too short to show real battery drain or thermal throttling — see Step 6 for that.',
            style: TextStyle(color: Colors.grey),
          ),
          Slider(
            value: _timedIterations.toDouble(),
            min: 10,
            max: 200,
            divisions: 19,
            label: '$_timedIterations',
            onChanged: _isRunning ? null : (v) => setState(() => _timedIterations = v.round()),
          ),
          Text('$_timedIterations iterations per candidate/delegate combination'),
          ElevatedButton(
            onPressed: (_isRunning || !_framesReady || _selectedSpecs.isEmpty || _selectedDelegates.isEmpty)
                ? null
                : _runQuickBenchmarks,
            child: Text(_isRunning ? (_progressLabel ?? 'Running...') : 'Run quick pass'),
          ),
          const Divider(height: 32),
          _sectionHeader('Step 6 — Continuous endurance pass (battery drain + thermal stability)'),
          const Text(
            'A genuinely long, continuous run — the only way to see real battery percentage drop '
            'or thermal throttling. Runs each selected model/delegate combination back to back for '
            'the full duration below. Keep the app open and screen on for the whole run.',
            style: TextStyle(color: Colors.grey),
          ),
          Slider(
            value: _enduranceMinutes.toDouble(),
            min: 1,
            max: 30,
            divisions: 29,
            label: '$_enduranceMinutes min',
            onChanged: _isRunning ? null : (v) => setState(() => _enduranceMinutes = v.round()),
          ),
          Text('$_enduranceMinutes minutes per candidate/delegate combination'),
          ElevatedButton(
            onPressed: (_isRunning || !_framesReady || _selectedSpecs.isEmpty || _selectedDelegates.isEmpty)
                ? null
                : _runEnduranceTests,
            child: Text(_isRunning ? (_progressLabel ?? 'Running...') : 'Run endurance pass'),
          ),
          const Divider(height: 32),
          _sectionHeader('Step 7 — Comparison report'),
          const Text(
            'Aggregates every stored result (this session and any prior ones on this device), scores '
            'each candidate with weighted, normalized metrics, and ranks them — a data-driven '
            'recommendation, not a manual pick.',
            style: TextStyle(color: Colors.grey),
          ),
          ElevatedButton.icon(
            onPressed: _isRunning ? null : _generateComparisonReport,
            icon: const Icon(Icons.leaderboard_outlined),
            label: const Text('Generate comparison report'),
          ),
          if (_reportMarkdown != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade700)),
              child: SelectableText(_reportMarkdown!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            ),
            if (_exportedReportPath != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Report saved to: $_exportedReportPath', style: const TextStyle(color: Colors.grey)),
              ),
          ],
          const SizedBox(height: 24),
          if (_sessionResults.isNotEmpty) ...[
            const Text('Results (this session)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
            ..._sessionResults.map(_resultTile),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _exportCsv,
              icon: const Icon(Icons.download),
              label: const Text('Export all-time raw results to CSV'),
            ),
            if (_exportedCsvPath != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Exported to: $_exportedCsvPath', style: const TextStyle(color: Colors.grey)),
              ),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(String text) =>
      Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16));

  Widget _frameAnnotationCard(MapEntry<int, Uint8List> entry) {
    final index = entry.key;
    final thumbnail = entry.value;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (thumbnail.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.memory(thumbnail, width: 100, height: 100, fit: BoxFit.cover),
              )
            else
              const SizedBox(width: 100, height: 100, child: Icon(Icons.broken_image)),
            const SizedBox(width: 8),
            Expanded(
              child: Wrap(
                spacing: 4,
                children: HazardLabelCanonicalizer.canonicalClasses.map((c) {
                  final selected = _groundTruth[index].contains(c);
                  return FilterChip(
                    label: Text(c, style: const TextStyle(fontSize: 11)),
                    selected: selected,
                    onSelected: (checked) => setState(() {
                      if (checked) {
                        _groundTruth[index].add(c);
                      } else {
                        _groundTruth[index].remove(c);
                      }
                    }),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultTile(ModelBenchmarkResult result) {
    if (!result.succeeded) {
      return ListTile(
        leading: const Icon(Icons.error_outline, color: Colors.redAccent),
        title: Text('${result.modelName} — ${result.delegate.name.toUpperCase()} (${result.testMode.name})'),
        subtitle: Text(result.failureReason ?? 'Failed'),
      );
    }

    final lines = <String>[
      'FPS: ${result.estimatedFps?.toStringAsFixed(1)} · Mean: ${result.meanLatencyMs?.toStringAsFixed(1)}ms',
      'Heap Δ: ${result.nativeHeapDeltaBytes != null ? '${(result.nativeHeapDeltaBytes! / 1024 / 1024).toStringAsFixed(1)} MB' : 'n/a'} '
          '· CPU: ${result.cpuUsagePercentOfOneCore?.toStringAsFixed(0) ?? 'n/a'}%',
      'Battery: ${result.avgBatteryCurrentMicroAmps != null ? '${(result.avgBatteryCurrentMicroAmps! / 1000).toStringAsFixed(1)} mA' : 'n/a'}'
          '${result.batteryPercentDrop != null ? ' · ${result.batteryPercentDrop}% drop over ${result.testDurationSeconds != null ? (result.testDurationSeconds! / 60).toStringAsFixed(0) : '?'}min' : ''} '
          '· Thermal peak: ${result.thermalStatusPeak ?? 'n/a'}',
    ];
    if (result.precision != null) {
      lines.add('Precision/Recall: ${(result.precision! * 100).toStringAsFixed(0)}%/${(result.recall! * 100).toStringAsFixed(0)}% '
          '· TP/FP/FN: ${result.truePositives}/${result.falsePositives}/${result.falseNegatives} '
          '· Stability: ${result.detectionStabilityScore != null ? '${(result.detectionStabilityScore! * 100).toStringAsFixed(0)}%' : 'n/a'} '
          '· Time-to-warning: ${result.meanTimeToWarningMs != null ? '${result.meanTimeToWarningMs!.toStringAsFixed(0)}ms' : 'n/a'}');
    } else if (result.detectionQualityNote != null) {
      lines.add(result.detectionQualityNote!);
    }

    return ListTile(
      leading: const Icon(Icons.check_circle_outline, color: Colors.greenAccent),
      title: Text('${result.modelName} — ${result.delegate.name.toUpperCase()} (${result.testMode.name})'),
      subtitle: Text(lines.join('\n')),
      isThreeLine: true,
    );
  }
}
