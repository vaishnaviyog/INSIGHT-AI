# Scenario Trace (Manually Traced From Firmware Logic — NOT an Executed Simulation Run)

Status: this file was produced by reading `wokwi/main.ino` line by
line and working out what it would print/do for each demonstration
scenario (sequence numbers, the `SENSOR_FAULT` risk level, and the
`fault=` field on each `DECISION` line). **It is not console output
captured from an actual Wokwi run** — real executed results now exist
in `docs/PRE_HARDWARE_VALIDATION_REPORT.md` and
`docs/DISSERTATION1_TEST_PLAN.md`; this file is kept only as the
original narrative walkthrough of *why* each scenario behaves as it
does.
No Wokwi CLI token/account was available in this environment to
execute the simulation and capture real output. This is a code trace,
explicitly labelled as such per `docs/SIMULATION_LIMITATIONS.md` §9.

To get real, executed results: open `wokwi/` in the Wokwi VS Code
extension or at wokwi.com, run it, set each HC‑SR04's distance slider
per the scenario below, and paste the real Serial Monitor output into
`docs/DISSERTATION1_TEST_PLAN.md`'s "Observed output" column.

---

## Scenario 1 — Clear Path

**Setup**: front = 200 cm, left = 200 cm, right = 200 cm (all > `SAFE_DISTANCE_CM`)

Traced classify() results: all three → `RiskLevel::SAFE`.

Traced decision branch: none of the `if` conditions match until the
final `else` → `SystemState::CLEAR`.

Predicted output per cycle (seq increments by 1 each cycle; shown as
`<S>` since the exact starting value depends on how many cycles have
already run since boot):
```
MSG node=NODE_FRONT type=ULTRASONIC distance_cm=200.0 risk=SAFE direction=CENTER seq=<S> t_ms=<N>
MSG node=NODE_LEFT type=ULTRASONIC distance_cm=200.0 risk=SAFE direction=LEFT seq=<S> t_ms=<N>
MSG node=NODE_RIGHT type=ULTRASONIC distance_cm=200.0 risk=SAFE direction=RIGHT seq=<S> t_ms=<N>
DECISION state=CLEAR reason="no sensor within warning/danger range" fault=false
```
Predicted actuation: both haptic LEDs OFF, buzzer OFF. Matches the
required "no emergency vibration, no warning" outcome.

---

## Scenario 2 — Obstacle on Left

**Setup**: front = 200 cm, left = 40 cm (between 25 and 50 → WARNING), right = 200 cm

Traced: `leftRisk = WARNING`, others `SAFE`. `frontRisk != DANGER`;
`leftRisk == WARNING && rightRisk == WARNING` is false (right is
SAFE); `leftRisk == WARNING` branch matches.

Predicted output:
```
MSG node=NODE_LEFT type=ULTRASONIC distance_cm=40.0 risk=WARNING direction=LEFT seq=<S> t_ms=<N>
...
DECISION state=LEFT reason="left sensor WARNING" fault=false
```
Predicted actuation: LEFT LED ON, RIGHT LED OFF, buzzer OFF.

---

## Scenario 3 — Obstacle on Right

**Setup**: front = 200 cm, left = 200 cm, right = 40 cm

Traced: symmetric to Scenario 2. `rightRisk == WARNING` branch matches
(left-side branch is checked first in the code but does not match
since left is SAFE).

Predicted output:
```
DECISION state=RIGHT reason="right sensor WARNING" fault=false
```
Predicted actuation: RIGHT LED ON, LEFT LED OFF, buzzer OFF.

---

## Scenario 4 — High-Risk / Immediate Stop

**Setup A** (frontal danger): front = 15 cm (≤ `DANGER_DISTANCE_CM`), left/right = 200 cm

Traced: `frontRisk == DANGER` — this is the **first** condition
checked after SOS, so it wins regardless of left/right state (matches
the architecture note that a frontal immediate-danger reading always
takes precedence, mirroring `NavigationDecisionEngine`'s "immediate
danger always interrupts" philosophy at a smaller scale).

Predicted output:
```
DECISION state=STOP reason="front sensor DANGER (immediate obstacle ahead)" fault=false
```
Predicted actuation: both LEDs ON, buzzer ON (continuous while the
condition persists).

**Setup B** (both-sides warning, alternate path to STOP): front = 200
cm, left = 45 cm, right = 45 cm

Traced: `frontRisk` is SAFE, but `leftRisk == WARNING && rightRisk ==
WARNING` both true → STOP branch via the "narrow passage" reason.

Predicted output:
```
DECISION state=STOP reason="both sides in WARNING range (narrow passage / closing on both sides)" fault=false
```

---

## Scenario 5 — SOS

**Setup**: press `btn_sos` once (any obstacle state).

Traced `pollSosButton()`: on the debounced falling edge (`raw ==
LOW`), `sosActive` becomes `true`, `sosStartedAtMs = now`, and one
`MSG node=NODE_SOS ...` plus one `EVENT sos_triggered ...` line is
printed exactly once (not repeated every cycle, since it's inside the
edge-detected `if`).

Predicted output (once, at the moment of press). Note `seq=0` here:
the SOS message is constructed with a hardcoded `0`, not the shared
`cycleSequenceNumber` used by the three ultrasonic MSG lines — it is
an asynchronous, edge-triggered event, not part of a numbered sensing
cycle.
```
MSG node=NODE_SOS type=BUTTON distance_cm=NA risk=DANGER direction=NONE seq=0 t_ms=<N>
EVENT sos_triggered — this is the event a physical build would forward to the companion phone app / EmergencyService. No SMS/call is sent from this prototype.
```

Traced `loop()`: while `sosActive` is true, `actuate()` is always
called with `SystemState::SOS` regardless of `currentState`, producing
an alternating LEFT/RIGHT/buzzer pulse every ~200ms (traced from the
`lastPatternToggleMs` toggle logic) — a pattern deliberately distinct
from STOP's steady-on output.

After `SOS_HOLD_MS` (5000ms) elapses, traced `pollSosButton()`'s second
`if` block sets `sosActive = false` and prints:
```
EVENT sos_hold_elapsed — prototype SOS display ends, resuming obstacle detection.
```
Normal obstacle-driven `currentState` actuation resumes on the next
`actuate()` call.

**Honesty note**: no SMS is sent, no call is placed, and no network
request is made anywhere in this firmware. The two `EVENT` lines above
are exactly what is claimed — a demonstration of the event a real
bridge to `EmergencyService`/`IEmergencySignalSource` would carry — not
a working emergency-contact system. See
`docs/DISSERTATION1_ARCHITECTURE_ANALYSIS.md` §8 (Open Questions) for
why that bridge is not built here.

---

## Scenario 6 — Sensor Fault (audit fix, new)

**Setup**: front ECHO disconnected/hidden in the diagram (or set such
that no echo returns within `ULTRASONIC_TIMEOUT_US`); left = 200cm,
right = 200cm.

Traced `readDistanceCm()`: `pulseIn(..., ULTRASONIC_TIMEOUT_US)`
returns 0 (no echo within 25ms) → function returns `NAN`.

Traced `classify(NAN)`: `isnan(distanceCm)` is true →
`RiskLevel::SENSOR_FAULT` (this is the audit fix — previously this
branch returned `RiskLevel::SAFE`).

Traced `loop()`: `frontRisk == RiskLevel::SENSOR_FAULT`, so
`faultActive` becomes `true` and a `FAULT node=NODE_FRONT ...` line is
printed. In the decision chain, `frontRisk == RiskLevel::DANGER` is
false (SENSOR_FAULT is a distinct enum value from DANGER), so the
front sensor's fault does **not** trigger STOP by itself — the
decision falls through to whatever the (valid) left/right readings
justify, which here is `CLEAR`.

Predicted output:
```
MSG node=NODE_FRONT type=ULTRASONIC distance_cm=NA risk=SENSOR_FAULT direction=CENTER seq=<S> t_ms=<N>
MSG node=NODE_LEFT type=ULTRASONIC distance_cm=200.0 risk=SAFE direction=LEFT seq=<S> t_ms=<N>
MSG node=NODE_RIGHT type=ULTRASONIC distance_cm=200.0 risk=SAFE direction=RIGHT seq=<S> t_ms=<N>
FAULT node=NODE_FRONT reason=no_echo_within_timeout
DECISION state=CLEAR reason="no sensor within warning/danger range" fault=true
```

Predicted actuation: haptic LEDs and buzzer follow the `CLEAR` state
(both OFF) exactly as a genuinely clear path would look — **this is
the specific, audit-flagged risk that a faulted front sensor is
haptically silent, same as a real clear path.** What is now different
from before the fix: the status LED switches to the fast
`FAULT_BLINK_MS` (80ms) blink instead of its normal 1000ms idle
heartbeat, and the Serial log clearly states `risk=SENSOR_FAULT` /
`FAULT node=NODE_FRONT` / `fault=true` — so a reviewer watching the
status LED or the Serial Monitor can tell this apart from a genuine
CLEAR, even though the haptic output itself cannot — and intentionally
does not try to: a fault is not treated as an obstacle, deliberately
not conflating the two without a clear reason.
