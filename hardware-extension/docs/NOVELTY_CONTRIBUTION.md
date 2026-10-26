# Novelty Contribution: Adaptive Fault-Tolerant Zone Reallocation

Status: SIMULATED and VERIFIED (automated pin-state tests, 44/44
assertions passed across seven scenario files — see §4, §6, §9, and §10).
**THEORETICALLY PROPOSED** as a patentable/publishable contribution —
this document is written to be useful to a dissertation panel and, if
pursued, a patent agent doing a proper prior-art search; it is not
itself a legal novelty determination, which no one without that search
can make. The honest baseline this document extends: the raw hardware
(ESP32 + HC‑SR04 + vibration motors) is not novel and this document
does not re-claim that it is. What follows is narrower and specific.

**Framing, stated plainly up front**: a 2026, 25-paper deep-research
pass ("Embedded obstacle sensing novelty 2026", kept outside this
folder alongside the dissertation's other research material) found that
the *general* concept here — a neighbour sensor compensating when
another fails, with a distinct reduced-confidence signal — is not new
in an absolute sense; fault-tolerant/redundant-sensor schemes with this
shape go back at least to Luck & Ray (1991) in the general
fault-tolerant control literature, and a broad body of aerospace/
automotive patents covers adjacent-sensor fault compensation. What is
being claimed here is narrower: a **translation** of that known
technique into the cheap/embedded assistive-wearable sub-domain, where
the reviewed 2025–2026 literature (§1) does not yet implement it, bound
to a specific sensor topology, threshold design, and dedicated haptic
state. This document does not claim invention of the general concept —
see §5 and §7 for the fuller honest accounting.

## 1. The problem, in the literature's own words

Three 2025–2026 papers architecturally close to this project's Stage 1
(ultrasonic/multi-sensor wearable obstacle detection with haptic
feedback) were reviewed for this dissertation (full citations in
`README.md` §Literature Review / the Review 2 deck). Their stated
limitations:

- **Ray & Indupuru (2026)**, dual-HC‑SR04 wearable: thresholds are
  fixed, "with no mention of adjusting to different environments or
  users"; sensor failure, cross-talk, and fault handling are not
  addressed anywhere in the paper.
- **Ikeme et al. (2025)**, ultrasonic+PIR dual-sensor aid: accuracy
  "decreasing at longer ranges"; sensor fault handling, cross-talk,
  and coverage gaps between sensors are not addressed.
- **Gao et al. (2025, *Nature Communications*)**, the strongest and
  most recent paper in the set: states outright that current
  multi-sensor assistive devices typically use **"outcome fusion,
  where the detection result is constrained by the weakest
  component,"** concluding this causes **"a lack of robustness in
  diverse scenarios."** Also documents user-survey-identified **"alert
  fatigue"** from oversensitive single-mode detection, with "refining
  detection algorithms to reduce false positives" named as future
  work — not yet solved there either.

**The gap, stated plainly**: no reviewed system actively compensates
when one of its own sensors fails. Either the failure isn't addressed
at all, or (per Gao et al.) the overall system is explicitly
acknowledged to degrade to the reliability of its single weakest part.
None give the user a way to know the difference between "fully
protected" and "silently degraded."

## 2. The mechanism

Implemented in `wokwi/main.ino` (`classifyWithCompensation()`, the
`DEGRADED` system state, and the decision/actuation logic in `loop()`/
`actuate()`):

1. **Adaptive threshold reallocation.** When a sensor reports
   `SENSOR_FAULT` (no echo), its geometric neighbour's `WARNING`
   distance threshold widens by `DEGRADED_THRESHOLD_MULTIPLIER` (1.5×:
   50cm → 75cm). Front compensates for either side failing; each side
   sensor compensates for a front failure. `DANGER` is deliberately
   **not** widened — only the earlier warning zone is — so a degraded
   sensor can prompt an earlier heads-up but never fabricate an
   immediate-stop condition on its own.
2. **A distinct "coverage reduced" signal.** When compensation is
   active and nothing is currently detected (no SOS/DANGER/WARNING
   condition fires even under the widened threshold), the system
   enters a new state, `DEGRADED`, with its own haptic signature — a
   slow synchronized double-pulse (300ms on, 1000ms period), reset to
   start immediately on entry — clearly distinct from STOP's
   continuous signal and SOS's fast ~200ms alternation, and
   deliberately gentler (no buzzer) since it is a heads-up, not an
   alarm.

This directly answers Gao et al.'s named problem: instead of overall
reliability dropping to the failed sensor's level (silence, in this
system's case), the working neighbour actively extends its coverage
and the user is explicitly told protection is reduced rather than
being left to assume it is full.

## 3. Why this is a specific, non-obvious mechanism (not just "we added error handling")

- It is **conditional and reversible**, not a permanently loosened
  threshold — §4's control test proves the same input (60cm) is
  classified differently depending on whether a neighbour has failed.
- It ties a **specific compensation topology** (front↔either side) to
  the physical sensor layout, rather than a generic "average the
  sensors" rule.
- It introduces a **fourth, dedicated notification state** (`DEGRADED`)
  distinct from both "normal" and "alarm" — a deliberate three-tier
  communication design (full protection / reduced-but-compensated
  protection / danger), not a binary fault flag.
- It is **claimable as a system**, not a bare algorithm: the
  mechanism only exists in the context of the specific sensor array +
  processor + haptic actuators executing it, which matters under
  India's Patents Act 1970 §3(k) exclusion of "algorithms per se" —
  a method tied to a specific hardware system has a materially
  different standing than a pure software claim.

## 4. Evidence — genuinely executed, not predicted

Every claim above is backed by an actual automated `wokwi-cli` run,
not a manual trace:

**Wokwi cannot simulate a true sensor timeout via its distance slider**
(2–400cm only, documented in `docs/SIMULATION_LIMITATIONS.md`), so
genuine fault testing requires an actual disconnected wire. A second
diagram, `wokwi/diagram_front_fault.json`, is identical to the main
circuit with the front HC‑SR04's ECHO line genuinely unwired — this is
the only reliable way to produce a real `SENSOR_FAULT` in simulation.

| # | Test | Scenario file | Input | Result |
|---|---|---|---|---|
| 1 | **Compensation proof** | `test_scenario_fault.yaml` (fault diagram) | Front faulted, left=60cm (beyond normal 50cm WARNING, within widened 75cm) | `MSG ... risk=WARNING` — **D25=1**, triggered by compensation |
| 2 | **DEGRADED reachable** | `test_scenario_fault_degraded.yaml` (fault diagram) | Front faulted; left forced to DANGER then reverted to SAFE, triggering a fresh transition | `DECISION state=DEGRADED` — verified via `--expect-text`, not pin timing (the pulse's 300ms-of-1000ms ON window and the ~300ms transition-phase uncertainty are the same size, so no fixed-delay pin check can be guaranteed to land inside it — see `docs/DISSERTATION1_TEST_PLAN.md` test 19's design note for the full reasoning) |
| 3 | **Control / counter-proof** | `test_scenario.yaml` (normal diagram, step 9) | All sensors healthy, left=60cm (same distance as test 1) | `MSG ... risk=SAFE` — **D25=0**, confirming compensation is conditional, not a permanently loosened threshold |

Test 1: `wokwi-cli . --diagram-file diagram_front_fault.json --scenario
test_scenario_fault.yaml --timeout 30000` → `Scenario completed
successfully`, exit code 0.
Test 2: `wokwi-cli . --diagram-file diagram_front_fault.json --scenario
test_scenario_fault_degraded.yaml --expect-text "DECISION
state=DEGRADED" --timeout 30000` → `TEST PASSED`, exit code 0,
confirmed stable across 6 repeated runs.
Test 3 (plus the main scenarios from `docs/PRE_HARDWARE_VALIDATION_REPORT.md`):
`wokwi-cli . --scenario test_scenario.yaml --timeout 30000` → `Scenario
completed successfully`, exit code 0.

**Tests 1 and 3 together are the key proof** of the compensation
mechanism itself: the *identical* 60cm reading is classified `WARNING`
when a neighbour has failed and `SAFE` when it hasn't — demonstrated
on the live simulator, not asserted in prose. Test 2 proves DEGRADED is
reachable at all, via the firmware's own stated decision rather than an
LED snapshot.

## 5. Correctness note, separate from the novelty claim: a pre-existing bug found and fixed

While building the dual-fault test in §6 below, direct code inspection
(`grep` for every `RiskLevel::DANGER` comparison in the decision chain)
found that the original precedence chain only ever checked `frontRisk`
for `DANGER` — a `DANGER`-level (≤25cm) reading from the **left or
right** sensor alone fell through every branch (`WARNING != DANGER`)
all the way to `CLEAR`/`DEGRADED`, producing no warning at all for an
obstacle as close as the front-DANGER case already treats as an
immediate stop. This predates this phase's work and is unrelated to
the fault-tolerance mechanism itself. Fixed in `wokwi/main.ino` by
adding explicit `leftRisk == DANGER` / `rightRisk == DANGER` branches
(both → `STOP`), and locked in by a regression test (`test_scenario.yaml`
steps 10, added for exactly this). This is a correctness fix, not a
novelty claim — noted here only so it isn't mistaken for part of §2–3.

## 6. Correlated/multiple-fault fail-safe (a robustness extension, not a novelty claim)

**Labelled plainly up front**: unlike §2–3, this is not presented as
novel at all, in any sense. "Distrust a compensation mechanism when
enough of its inputs have failed, and fall back to the system's
existing safe state" is a textbook fail-safe principle used throughout
reliability engineering — there is nothing specific or non-obvious
being claimed here. It is included because it closes an honest
objection the deep-research pass raised against §2's mechanism (see
below), and because dissertation and test-plan completeness benefit
from stating it, not because it strengthens the novelty case.

The mechanism in §2 assumes faults are independent — compensating a
single failed sensor via its one working neighbour. The 25-paper
deep-research pass flagged a literature-grounded objection to that
assumption: **Muzychenko (2025)** notes that voting-style/neighbour-
compensation fault tolerance "loses effectiveness with ... multiple
correlated faults" — and three ultrasonic sensors sharing one
wearable's power rail, mounting, and acoustic environment are a
plausible *correlated*-fault scenario (e.g. a power-rail brownout or a
loose harness taking out two sensors together), not an independent one
in the classical reliability-theory sense.

`main.ino` now computes `faultCount` (0–3) every cycle and only trusts
compensation when `faultCount == 1` (`compensationTrusted`). With 2 or
more sensors down simultaneously:

- Compensation is disabled entirely — no threshold is widened on the
  strength of a single remaining sensor covering for two failures.
- The system falls back to the existing `STOP` haptic pattern (reused,
  not a new state) whenever the one remaining healthy sensor shows
  nothing within its *normal* (uncompensated) range — rather than
  presenting the gentle `DEGRADED` pulse, which would overstate
  confidence in a reading this thin.
- Critically, a **genuine direct** `WARNING` or `DANGER` reading from
  the remaining healthy sensor still takes precedence over this
  fail-safe branch (it is checked earlier in the precedence chain) —
  real sensor data is always trusted regardless of how many *other*
  sensors have failed; only the *absence* of a reading triggers the
  conservative fallback.

**Evidence** — a third circuit variant, `wokwi/diagram_dual_fault.json`
(front **and** left ECHO both genuinely unwired, only right remains
healthy), and `wokwi/test_scenario_dual_fault.yaml`:

| # | Test | Input (right sensor) | Result |
|---|---|---|---|
| 1 | Fail-safe engages | 200cm (nothing detected) | `DECISION state=STOP reason="2+ sensors faulted simultaneously..."` — **D25=1, D26=1** |
| 2 | Direct WARNING still honoured | 40cm (genuine, uncompensated WARNING) | `DECISION state=RIGHT reason="right sensor WARNING"` — **D25=0, D26=1**, not swallowed by the fail-safe |
| 3 | Direct DANGER still honoured | 20cm (genuine DANGER) | `DECISION state=STOP reason="right sensor DANGER..."` — **D25=1, D26=1**, via the direct-DANGER branch (same pin outcome as test 1, but a structurally higher-precedence code path — not distinguishable by pin state alone, verified by code order/the Serial `reason=` log instead) |

`wokwi-cli . --diagram-file diagram_dual_fault.json --scenario
test_scenario_dual_fault.yaml --timeout 30000` → `Scenario completed
successfully`, exit code 0; Serial log confirms `FAULT node=NODE_FRONT`
and `FAULT node=NODE_LEFT` both firing every cycle throughout.

**Extended evidence — total sensor failure (all 3, not just 2 of 3).**
Prompted directly by the question "could this system ever silently
report CLEAR when it is actually completely blind?" — a genuinely
important question to be able to answer with evidence, not reassurance.
A fourth circuit variant, `wokwi/diagram_triple_fault.json` (all three
ECHO lines genuinely unwired, zero healthy sensors remain), with
`wokwi/test_scenario_triple_fault.yaml`: from the very first decision
cycle after boot, and sustained across multiple further cycles,
`DECISION state=STOP reason="2+ sensors faulted simultaneously..."` —
**D25=1, D26=1**, both checks. The same `faultCount>=2` fail-safe
already proven for 2-of-3 failures was never actually tested at 3-of-3
until this check; it behaves identically (continuous STOP, never
CLEAR), as the code's structure predicts (`faultCount` is just an
integer count, with no special case missing for 3), but this is now
*proven*, not assumed. `wokwi-cli . --diagram-file
diagram_triple_fault.json --scenario test_scenario_triple_fault.yaml
--timeout 30000` → `Scenario completed successfully`, exit code 0.

## 7. Quantified coverage-retention metric for DEGRADED (not a novelty claim either)

**Labelled plainly up front, same as §6**: this is arithmetic
(75/50 = 1.5×), not a mechanism or a method — there is no novelty
claim attached to stating a number. It is included because the
deep-research pass specifically recommended quantifying §2's
compensation rather than leaving it qualitative, and a dissertation
panel reasonably expects a number where one is available.

The second recommendation from the 25-paper deep-research pass: give
the `DEGRADED` compensation a concrete number rather than only a
qualitative "coverage is reduced" description. Stated honestly and
narrowly, since this firmware has no geometric beam-angle or
solid-angle model for the HC‑SR04 sensors (see
`docs/SIMULATION_LIMITATIONS.md`) — this is a **1-D warning-zone depth
metric for the compensating neighbour's own detection cone**, not an
area/solid-angle "coverage" figure, and it says nothing about the
failed sensor's own blind spot, which is not geometrically covered by
a neighbour mounted in a different position/orientation.

- Normal `WARNING` threshold: 50cm. Compensated (neighbour-widened)
  threshold: 50cm × `DEGRADED_THRESHOLD_MULTIPLIER` (1.5) = 75cm.
- **Warning-zone depth retained by the compensating neighbour: +50%**
  (an additional 25cm of early-warning depth, 75cm vs. 50cm), in
  exchange for the explicit `DEGRADED` disclosure that this is reduced-
  confidence coverage, not full protection.
- Without compensation, the same 60–75cm band on the healthy neighbour
  reads `SAFE` (as §4 test 3 / `test_scenario.yaml` step 9 proves) —
  i.e. the uncompensated system's "retained coverage" in that band is
  0%; compensation is what raises it to the 50% figure above, not an
  inherent property of the hardware.
- This number characterises **one neighbour's own extended radius
  only**. It does not, and is not claimed to, quantify recovery of the
  failed sensor's own field of view — restoring that would require
  actual sensor fusion/geometric triangulation, explicitly out of scope
  for a one-day, firmware-only addition (see the deep-research report's
  "do NOT build" list, "Embedded obstacle sensing novelty 2026",
  outside this folder — ask if you need it re-attached here).

## 9. Temporal WARNING confirmation (a second gap-fill, also not claimed as novel)

**Labelled plainly up front, same as §6–7**: N-of-M temporal
confirmation / hysteresis is one of the oldest, most standard
techniques in embedded sensing — not novel in any sense, and in fact
this project explicitly *deferred* adding it earlier (classified
MINOR, "not worth over-engineering before physical testing shows it's
needed"). What changed is not a reassessment of that engineering
judgement; it's that the literature pass surfaced a specific, named,
still-unsolved limitation this directly answers.

**The limitation, in the paper's own words**: Gao et al. (2025, *Nature
Communications*) — the strongest paper reviewed for this dissertation
(§1) — report a user-survey-identified **"alert fatigue"** problem from
oversensitive single-mode detection, and list **"refining detection
algorithms to reduce false positives"** as their own future work, not
solved in their paper either.

**The mechanism**: `confirmWarning()` in `main.ino` requires a
`WARNING`-level reading to persist for `WARNING_CONFIRM_CYCLES` (2)
consecutive sensing cycles (~600ms) before it is acted on. Deliberately
asymmetric, for safety: `DANGER`, `SENSOR_FAULT`, and any return to
`SAFE` are never delayed — only the moderate `WARNING` case Gao et
al.'s users specifically complained about is. The raw, unfiltered
classification is still what's printed in each `MSG` line (so a
transient blip remains visible in the log even when the haptic output
correctly ignores it) — only the DECISION layer sees the confirmed
value.

**Evidence** — `wokwi/test_scenario_confirm_filter.yaml` (main
diagram, no fault involved): a 40cm left reading held for exactly one
cycle then reverted to 200cm (clear) never promotes to `LEFT`
(`D25` stays 0 throughout — the alert-fatigue case, suppressed); the
same 40cm reading held continuously **is** confirmed and acted on
within two cycles (`D25` goes 0→1 at the second cycle, not delayed
indefinitely). `wokwi-cli . --scenario
test_scenario_confirm_filter.yaml --timeout 30000` → `Scenario
completed successfully`, exit code 0, 4/4 assertions passed.

**Honest tradeoff, stated explicitly**: this introduces a bounded
~300ms worst-case detection delay for a single, momentary WARNING-level
obstacle (e.g. something that appears and disappears within one
sensing cycle) in exchange for suppressing false positives on
borderline/noisy readings. `DANGER` is never subject to this delay.
Like every other threshold in this workspace, 2 cycles is a reasoned
placeholder, not physically calibrated.

**Interaction with §2's mechanism, observed during testing**: when a
sensor is faulted (DEGRADED-eligible) and its compensated neighbour's
WARNING is mid-confirmation, the system reports `DEGRADED` during the
delay rather than a bare `CLEAR` — the two mechanisms compose safely,
confirmed via Serial log in `test_scenario_fault.yaml`'s run, not
merely asserted.

## 10. Closing-speed escalation (a third gap-fill, also not claimed as novel)

**Labelled plainly up front, same as §6–7 and §9**: comparing two
consecutive readings to detect a fast change is a basic technique, not
a novel mechanism. This responds directly to a real-world risk
surfaced by critical review of this project, not a literature-stated
limitation: the normal decision chain only looks at a sensor's
*current* absolute distance against fixed thresholds, so an object
closing in quickly (another pedestrian, a cyclist) gets no response
until it happens to cross `DANGER_DISTANCE_CM` — by which point
reaction time may already be too short.

**The mechanism**: `isClosingFast()` in `main.ino` compares each
sensor's current raw reading against its own previous cycle's reading.
If a sensor's distance drops by at least `CLOSING_RATE_DANGER_CM`
(40cm, ≈133cm/s, roughly brisk-jogging speed — a reasoned placeholder,
not derived from physical human-approach-speed data) within one
`SENSOR_CYCLE_MS` (300ms) while still inside `CLOSING_RATE_ZONE_CM`
(150cm), that sensor escalates straight to `STOP` — ahead of the
WARNING checks and bypassing `confirmWarning()`'s 2-cycle delay
entirely, the same way `DANGER` does, since a sharp rate of closure is
already a stronger signal than one raw reading.

**Evidence** — `wokwi/test_scenario_closing_speed.yaml` (main diagram):
a front reading jumping from 150cm to 90cm in one cycle (delta=60cm,
current still SAFE by the normal fixed thresholds — without this
mechanism this would stay `CLEAR`) escalates to `STOP`
(**D25=1, D26=1**); the counter-proof, a smaller 150cm→120cm jump
(delta=30cm, below the 40cm threshold) correctly does **not** escalate
(**D25=0, D26=0**), confirming this triggers on rate of closure, not
merely "distance decreased." `wokwi-cli . --scenario
test_scenario_closing_speed.yaml --timeout 30000` → `Scenario
completed successfully`, exit code 0, 4/4 assertions passed.

**An honest limitation found while building this, worth stating
plainly**: Wokwi's sensor `distance` control only supports setting an
instantaneous absolute value — there is no way to simulate a smooth,
continuous approach. This means every test scenario in this whole
project that jumps a sensor from a far baseline straight to a near one
(which is most of them — e.g. `test_scenario.yaml`'s 200cm→40cm
WARNING setup) looks, for exactly one cycle, mathematically identical
to a genuinely fast-approaching object. This surfaced as a real
regression: `test_scenario_confirm_filter.yaml`'s precise 1-cycle
timing check initially broke, because its own 200cm→40cm jump
triggered this new mechanism as an unintended side effect. Fixed by
starting that file's baseline closer (70cm, delta=30cm, under
threshold) so it tests `confirmWarning()` in isolation — documented
here, not silently patched over, because it is a genuine, structural
limitation of validating a rate-based mechanism against a simulator
with no continuous-motion model, not merely a test-authoring mistake.
A physical build would not have this ambiguity, since a real obstacle
cannot teleport.

## 11. What this does NOT establish

- **Not a patentability determination.** Only a professional prior-art
  search by a patent agent can establish that no closer prior art
  exists than the three papers reviewed here.
- **Not physically validated.** The 1.5× multiplier, the 300ms/1000ms
  pulse timing, and the front↔side compensation topology are
  reasoned starting points, not derived from physical testing —
  consistent with every other threshold in this workspace (see
  `docs/DISSERTATION1_TEST_PLAN.md`).
- **Does not make the system "safe."** A compensated sensor still has
  objectively less information than a working one; `DEGRADED` communicates
  reduced confidence, it does not restore full coverage.
- **§9's confirmation filter is not a novelty claim** (hysteresis is a
  standard, well-known technique) and introduces a real, bounded
  detection-delay tradeoff for momentary WARNING-level obstacles —
  see §9's explicit statement of that tradeoff.
- **§10's closing-speed escalation is not a novelty claim either**, its
  40cm/cycle threshold is an unvalidated placeholder (not derived from
  real human- or vehicle-approach-speed data), and — as documented in
  §10 itself — it cannot be cleanly distinguished from the simulator's
  own instantaneous scenario-setup jumps in Wokwi, only from genuine
  continuous motion on real hardware.
- **Neither §9 nor §10 solves the gaps identified by direct critical
  review that actually require new hardware** — ground-level hazards
  (stairs, curbs, drop-offs), specular surfaces (glass, mirrors),
  acoustic cross-talk, and real haptic perceptibility remain entirely
  unaddressed and are not claimed to be. See README.md's safety-scope
  section for the explicit list of what this device is not suitable
  for, even once physically built as specified.
- **No patent has been filed.** This document is preparation material,
  not a filing, and no claim is made that filing has occurred or is
  guaranteed to succeed.
- **Not a claim that the general fault-compensation concept is new.**
  As stated up front, prior art for neighbour-sensor compensation with
  a reduced-confidence signal exists at least back to Luck & Ray (1991)
  and in decades of aerospace/automotive fault-tolerance patents. The
  claim here is narrower and domain-specific — see the framing note at
  the top of this document and `reports/Embedded obstacle sensing
  novelty 2026.md` for the full 25-paper comparison this rests on.
- **§7's retention figure is a single-axis distance metric, not a
  coverage/area claim**, and does not quantify the failed sensor's own
  blind spot — see §7 for the explicit scope limit.
