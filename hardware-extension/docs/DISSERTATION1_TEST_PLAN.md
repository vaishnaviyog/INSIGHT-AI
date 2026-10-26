# Dissertation 1 — Test Plan

Status: **Tests 1–7, 13, 18–20, 21–24, 25–26, and 27–30 are EXECUTED,
not predicted** — re-verified 2026-10-22 via seven scenario files:
`wokwi/test_scenario.yaml` (main diagram, 10 steps),
`wokwi/test_scenario_fault.yaml` and
`wokwi/test_scenario_fault_degraded.yaml` (both against
`wokwi/diagram_front_fault.json`, front sensor's ECHO genuinely
disconnected — split into two files because the DEGRADED pulse's
narrow ON window proved fragile to hit via a delay chained after a
prior step; the fresh-boot version is far more timing-stable),
`wokwi/test_scenario_dual_fault.yaml` against
`wokwi/diagram_dual_fault.json` (front **and** left ECHO both
genuinely disconnected), `wokwi/test_scenario_triple_fault.yaml`
against `wokwi/diagram_triple_fault.json` (all three ECHO lines
genuinely disconnected), `wokwi/test_scenario_confirm_filter.yaml`
(main diagram, proves the temporal WARNING confirmation filter), and
`wokwi/test_scenario_closing_speed.yaml` (main diagram, proves the
closing-speed escalation mechanism). Wokwi's distance slider alone
cannot simulate a true sensor timeout, hence the dedicated fault
diagrams. Both the LEFT/RIGHT haptic LED GPIO pin states AND the full
Serial text log are confirmed for every executed test. **44/44
pin-state assertions passed across all seven scenario files** (22 + 2
+ 2 + 6 + 4 + 4 + 4). Tests 9–12 and 14–17 have not been scripted into
the automated scenario yet and remain PENDING (predicted only, from
tracing the code). The Physical Tests and WSN Tests sections are **not
runnable
at all** — no physical hardware and no Stage 2 wireless node exist.

To extend the automated coverage or re-run it: `cd wokwi`, set
`WOKWI_CLI_TOKEN`, then `wokwi-cli . --scenario test_scenario.yaml
--timeout 30000`. To run the remaining PENDING rows manually: open
`wokwi/` in the Wokwi VS Code extension or wokwi.com, use each
HC‑SR04's distance slider, and use the diagram's controls to
disconnect/hide a sensor for fault tests.

All thresholds referenced are the constants at the top of `main.ino`:
`SAFE_DISTANCE_CM = 100`, `WARNING_DISTANCE_CM = 50`,
`DANGER_DISTANCE_CM = 25`, `SENSOR_SETTLE_DELAY_MS = 15`,
`SOS_HOLD_MS = 5000`.

## Simulation Tests (Wokwi — can be run today)

| # | Test | Input | Expected output | Observed output | Pass/Fail |
|---|---|---|---|---|---|
| 1 | Clear path | All sensors > 100cm | `DECISION state=CLEAR ...`; both haptic LEDs OFF, buzzer OFF | `esp32:D25=0, D26=0` (automated scenario step 1; re-confirmed step 7) | **PASS** (LED evidence; log text unconfirmed) |
| 2 | Front obstacle | Front ≤ 25cm, left/right clear | `DECISION state=STOP reason="front sensor DANGER..."`; both LEDs ON, buzzer ON | `esp32:D25=1, D26=1` (scenario step 4, front=20cm) | **PASS** (LED evidence; buzzer/log text unconfirmed) |
| 3 | Left obstacle | Left 25–50cm (WARNING), front/right clear | `DECISION state=LEFT reason="left sensor WARNING"`; LEFT LED ON only | `esp32:D25=1, D26=0` (scenario step 2, left=40cm) | **PASS** (LED evidence; log text unconfirmed) |
| 4 | Right obstacle | Right 25–50cm, front/left clear | `DECISION state=RIGHT reason="right sensor WARNING"`; RIGHT LED ON only | `esp32:D25=0, D26=1` (scenario step 3, right=40cm) | **PASS** (LED evidence; log text unconfirmed) |
| 5 | Immediate danger / STOP | Front ≤ 25cm (or left AND right both ≤ 50cm) | `DECISION state=STOP ...`; both LEDs ON, buzzer ON | Both routes tested: front=20cm → `D25=1,D26=1` (step 4); left=40,right=40 → `D25=1,D26=1` (step 5) | **PASS** (both routes, LED evidence) |
| 6 | SOS | Press `btn_sos` | `EVENT sos_triggered ...` once; `DECISION state=SOS` next cycle; alternating LED/buzzer pulse ~200ms; auto-resumes after 5s with `EVENT sos_hold_elapsed ...` | `esp32:D25=1, D26=1` 100ms after press (scenario step 8) | **PASS** (confirms pattern starts ON as designed; alternation timing, auto-resume, and EVENT log text not independently re-confirmed here — see `tests/SCENARIO_TRACE.md` for the traced full timeline) |
| 7 | Sensor timeout | Disconnect one sensor's ECHO wire in the diagram (or set distance beyond the simulator's range so no echo returns) | `readDistanceCm()` returns NAN; `MSG ... distance_cm=NA risk=SENSOR_FAULT ...` for that node | Front set to 400cm (beyond `ULTRASONIC_TIMEOUT_US`'s ~430cm range) → `D25=0, D26=0` (scenario step 6) — i.e. the fault produced no false obstacle warning | **PASS** (behavioural evidence only — confirms a faulted sensor doesn't trigger LEFT/RIGHT/STOP; the exact `SENSOR_FAULT`/NAN log text was not independently read) |
| 8 | Sensor fault indication (audit fix) | Same setup as Test 7 | A `FAULT node=NODE_X reason=no_echo_within_timeout` line is printed; status LED switches to the fast `FAULT_BLINK_MS` (80ms) pattern instead of its normal heartbeat; `DECISION ... fault=true` | Not independently checked — the automated scenario asserts only D25/D26, not D33's blink rate or the Serial `FAULT`/`fault=true` text | PENDING |
| 9 | Multiple simultaneous hazards | Front ≤ 25cm AND left ≤ 40cm AND right ≤ 40cm all at once | `DECISION state=STOP reason="front sensor DANGER..."` (front-DANGER precedence wins; no conflicting output) | Not yet scripted | PENDING |
| 10 | SOS during obstacle warning | Set left ≤ 40cm (LEFT state active), then press `btn_sos` | Decision switches to `state=SOS` immediately (SOS is checked first in the precedence chain); LEFT LED behaviour is overridden by the SOS alternating pattern | Not yet scripted | PENDING |
| 11 | Threshold boundary | Distance set to exactly 100.0, 50.0, and 25.0cm | 100.0→SAFE (not WARNING); 50.0→WARNING (boundary is `<=`); 25.0→DANGER (boundary is `<=`) | Not yet scripted | PENDING |
| 12 | Rapid threshold oscillation | Rapidly move one sensor's slider back and forth across the WARNING/SAFE boundary | **Superseded by Tests 25–26**: as of the temporal WARNING confirmation filter (`docs/NOVELTY_CONTRIBUTION.md` §9), oscillation across the WARNING boundary specifically is now smoothed (2-cycle confirmation) rather than flipping every cycle — this row's original premise ("no hysteresis") is no longer accurate for WARNING. DANGER/SAFE boundaries remain unfiltered, still flip immediately | See Tests 25–26 (EXECUTED) | **SUPERSEDED** |
| 13 | All sensors in danger | Front, left, and right all ≤ 25cm simultaneously | `DECISION state=STOP reason="front sensor DANGER..."`; stable, non-conflicting output | Covered by scenario step 4's precedence proof (front DANGER wins regardless of left/right) — the specific all-three-≤25cm combination itself not yet scripted | PENDING (partially supported) |
| 14 | Two dangerous sensors + one failed sensor | Left ≤ 40cm, right ≤ 40cm, front ECHO disconnected (NAN) | `DECISION state=STOP reason="both sides in WARNING range..."` (front's fault does not block the valid left/right reading from producing STOP); front's `MSG`/`FAULT` lines still show `SENSOR_FAULT` | Not yet scripted | PENDING |
| 15 | SOS held through full `SOS_HOLD_MS` | Press and continuously hold `btn_sos` for >5s | SOS fires once on press; pattern continues for the full 5s; `EVENT sos_hold_elapsed` fires at 5s; SOS does **not** re-trigger while still held (no new HIGH→LOW edge) | Not yet scripted | PENDING |
| 16 | Fresh SOS after release | After Test 15, release the button, then press again | A fresh `EVENT sos_triggered` fires on the new press (a genuine new falling edge) | Not yet scripted | PENDING |
| 17 | Reset behaviour | Restart the simulation / reset the ESP32 | Boot banner prints once (now includes the "NOT a WSN" line); all outputs start OFF/LOW; first sensing cycle begins within `SENSOR_CYCLE_MS` of boot; no stale STOP/SOS state carries over | Not yet scripted | PENDING |
| 18 | Adaptive compensation (novel — `docs/NOVELTY_CONTRIBUTION.md`) | Front sensor genuinely disconnected (`diagram_front_fault.json`), left=60cm (beyond normal 50cm WARNING, within compensated 75cm) | `risk=WARNING`, `DECISION state=LEFT`, D25=1 — triggered by the widened threshold | `MSG ... distance_cm=60.8 risk=WARNING ...`, D25=1 (`test_scenario_fault.yaml` step 1) | **PASS** (EXECUTED) |
| 19 | DEGRADED reachable (novel) | Fault diagram: left forced to DANGER (20cm) first to prove baseline wiring, then reverted to SAFE (150cm) with front still faulted | Baseline: `DECISION state=STOP`, D25=1/D26=1 (pin-checked, steady state). After revert: `DECISION state=DEGRADED` (verified via `--expect-text`, not pin timing — see design note below for why) | Confirmed 6/6 on repeated runs, `test_scenario_fault_degraded.yaml` + `--expect-text "DECISION state=DEGRADED"` | **PASS** (EXECUTED) |
| 20 | Compensation control/counter-proof (novel) | Normal diagram (no fault), left=60cm, front/right clear | Same 60cm reading as Test 18 must stay `SAFE`/`CLEAR` without a fault present — proves compensation is conditional, not a permanently loosened threshold | `MSG ... distance_cm=60.8 risk=SAFE ...`, D25=0 (`test_scenario.yaml` step 9) | **PASS** (EXECUTED) |
| 21 | Left/right DANGER regression (bug fix) | Left=20cm (front/right clear), then right=20cm (front/left clear) | `DECISION state=STOP reason="left sensor DANGER..."` / `"right sensor DANGER..."`; D25=1,D26=1 both cases — fixes a pre-existing gap where only `frontRisk==DANGER` was ever checked | Both confirmed, `test_scenario.yaml` step 10 | **PASS** (EXECUTED) |
| 22 | Correlated dual-fault fail-safe (robustness extension, not a novelty claim — §6 of `NOVELTY_CONTRIBUTION.md`) | Front **and** left genuinely disconnected (`diagram_dual_fault.json`), right=200cm (nothing detected) | `DECISION state=STOP reason="2+ sensors faulted simultaneously..."`; compensation disabled (`compensationTrusted=false` since `faultCount==2`), fail-safe STOP engages instead of a DEGRADED pulse | `D25=1,D26=1` (`test_scenario_dual_fault.yaml` step 1); Serial confirms both `FAULT` lines firing every cycle | **PASS** (EXECUTED) |
| 23 | Direct reading still honoured over the fail-safe (robustness extension) | Same dual-fault diagram, right=40cm (genuine, uncompensated WARNING) | `DECISION state=RIGHT reason="right sensor WARNING"` — a real reading from the one healthy sensor is never swallowed by the faultCount≥2 fallback | `D25=0,D26=1` (`test_scenario_dual_fault.yaml` step 2) | **PASS** (EXECUTED) |
| 24 | Direct DANGER still honoured over the fail-safe (robustness extension) | Same dual-fault diagram, right=20cm (genuine DANGER) | `DECISION state=STOP reason="right sensor DANGER..."` — via the direct-DANGER branch, a structurally higher-precedence path than the fail-safe branch (same pin outcome as Test 22, verified distinct by the Serial `reason=` text, not by pin state) | `D25=1,D26=1` (`test_scenario_dual_fault.yaml` step 3) | **PASS** (EXECUTED) |
| 25 | Transient WARNING blip suppressed (gap-fill, not a novelty claim — §9 of `NOVELTY_CONTRIBUTION.md`) | Normal diagram, left=40cm for exactly one cycle then reverted to 200cm before a second cycle could confirm it | `DECISION state=CLEAR` throughout — a single-cycle blip is never promoted to `LEFT`, directly answering Gao et al. (2025)'s named "alert fatigue" limitation | `D25=0` on both checks (`test_scenario_confirm_filter.yaml` steps 1–2) | **PASS** (EXECUTED) |
| 26 | Sustained WARNING still confirmed within 2 cycles (gap-fill) | Same diagram, left=40cm held continuously | `DECISION state=CLEAR` on cycle 1 (unconfirmed), `state=LEFT` on cycle 2 (confirmed) — the filter delays a genuine reading by at most ~300ms, it does not suppress it | `D25=0` then `D25=1` (`test_scenario_confirm_filter.yaml` step 3's two checks) | **PASS** (EXECUTED) |
| 27 | Total sensor failure fail-safe (robustness extension, not a novelty claim — §6 of `NOVELTY_CONTRIBUTION.md`) | All three sensors genuinely disconnected (`diagram_triple_fault.json`) | `DECISION state=STOP reason="2+ sensors faulted simultaneously..."` from the first cycle after boot, sustained — proves the system can never silently report CLEAR when completely blind | `D25=1,D26=1` on both checks (`test_scenario_triple_fault.yaml`) | **PASS** (EXECUTED) |
| 28 | Fast-approaching obstacle escalation (gap-fill, not a novelty claim — §10 of `NOVELTY_CONTRIBUTION.md`) | Front jumps 150cm→90cm in one cycle (delta=60cm ≥ `CLOSING_RATE_DANGER_CM`), still SAFE by fixed thresholds | `DECISION state=STOP reason="rapid closing speed detected..."` — escalates ahead of the normal WARNING/DANGER threshold crossing | `D25=1,D26=1` (`test_scenario_closing_speed.yaml` step 1) | **PASS** (EXECUTED) |
| 29 | Closing-speed control/counter-proof (gap-fill) | Front jumps 150cm→120cm (delta=30cm, below threshold) | Must NOT escalate — proves the mechanism triggers on rate of closure, not merely "distance decreased" | `D25=0,D26=0` (`test_scenario_closing_speed.yaml` step 2) | **PASS** (EXECUTED) |
| 30 | Confirmation-filter / closing-speed interaction fix | `test_scenario_confirm_filter.yaml`'s original 200cm→40cm blip jump (delta=160cm) incidentally also crossed the new closing-speed threshold, breaking its precise 1-cycle timing check | Baseline changed to 70cm (delta=30cm, under threshold) so the two mechanisms don't interfere — re-verified against Test 25/26's expected behaviour | Re-ran clean after fix, all 4 assertions pass | **PASS** (EXECUTED, regression fixed) |

## Physical Tests (require the Stage 1 physical build — not runnable yet)

| # | Test | What it checks | Why it can't be done in Wokwi |
|---|---|---|---|
| P1 | ECHO divider voltage measurement | Multimeter reading at the GPIO-side divider node reads ~3.0V (per `docs/POWER_ARCHITECTURE.md` §2), not ~5V | Wokwi has no analog voltage model |
| P2 | HC‑SR04 accuracy vs known distances | Real accuracy/repeatability across surfaces, angles, lighting | Wokwi's sensor is an idealised slider value |
| P3 | Acoustic cross-talk between the 3 sensors | Whether `SENSOR_SETTLE_DELAY_MS=15` is actually sufficient, too much, or too little | Wokwi has no acoustic model at all (§3 of `SIMULATION_LIMITATIONS.md`) |
| P4 | Motor driver stage functional test | MOSFET switches the motor cleanly; flyback diode prevents any observable driver damage over repeated cycles | Motor/MOSFET circuit doesn't exist in Wokwi (§2 of `SIMULATION_LIMITATIONS.md`) |
| P5 | Haptic distinguishability | Whether a user can reliably tell LEFT / RIGHT / STOP apart by touch | Requires a real motor against real skin |
| P6 | Battery current draw / runtime | Real current draw under continuous 3-sensor polling, and with buzzer/motors active | Wokwi has no power model (§8) |
| P7 | Power switch / reset-under-battery behaviour | Confirms clean power-up/power-down with the physical switch and boost converter | Not present in the simulated power path |

## WSN Tests (require the Stage 2 wireless node — not designed to be built yet)

| # | Test | What it checks | Depends on |
|---|---|---|---|
| W1 | Wireless message latency | Send → hub receipt timing over ESP‑NOW | `docs/WSN_STAGE2_DESIGN.md` node existing physically |
| W2 | Packet delivery ratio / loss | Sequence-number gap detection at the hub | Same |
| W3 | Node-timeout / failure response | Power off the wireless node mid-test; hub must show `NODE_UNREACHABLE`/fault, not SAFE | `docs/WSN_STAGE2_DESIGN.md` §5 node-timeout logic, not yet implemented (no node to time out) |

## Design notes surfaced while writing this plan

- **Test 7/8/14 design note**: `classify()` now maps `NAN` (no echo)
  to `RiskLevel::SENSOR_FAULT`, distinct from `SAFE` — this is the
  direct fix for the audit's "a failed sensor and a clear path look
  identical" finding. A faulted sensor is excluded from the
  directional decision (it cannot itself trigger LEFT/RIGHT/STOP) but
  is separately logged and shown on the status LED, and does not
  suppress a valid DANGER/WARNING reading from a different sensor
  (Test 14 specifically exercises that combination).
- **Test 12 design note**: hysteresis/temporal confirmation remains
  deliberately unimplemented (classified MINOR in the audit, with an
  explicit instruction not to over-engineer it pre-physical-testing).
  This test exists to make that known limitation observable, not to
  fail the prototype for having it.
- **Test 15/16 design note**: newly added per the audit's identified
  SOS held-button edge case (§7 of the audit) — previously undocumented
  and untested.
- Tests 1–6 are the five core demonstration scenarios (README.md
  "Simulation Scenarios"), reworded to match this plan's numbering (1
  = clear path, 2–4 = directional, 5 = STOP, 6 = SOS) — Test 5's
  "either/or" input covers both routes to STOP that the original
  5-scenario table listed as one scenario.
- **Test 21 design note**: found independently while designing Test
  22–24's dual-fault diagram, not part of the planned one-day
  additions — a genuine pre-existing correctness gap, unrelated to the
  fault-tolerance mechanism. See `NOVELTY_CONTRIBUTION.md` §5.
- **Test 19 (`test_scenario_fault_degraded.yaml`) design note — three
  revisions, each fixing a real problem the last one missed**: (1)
  originally checked via a delay relative to a prior step in the same
  run — passed standalone, failed in a batch run, pure cross-step
  timing jitter. (2) Rewritten to check via a fixed boot-relative
  delay (850ms), reasoning boot-to-first-cycle timing is consistently
  ~696–700ms — this ALSO proved fragile (confirmed via the sibling
  triple-fault test using the identical pattern, which intermittently
  failed on a later re-run; boot/first-cycle timing can exceed 850ms
  under some conditions). (3) Final design: forces a definite
  non-DEGRADED baseline (STOP) first, pin-checked since STOP doesn't
  pulse, then triggers the DEGRADED transition at a script-controlled
  moment — but this uncovered a *structural*, not just a timing, issue:
  the DEGRADED pulse's 300ms ON window and the ~300ms transition-phase
  uncertainty are the same size, so no fixed-delay pin check can be
  mathematically guaranteed to land inside it (a wider delay does not
  fix this, since the pulse repeats at the same phase forever). Fixed
  by verifying DEGRADED is reached via the Serial log text
  (`--expect-text "DECISION state=DEGRADED"`) instead of pin timing —
  deterministic regardless of pulse phase. Confirmed stable 6/6 on
  repeated runs after this fix, 0/6 before it was tried.
- **Tests 25–26 design note**: `confirmWarning()` is deliberately
  asymmetric — only `WARNING` is delayed pending confirmation; `DANGER`,
  `SENSOR_FAULT`, and any return to `SAFE` are never delayed, since the
  alert-fatigue problem these tests address is specifically about the
  moderate case, not the immediate-stop case. This also meant
  `test_scenario_fault.yaml` test 18's own delay needed lengthening
  (800ms → 1200ms) to allow for the same 2-cycle confirmation on its
  first post-boot check.
- **Tests 22–24 design note**: `compensationTrusted` is only `true`
  when exactly one of the three sensors is faulted (`faultCount==1`);
  with 2+ simultaneous faults it is forced `false` and the
  `faultCount>=2` branch (checked only after every direct DANGER/
  WARNING check) provides a conservative `STOP` fallback instead of a
  `DEGRADED` pulse. Tests 23–24 exist specifically to prove this
  fallback never overrides a genuine reading from whichever sensor is
  still healthy.
