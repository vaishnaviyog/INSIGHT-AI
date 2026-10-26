# Simulation Limitations

Status: this document is the single source of truth for what the
Wokwi prototype **does not** prove. Every other document in this
workspace links back here rather than re-stating these limits, so
read this before treating any simulated result as validated hardware
behaviour.

## 1. No wireless WSN simulation (the biggest limitation)

**Claim checked against Wokwi's own documentation and an open Wokwi
feature request before writing any firmware.** As of this writing:

- Wokwi has no ESP‑NOW simulation. A public feature request for
  "ESP-NOW and Multi-Microcontroller Support in Single Project"
  (wokwi/wokwi-features issue #1015) is open and unresolved.
- Only **one microcontroller executes at a time** per Wokwi project,
  even when a `diagram.json`/`wokwi.toml` defines more than one chip.

**Consequence for this prototype**: what's built here is **Stage 1**
only — three ultrasonic sensors wired directly to one ESP32, not
independently-radioed nodes. This is correctly described as an
**embedded/IoT sensing prototype, not a WSN** — calling it a WSN
because it has multiple sensors would be a category error.
The firmware still builds and logs a message struct
(`NODE_FRONT`/`NODE_LEFT`/`NODE_RIGHT`, see `main.ino`) shaped like
what a real Stage 2 wireless node would transmit, so the **message
format and the decision logic that consumes it** are exercised — the
**wireless transport itself does not exist yet, in simulation or
otherwise**. `docs/WSN_STAGE2_DESIGN.md` defines the one genuinely
spatially-separated wireless node (not three) planned to make the WSN
claim actually true, once built physically — Wokwi cannot simulate
that link either way, for the reasons above.

## 2. No physical vibration motors

Wokwi's part catalog does not include a vibration-motor part (checked
against Wokwi's parts documentation and search; only a *vibration
sensor* — an input component, the opposite of what's needed — exists,
and that is unrelated). `LEFT_HAPTIC_LED_PIN` and
`RIGHT_HAPTIC_LED_PIN` in `main.ino` are **virtual representations of
haptic output — requires physical validation.** Specifically unproven
by simulation:

- Whether a real motor at the chosen GPIO drive level is strong
  enough to feel through clothing
- Whether LEFT vs RIGHT vs STOP (both) are actually distinguishable by
  touch, at whatever body location they end up mounted
- Motor driver circuitry (MOSFET + flyback diode, fully specified in
  `docs/CIRCUIT_CONNECTIONS.md` §3) is not simulated at all — the
  Wokwi LEDs continue to be driven directly from the GPIO, which is
  safe for an LED but would NOT be safe for a real motor's back-EMF.
  The driver design exists on paper (BOM-costed and schematically
  described) but has never been built or tested.
- PWM-based intensity control is not implemented in the current
  firmware (simple digital HIGH/LOW) — real motors typically want PWM
  for comfort tuning, and that is unvalidated design work, not just
  unvalidated simulation

## 3. HC‑SR04 is simulated as an ideal sensor

Wokwi's HC‑SR04 model returns a clean, exact distance controlled by a
manual slider (2–400 cm) or a scripted value. It does not simulate:

- Signal loss/absorption on soft, dark, or steeply-angled real
  surfaces (a well-known real-world HC‑SR04 weakness)
- Acoustic cross-talk between the three close-mounted sensors
  (~20–30cm apart on one harness). The firmware triggers them strictly
  sequentially, never simultaneously, and now adds a
  `SENSOR_SETTLE_DELAY_MS` (15ms) gap between one sensor's echo ending
  and the next one's trigger firing, specifically as a precaution
  against residual acoustic reverberation — but **Wokwi has no
  acoustic model at all**, so neither the original risk nor this
  firmware-side mitigation can be confirmed or refuted in simulation.
  This remains a physical-testing requirement.
- Outdoor conditions: wind, rain, ambient noise, temperature effects
  on the speed of sound
- Real mounting-angle drift over time (straps shifting during walking)
- Beam-angle coverage gaps between the three fixed sensor cones

## 4. The ECHO voltage divider is drawn but not electrically validated

`wokwi/diagram.json` now includes the 2.2kΩ/3.3kΩ divider on every
ECHO line (see `docs/CIRCUIT_CONNECTIONS.md` §2 and
`docs/POWER_ARCHITECTURE.md` §2 for the calculation). **This addition
is a wiring-diagram/documentation aid, not electrical proof.** Wokwi
simulates digital pins as boolean HIGH/LOW, not as analog voltages —
it cannot confirm the divider actually produces ~3.0V at the GPIO, and
it would not have flagged the original unprotected 5V-to-3.3V
connection as unsafe either. A multimeter reading on physical hardware
is the only way to confirm this circuit behaves as calculated.

## 5. Sensor-fault handling is logic-only, not a real fault-detection capability

The firmware distinguishes `SENSOR_FAULT` (no echo received) from
`SAFE` (see `main.ino`'s `classify()`). This is exercised in simulation
by disconnecting/hiding a sensor's ECHO wire in the diagram, which is a
reasonable proxy for "no echo," but does not cover every real failure
mode (e.g. a sensor that returns a plausible but wrong reading due to
physical damage would not be caught by this mechanism at all, in
simulation or physically) — this does not make the system fail-safe.

## 6. Hysteresis/temporal confirmation remains deliberately unimplemented

A single noisy HC‑SR04 reading still flips the reported state
immediately — no confirmation-over-N-readings filter was added,
deliberately, to avoid over-engineering a MINOR finding before
physical testing. Wokwi's slider makes this easy to demonstrate (rapid
slider movement across a threshold produces rapid state changes) but
cannot show whether *real* HC‑SR04 noise is frequent/severe enough to
make this matter physically — that determination is deferred to
physical testing.

## 7. No real-world timing/latency validation

`pulseIn()` (used for HC‑SR04 reads) is genuinely blocking on real
hardware for the duration of the echo wait — up to
`ULTRASONIC_TIMEOUT_US` (25 ms) per sensor, ×3 sensors, every cycle.
Wokwi's simulated clock and CPU model do not necessarily reflect real
ESP32 timing behaviour or real-device jitter under Wi‑Fi/ESP‑NOW radio
load (which does not even run in this prototype). Any latency figures
that eventually matter for the dissertation (see "Metrics" in
`README.md`) must be measured on physical hardware, not inferred from
the simulator.

## 8. No power/battery simulation

Wokwi provides virtual USB power with no meaningful current-draw
model. Battery life, the boost converter's real behaviour, voltage sag
under 3× simultaneous sensor reads, and brown-out behaviour are
entirely unvalidated by this simulation — see
`docs/POWER_ARCHITECTURE.md` §6.

## 9. Test results: partially executed (pin-state), Serial text still unread

**Update (2026-09-27): 8 of the test scenarios have now been
genuinely executed**, not just traced — see
`docs/PRE_HARDWARE_VALIDATION_REPORT.md` and `wokwi/test_scenario.yaml`.
`wokwi-cli`'s Serial Monitor **text** output could not be captured on
this machine, across multiple independent attempts (two ESP32 core
versions, plain and merged firmware images, an active license, even a
trivial unrelated test sketch) — that specific limitation is real and
unresolved. But `wokwi-cli --scenario` can directly assert a GPIO
pin's digital value against the running simulation, independent of
Serial entirely, and that path works reliably. Using it, the LEFT/
RIGHT haptic LED pins (D25/D26) were verified against 8 scenarios
(clear, left, right, frontal STOP, both-sides STOP, sensor fault,
recovery, SOS) with all 8 assertions passing.

**What this does and does not close out**: this confirms the
*haptic decision logic* end-to-end — genuinely executed, not
predicted. It does **not** confirm the exact Serial log text (`MSG`/
`DECISION`/`FAULT`/`EVENT` line wording), the buzzer's actual state,
or the status LED's blink *rate* (only D25/D26 were asserted) — those
remain traced-only (`tests/SCENARIO_TRACE.md`) or manually-observed
(the status LED blink was visually confirmed by the user in VS Code,
but not asserted programmatically). `docs/DISSERTATION1_TEST_PLAN.md`
marks each row precisely by which of these two evidence levels it has.

## 10. What this simulation DOES validate honestly

To be fair to the prototype and not only list failures:

- The **firmware compiles against real pin/peripheral semantics**
  (HC‑SR04 trigger/echo timing, GPIO direction, `INPUT_PULLUP` button
  debounce logic) — these are the same APIs and timing constraints a
  real ESP32 would use.
- The **decision logic's precedence order** (front-DANGER always wins,
  both-sides-WARNING escalates to STOP, single-side WARNING drives the
  correct LEFT/RIGHT output, SOS overrides everything) is exercised
  exactly as written, because Wokwi's HC‑SR04 slider lets each
  scenario's inputs be set precisely — and, as of §9, this is now
  **automated and asserted against real simulated GPIO state**
  (`wokwi/test_scenario.yaml`), not just manually observed once.
- The **message format** each "node" constructs is real code, not a
  mock — it is the literal struct/serialization a physically split
  node would reuse.
- Wiring correctness (every signal actually reaches a real GPIO,
  nothing is a fictitious connection) is enforced by Wokwi refusing to
  simulate a malformed circuit.
- The **sensor-fault path** (a disconnected/no-echo sensor correctly
  producing `SENSOR_FAULT`, excluded from directional decisions, and
  distinctly logged/status-LED-indicated, rather than silently read as
  SAFE) is exercisable and observable in simulation by hiding an ECHO
  connection — this is a genuine logic validation, even though it
  doesn't cover every physical failure mode (§5 above).
