# Dissertation 1 — Architecture Analysis

Status: THEORETICALLY PROPOSED / SIMULATED (pre-hardware). No physical
testing has taken place. This document records what was found by
inspecting the INSIGHT Flutter codebase (repository root `lib/`)
and how the proposed IoT/WSN hardware extension relates to it.

---

## 1. Existing INSIGHT Architecture (as found in code)

INSIGHT is a Flutter mobile app. All sensing, decision-making and
feedback currently happen **on the phone**; there is no external
hardware anywhere in the current codebase. The relevant pipeline,
traced through the source:

```
Phone camera (CameraImage)
        │
        ▼
HazardDetectionService              lib/services/hazard_detection_service.dart
  - runs YoloTfliteHazardDetector (YOLOv8n TFLite) on-device
  - HazardTemporalFilter: an object must appear in ≥3 consecutive
    detection runs before being "confirmed"
  - CollisionTimeEstimator: estimates time-to-collision from two
    successive distance readings of the same label
        │  List<DetectedHazard>
        │  (label, priority, confidence, distanceBand,
        │   horizontalPosition: left/center/right,
        │   estimatedDistanceMeters, timeToCollisionSeconds)
        ▼
RiskAssessmentService.assess()      lib/services/risk_assessment_service.dart
  - stateless, explainable hand-weighted factor model
  - factors: Hazard (0.35), Walking Speed (0.15), Reaction/clearance
    latency (0.15), Route Familiarity (0.10), Behaviour Confidence
    (0.10), Navigation History (0.10), Environment/daylight (0.05)
  - → RiskAssessment { overallRiskScore, riskLevel, riskFactors,
      explanation }
        ▼
AdaptiveRiskEngine.assess()         lib/services/adaptive_risk/adaptive_risk_engine.dart
  - takes the RiskAssessment above as ONE meta-factor
    ("Core Perception & Behaviour", weight 0.60) and adds:
    Approach Trend (0.22, is the hazard distance closing frame to
    frame), Destination Confidence (0.10, from the Voice
    Understanding Layer), GPS Accuracy (0.08)
        ▼
NavigationDecisionEngine.decide()   lib/services/adaptive_risk/navigation_decision_engine.dart
  - fixed precedence order (not a weighted blend):
    1. immediate-danger hazard → stopImmediately (always interrupts)
    2. overall risk critical → slowDown (interrupts)
    3. awaiting voice confirmation → confirmDestination
    4. transit boarding/transferring → boardBus / prepareForTransfer
    5. high-urgency (non-immediate) hazard → slowDown
    6. otherwise → continueWalking
  - separate dedicated methods produce moveLeft / moveRight
    (from a hazard's left/right position), repeatInstruction, wait
        ▼
AudioService.speak()                lib/services/audio_service.dart
  - flutter_tts spoken feedback ONLY — there is no physical/haptic
    output anywhere in the current app. All warnings are voice.
```

In parallel, two independent subsystems exist:

- **EmergencyService** (`lib/services/emergency_service.dart`) — a
  manual SOS button, a cancellable 10‑second countdown, then an SMS +
  phone-dialer launch to stored emergency contacts, all logged to a
  local Hive event log. It already defines an extension point,
  **`IEmergencySignalSource`** (`lib/services/emergency/emergency_signal_source.dart`),
  whose doc comment explicitly anticipates future hardware triggers:
  *"an IMU (fall detection), an ultrasonic/ToF sensor (imminent
  collision), a smart cane, or a wearable's panic button."* A working
  example already exists in-app: `FallDetectionSignalSource` (phone
  accelerometer). This is the natural, already-designed integration
  point for a WSN-triggered SOS.
- **Journey/transit planning** (GTFS import, RAPTOR router, transit
  session state machine) — entirely unrelated to obstacle sensing or
  hardware; out of scope for Dissertation 1.

## 2. Dissertation 1 Extension

Dissertation 1 adds a **physical sensing and haptic-feedback layer**
that INSIGHT does not currently have: distributed ultrasonic sensor
node(s), a microcontroller running a **simplified, hardware-local**
risk classification, and **directional vibration motors** worn by the
user (simulated as LEDs in Wokwi — see §9 and
`SIMULATION_LIMITATIONS.md`), plus a physical SOS button.

It does **not** re-implement computer vision, the YOLO model, the
7-factor `RiskAssessmentService`, or the `AdaptiveRiskEngine`. Those
are mature, tuned, phone-side subsystems and are explicitly out of
scope to modify or duplicate (per the task constraints). The hardware
prototype instead demonstrates a much smaller, honestly-scoped
question: *can a cheap microcontroller + ultrasonic sensors + haptic
actuators detect an obstacle, classify a coarse risk/direction state,
and give directional feedback fast enough to be worth building
physically?*

## 3. What Remains Software-Only (unchanged, not touched)

- YOLOv8n camera-based hazard detection (`hazard_detectors/`)
- `HazardTemporalFilter`, `CollisionTimeEstimator`
- `RiskAssessmentService` (7-factor score) and `AdaptiveRiskEngine`
  (Core/Approach Trend/Destination Confidence/GPS)
- `NavigationDecisionEngine`'s precedence logic
- Voice Understanding Layer, destination resolution, GTFS/transit
  journey planning, behaviour learning, onboarding
- `AudioService` (TTS) as the primary, richest feedback channel —
  the WSN layer is an **addition**, not a replacement

## 4. What Becomes Hardware/IoT

- Ultrasonic distance sensing (front / left / right) — a second,
  independent sensing modality alongside the camera, useful because
  it gives a **direct metric distance** rather than a monocular
  bounding-box heuristic, and can face directions the phone camera
  usually doesn't (e.g. worn on the chest/cane pointing forward while
  the phone is in a pocket)
- A simplified, configurable-threshold, **hardware-local** risk state
  (SAFE / WARNING / DANGER per sensor) — deliberately not a
  reimplementation of `RiskAssessmentService`'s 7-factor model
- Directional haptic output (LEFT / RIGHT / BOTH=STOP)
- A physical SOS button, wired to a design that mirrors
  `IEmergencySignalSource`'s existing contract conceptually (see §6)
- The node→controller message structure that a real distributed WSN
  build would use (see §5)

## 5. Communication Responsibilities

**Superseded by `docs/WSN_STAGE2_DESIGN.md`** — that document is now
the canonical, audit-reviewed message format and topology design;
the table below is kept for historical context on the original
reasoning but two decisions have since changed: (1) `riskLevel` is
dropped from the wire format (classification stays centralised at the
hub, not duplicated per node — see `WSN_STAGE2_DESIGN.md` §3), and
(2) a `sequenceNumber` field was added (enables packet-loss
measurement, which this original design lacked). The Stage 1 firmware
(`wokwi/main.ino`) also now distinguishes a fourth risk value,
`SENSOR_FAULT`, from `SAFE` — a non-responding sensor must not be
indistinguishable from a genuinely clear path.

Original proposed message shape per sensor reading (fields chosen to
match what a risk/decision layer actually needs, and what
`DetectedHazard`/`EmergencyTriggerSignal` already carry on the
software side, so the two vocabularies stay compatible):

| Field | Type | Notes |
|---|---|---|
| `nodeId` | string | e.g. `NODE_FRONT`, `NODE_LEFT`, `NODE_RIGHT`, `NODE_SOS` |
| `sensorType` | string | e.g. `ULTRASONIC`, `BUTTON` |
| `distanceCm` | float, nullable | null for the SOS node |
| `riskLevel` | enum | *(superseded — see note above; kept centralised at the hub instead)* |
| `direction` | enum | `LEFT` \| `CENTER` \| `RIGHT` \| `NONE` |
| `timestampMs` | uint32 | `millis()` since node boot (no RTC/NTP in prototype) — node-local, never compared numerically across nodes |

This workspace's terminology: **Stage 1** is the current,
single-controller, fully-wired prototype (this document, this
simulation) — correctly described as embedded/IoT sensing, **not** a
WSN (see README.md §5 for the terminology distinction). **Stage 2**
is the future, not-yet-built wireless extension — one genuinely
spatially-separated node (not three; see §9 below and
`docs/WSN_STAGE2_DESIGN.md`) talking ESP‑NOW to this same hub. In the
**Wokwi simulation (Stage 1)**, all three ultrasonic sensors are wired
directly to one ESP32 (see §9 for why, and `SIMULATION_LIMITATIONS.md`
for the precise Wokwi constraint that would prevent simulating
wireless nodes even if Stage 2 were built today), but the firmware
still constructs and logs a message struct per sensor per cycle over
Serial — so the message format's *shape* and the decision logic that
consumes it are exercised, even though no wireless transport exists
yet in simulation or physically.

## 6. Proposed Data Flow

```
Sensor Node(s): front / left / right ultrasonic + SOS button
        │  (wired in Wokwi prototype; ESP-NOW/Wi-Fi in the physical build)
        ▼
Central ESP32 controller
        │  - per-sensor SAFE/WARNING/DANGER classification
        │  - fixed-precedence decision: DANGER-front > both-sides-risk >
        │    single-side risk > clear (mirrors NavigationDecisionEngine's
        │    "discrete decision, not a weighted blend" philosophy, at a
        │    much smaller scale)
        ▼
Haptic actuation: LEFT motor / RIGHT motor / BOTH (=STOP) + buzzer on DANGER
        │
        ▼
User (wearable)
```

SOS is a parallel path: button press → SOS event constructed and
logged over Serial (the message the physical build would forward to
the phone app) → distinct alternating haptic/buzzer pattern. This
hardware layer does **not** call `EmergencyService` directly — that
would require an actual phone-side Bluetooth/Wi-Fi bridge, which is
explicitly not built in this milestone (see §8, Open Questions). The
architecturally honest claim is: *this prototype demonstrates the
event a real bridge would carry, not the bridge itself.*

## 7. Assumptions

- The wearable device is a **second, purpose-built unit**, separate
  from the phone — it does not attempt to replace the phone's camera,
  GPS, or voice interface.
- Ultrasonic sensing is a **complement** to the camera pipeline, not a
  replacement — it covers a different failure mode (monocular
  distance heuristics can be wrong; a direct time-of-flight reading
  from a fixed mount is a different, useful signal).
- The hardware-local SAFE/WARNING/DANGER thresholds are placeholders
  for a student prototype and are not derived from any accessibility
  research or user testing — they are configurable constants
  specifically so they can be recalibrated later.
- No physical device has been purchased or tested at the time of
  writing. Every claim about behaviour is either "simulated in
  Wokwi" or "traced by reading the firmware," never "measured."

## 8. Open Questions

- **Phone ↔ wearable bridge**: how (or whether) the ESP32's SOS/hazard
  events should ever reach `EmergencyService`/`IEmergencySignalSource`
  on the phone (Bluetooth Classic/BLE GATT? Wi-Fi direct? Not at all,
  and the wearable stays a fully standalone safety layer?). Not
  designed or built here — flagged for a later milestone/discussion
  with the dissertation guide.
- Whether the final physical build should stay single-ESP32 (Stage 1
  only) or add the one recommended wireless node (Stage 2, see §9 and
  `docs/WSN_STAGE2_DESIGN.md`) — the audit recommends Stage 2's
  minimal one-node version over both "stay wired forever" and the
  originally-proposed 2–3-node version, but this remains a scope
  decision for the guide, not something decided unilaterally here.
- Exact mounting location(s) on the user's body/cane and resulting
  sensor cone coverage — deferred to `PHYSICAL_PLACEMENT.md`, and
  ultimately requires physical iteration.
- Whether three ultrasonic sensors (front/left/right) are sufficient
  coverage, or whether a wider-beam/rotating arrangement is needed —
  cannot be answered from simulation; needs physical testing.

## 9. Controller/Topology Choice Summary (detail in other docs)

- Controller: **ESP32** (see BOM/README for the full Arduino Uno vs
  ESP32 comparison and reasoning).
- Topology for the **Wokwi prototype**: one ESP32 + three wired
  HC‑SR04 sensors, because Wokwi does not support simulating wireless
  ESP‑NOW/Wi‑Fi communication between two independently-running
  microcontrollers in a single project (confirmed against Wokwi's own
  docs and an open, unresolved Wokwi feature request — see
  `SIMULATION_LIMITATIONS.md`). Only one MCU can execute per Wokwi
  project today.
- Topology for the **physical Stage 2 extension**: **one** genuinely
  spatially-separated wireless node (e.g. cane-tip mounted) over
  ESP‑NOW to the same chest-hub ESP32 — **not** 2–3 independent
  wireless nodes. A 2–3-node topology was never actually justified
  against the physical placement already designed: three sensors
  ~20–30cm apart on one harness don't need wireless at all, so making
  all of them wireless would add cost, battery count, and failure
  modes for no research benefit. See `docs/WSN_STAGE2_DESIGN.md` for
  the full design. The firmware's message struct and decision logic
  were written so this one-node split is a straightforward follow-on
  change, not a rewrite (see `main.ino` comments).

## 10. Components That Need Physical Validation

Everything in this workspace is simulated or traced, not measured.
In particular, physical validation is required for:

- Real-world HC‑SR04 accuracy/noise on skin-toned clothing, dark
  surfaces, angled surfaces, rain/outdoor use (ultrasonic sensors are
  known to behave poorly on soft/absorptive or steeply angled
  surfaces — Wokwi's simulated sensor has none of these failure modes)
- Actual vibration motor intensity, distinguishability of LEFT vs
  RIGHT vs STOP by touch, and mounting comfort (Wokwi represents these
  as LEDs — see `SIMULATION_LIMITATIONS.md`)
- Battery life / power draw of 3 continuously-polled HC‑SR04 sensors
  under realistic walking use
- End-to-end wireless latency and packet loss for the physical
  multi-node ESP‑NOW build (impossible to measure in Wokwi)
- Enclosure, weight, wiring durability, and safety on a worn device
  (see `PHYSICAL_PLACEMENT.md`)
