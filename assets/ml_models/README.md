# Object Detection Model Files

## Production detector: YOLOv8n (current)

`YoloTfliteHazardDetector` (see `lib/services/hazard_detectors/`) is now
the ACTIVE production hazard detector, replacing the earlier COCO SSD
MobileNet detector (deleted — see below). It expects two files in this
folder, which are **not committed to source control** (binary model
files don't belong in git history for a project like this):

```
assets/ml_models/yolov8n.tflite
assets/ml_models/yolov8n_labels.txt
```

🚫 **BLOCKED: neither file is present in this repository right now.**
Until both are added, `YoloTfliteHazardDetector.isAvailable` stays
false and object detection produces nothing — see
`YoloTfliteHazardDetector.health` for a granular self-test report
(model file found/loaded, label file found/loaded, input shape valid,
output shape valid, inference ready) if you need to diagnose exactly
which step is failing after adding the files.

### Exact requirements

- **Filename / path:** `assets/ml_models/yolov8n.tflite` (model),
  `assets/ml_models/yolov8n_labels.txt` (labels — already bundled in
  this repo as the standard 80-class COCO list in Ultralytics' export
  order; replace it only if your export uses a custom/different class
  set).
- **Expected input shape:** `[1, height, width, 3]` — read from the
  model at runtime by `YoloTfliteHazardDetector.initialize()`, NOT
  hardcoded. A standard Ultralytics YOLOv8n export is typically
  640×640, but the code does not assume this.
- **Expected input dtype:** either `float32` (normalized 0..1) or
  `uint8` (raw 0..255) — also detected at runtime from the model's own
  input tensor type, not assumed.
- **Expected output shape:** `[1, 4+numClasses, numBoxes]` — the
  standard YOLOv8 TFLite export layout with NO built-in NMS (e.g.
  `[1, 84, 8400]` for the standard 80-COCO-class, 640×640, square
  export). `YoloTfliteHazardDetector` decodes this itself (per-box
  argmax class scoring, confidence filtering, greedy per-class IoU
  NMS) — this exact decode was already implemented and exercised by
  `ModelBenchmarkService._runYoloStyle` when this same candidate was
  benchmarked pre-replacement; the production detector reuses that
  algorithm, extended to keep full box geometry.
- **Label file:** `yolov8n_labels.txt`, one class name per line, index
  0 = the first line. NO leading placeholder line (unlike some legacy
  SSD label file distributions) — a standard Ultralytics COCO export
  does not have that quirk.

### How to obtain a compatible model

Export from Ultralytics directly (recommended — guarantees an
input/output shape this decoder is written against):

```
pip install ultralytics
yolo export model=yolov8n.pt format=tflite imgsz=640
```

This produces `yolov8n_float32.tflite` (and/or a quantized variant
depending on export flags) — rename whichever you use to
`yolov8n.tflite` and place it in this folder.

**Supported dtypes: `float32`, `uint8`, and `int8`.** A fully-integer
quantized export (Ultralytics `int8=True`) typically produces an
`int8` input tensor AND an `int8` output tensor, each with its own
independent `[scale, zeroPoint]` pair — `YoloTfliteHazardDetector`
reads both from the loaded model's own tensors at `initialize()` time
(never hardcoded, since a different export/calibration run produces
different values) and re-quantizes/dequantizes against them at
`detect()`-time, rather than assuming a shared constant or rejecting
int8 outright. `YoloTfliteHazardDetector` reads the actual input
AND output tensor dtypes at runtime rather than assuming either, for
whichever of the three supported types you use.

Alternatively, a pre-converted `yolov8n` TFLite export from a trusted
source (e.g. one already verified during this project's own benchmark
harness evaluation — see `assets/ml_models/benchmark_candidates/`
below) can be copied/renamed into this location instead of exporting
your own.

### Verifying the file after adding it

There is no SHA-256 to check against here — an Ultralytics export is
deterministic per `ultralytics` package version/export flags/PyTorch
version, not a single canonical published binary with one fixed hash.
Verify correctness functionally instead:

1. Add the two files to this folder and rebuild
   (`flutter pub get && flutter run`).
2. Open the app's Research Menu → check `YoloTfliteHazardDetector`'s
   status (surfaced via `HazardDetectionService.detectorAvailability`
   on the debug dashboard) reads available/ready, not "unavailable."
3. Point the camera at a person or vehicle and confirm a bounding box
   + spoken warning appears within a couple of seconds (the temporal
   filter requires 3 consecutive confirming frames before speaking).
4. If detections are consistently the WRONG class (e.g. every car
   reported as something unrelated), your export's class order may not
   match `yolov8n_labels.txt` — verify against your export's own
   `names` field (visible via `yolo export ... verbose=True` output, or
   by inspecting `metadata.yaml` if your export tool produces one) and
   correct `yolov8n_labels.txt` to match if needed.

Once both files are in this folder, no code changes are needed —
`YoloTfliteHazardDetector` is already wired in as the default detector
in `HazardDetectionService`.

## Retired: COCO SSD MobileNet

The earlier production detector (`CocoTfliteHazardDetector`,
`coco_ssd_mobilenet.tflite` + a legacy-format `coco_labels.txt`) has
been fully removed from the production pipeline and its class file
deleted — confirmed unreferenced anywhere else in the app before
removal. It remains available as an independent benchmark BASELINE
candidate only (see the "Benchmark candidate models" section below and
`BenchmarkModelSpec.candidates`'s "SSD MobileNet V1 (current
baseline)" entry, which has its own fully self-contained decode logic
and does not depend on the deleted class) — if you want that
comparison, the old download instructions still apply for THAT
specific path only, not for production detection.

---

## Benchmark candidate models (pre-replacement evaluation)

The Model Benchmark Harness (Research Menu -> "Vision Model Benchmark")
measures real, on-device numbers for three candidate replacements before
any of them is wired into the production detector. None of these are
committed to source control, same reasoning as above. Place them under
`assets/ml_models/benchmark_candidates/`:

```
assets/ml_models/benchmark_candidates/ssdlite_mobiledet.tflite
assets/ml_models/benchmark_candidates/ssdlite_mobiledet_labels.txt
assets/ml_models/benchmark_candidates/efficientdet_lite0.tflite
assets/ml_models/benchmark_candidates/efficientdet_lite0_labels.txt
assets/ml_models/benchmark_candidates/yolov8n.tflite
assets/ml_models/benchmark_candidates/yolov8n_labels.txt
```

A candidate whose file isn't present yet simply reports a clear
"asset not found" result in the harness — it does not block benchmarking
the others.

### SSDLite MobileDet
TensorFlow's official TFLite-exported checkpoint (COCO-trained,
`ssdlite_mobiledet_cpu` or `_edgetpu` variant — the CPU variant is the
correct one for this harness). Available from the TensorFlow Model
Garden / TF2 Detection Model Zoo.

### EfficientDet-Lite0
Export via TensorFlow Lite Model Maker or download a pre-converted
`efficientdet_lite0.tflite` from TensorFlow Hub. Expects the standard
4-tensor SSD-style postprocessing op output (boxes/classes/scores/count)
— verify this against whichever exact source you use; some raw
EfficientDet exports use a different output layout and would need
re-exporting with the postprocessing op included.

### YOLOv8n
Export from Ultralytics: `yolo export model=yolov8n.pt format=tflite`.
This produces a single-tensor `[1, 84, 8400]`-shaped output (no built-in
NMS) at 640x640 input — decoded by
`ModelBenchmarkService._runYoloStyle`. Both float32 and int8-quantized
exports are supported (the harness reads the interpreter's own input
tensor type at runtime); note that some int8 exports quantize pixel
values differently than the 0..1 float assumption
`ModelBenchmarkService._imageToFloat32Bytes` uses for the float variant
— if a candidate loads and runs without error but its outputs look wrong
during a later manual check, this normalization mismatch is the first
thing to verify.

### YOLO11n (optional fourth candidate)
`yolo export model=yolo11n.pt format=tflite` — TFLite export is
supported (community-confirmed export logs report a single-tensor
output around `[1, 84, 5040]` or `[1, 84, 8400]` depending on the exact
`imgsz` used). `ModelBenchmarkService` reads the output tensor's actual
shape at runtime rather than hardcoding either, so both export sizes
work without code changes. Officially reported COCO mAP is ~39 per
Ultralytics' own published figures — not independently re-verified by
this project, and NOT assumed to beat the other three candidates; that's
exactly what the comparison report (below) is for.

### A note on what this harness does NOT tell you
Bundling and benchmarking a model here does not make it production-ready
— label vocabulary, priority-tier mapping (like `CocoLabelConfig`), and
distance-estimation calibration (like `DistanceEstimationConfig`) all
still need to be built for whichever candidate wins, as a new
`IHazardDetector` implementation. The harness answers "is this fast/
light/accurate/efficient enough," not "is this fully integrated."

### Measuring per-model APK size
The harness cannot measure this automatically — an app can't observe its
own installed APK's size on disk in a way that isolates one candidate's
contribution, especially with all four candidates' assets bundled in one
build for convenience during benchmarking. To get a real per-model
number:

1. Temporarily comment out every candidate's asset except the one you're
   measuring in `pubspec.yaml`'s `flutter: assets:` list (or move the
   other three out of `benchmark_candidates/` temporarily).
2. `flutter build apk --release --analyze-size` — this prints a
   breakdown including exactly how much each bundled asset contributes.
3. Record the number in the harness's result — each exported CSV row has
   an `apk_size_manual_note_mb` column left blank for you to fill in
   after the fact (it is never auto-populated, so a blank there means
   "not measured yet," not zero).

### Detection quality (precision/recall/false positives/false negatives/stability/time-to-warning)
Optional — only computed if you annotate the captured frames in the
harness's Step 2 (mark which of the 9 evaluated hazard classes are
genuinely visible in each frame). This is a FRAME-LEVEL class-presence
proxy, not IoU-matched mAP: a class counts as correctly detected if the
model reports it anywhere in the frame and you marked it present, not
based on bounding-box location/count accuracy. It's only ever computed
on the CPU-delegate row per model (detection output doesn't meaningfully
change across delegates the way speed does) — see
`ModelBenchmarkResult`'s class doc comment for the full reasoning. With
only 8 sample frames this is a rough signal, not a statistically robust
evaluation — recapture and re-annotate a larger, more varied set of
frames (ideally across multiple real walks, not one static scene) before
treating any precision/recall number here as final.

**Detection stability** measures whether a genuinely-present class
flickers on/off across the captured frame sequence's original temporal
order (not the FPS pass's cycled reuse) — a model that's naturally more
consistent frame-to-frame needs less of production's 3-frame
`HazardTemporalFilter` delay to feel reliable.

**Time-to-warning** measures, per class, the elapsed processing time
from when it first appears in the burst to when it would be confirmed
under the SAME 3-consecutive-frame rule `HazardTemporalFilter` uses in
production. This is INFERENCE-SIDE ONLY — it does not include
`HazardDetectionService`'s real 300ms minimum-interval throttle between
detection runs, or `AudioService`/`LanguageService`'s TTS `speak()`
latency (both tracked separately elsewhere in the app via
`RuntimeMetricsCollector`). Treat it as "how much of the total
time-to-spoken-warning budget this model's inference consumes," not the
full real-world number.

### Continuous endurance pass (battery drain + thermal stability)
A short quick-pass run (tens of iterations, seconds of wall time) cannot
show a measurable battery PERCENTAGE drop or real thermal throttling —
both need a genuinely sustained window. Step 6 runs each selected
model/delegate combination continuously, back to back, for a
configurable duration (default 15 minutes), sampling battery percentage
before/after (a real drop, not just instantaneous current), and thermal
status/headroom periodically throughout — tracking the PEAK thermal
status reached at any point during the run, not just the final reading,
so a mid-run spike that recovers by the end isn't hidden.

This is deliberately a separate, explicit action from the quick pass:
running every selected combination for the full duration is a real time
cost (e.g. 4 models x 3 delegates x 15 minutes = 3 hours), so run it
intentionally for the combinations you actually need sustained data for.
Keep the device plugged into nothing and the app in the foreground for
the whole run, or the battery/thermal numbers won't reflect this
workload specifically.

### Comparison report (Step 7)
Aggregates every stored result — this session and any prior ones on
this device — into one profile per candidate model (using its
best-performing delegate for speed/memory/CPU, its CPU-delegate row for
detection quality/stability/time-to-warning, and a real endurance-test
row for battery/thermal where one exists), then scores each candidate
with weighted, min-max-normalized metrics and ranks them.

**The weights are suggested defaults, not an objective fact** — see
`BenchmarkComparisonService.defaultWeights` for the exact numbers and
rationale (detection quality and time-to-warning weighted highest for a
safety-relevant feature, resource cost moderate, APK size lowest).
Adjust and re-run if your priorities differ; the generated report always
states the weights used so the recommendation is fully re-derivable.

**A metric missing for one candidate is excluded from that candidate's
score, never scored as worst** — e.g. if you only annotated ground truth
for two of four candidates, the other two are ranked on their remaining
available metrics, and the report explicitly lists which metrics were
unavailable for which model rather than silently averaging past the gap.

The report is exported as a `.md` file to the app's documents directory
and also shown inline in the harness screen.
