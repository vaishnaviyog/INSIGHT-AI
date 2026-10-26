# INSIGHT — Dissertation 1 Review Report
### IoT/WSN Hardware Extension — Wokwi Simulation Prototype
Prepared for review: 2026-10-22

---

## 1. What this project is

INSIGHT (this repository's root) is an existing Flutter app that gives visually-impaired
users camera-based hazard detection and spoken feedback, entirely on-phone.
Dissertation 1 explores a **separate, external hardware layer** — a wearable
extension that would give the same kind of warning through touch (vibration)
instead of sound, using cheap, off-the-shelf parts.

**Hardware (simulated only — nothing physically built):**
- 1× ESP32 microcontroller
- 3× HC-SR04 ultrasonic distance sensors (front, left, right), chest-mounted
- 2× vibration motor outputs (LEFT/RIGHT haptic feedback)
- 1× buzzer, 1× SOS pushbutton

**What it does:** every 300ms, each sensor is classified SAFE / WARNING /
DANGER / SENSOR_FAULT. A fixed-precedence decision chain (not a black-box
model — deliberately simple and auditable) turns that into one of six
haptic states: CLEAR, LEFT, RIGHT, STOP, SOS, DEGRADED — each with its own
distinct vibration/buzzer pattern, so the user can tell them apart by feel.

This entire pipeline is built and verified in **Wokwi**, a browser-based
circuit simulator, driven by real firmware (`wokwi/main.ino`) — not a
diagram or a plan, a working, testable system, just not physically built yet.

---

## 2. Status, stated plainly

| Claim | Status |
|---|---|
| Logic/decision pipeline works as designed | ✅ SIMULATED and VERIFIED — 44/44 automated test assertions pass |
| Electrical design (voltage dividers, motor driver stage) | ✅ THEORETICALLY PROPOSED, reasoned, documented — not physically measured |
| Physical device exists | ❌ No. Nothing has been built or purchased. |
| Tested with a real visually-impaired user | ❌ No human testing of any kind has occurred. |

Every document in this project states this distinction explicitly —
**SIMULATED**, **THEORETICALLY PROPOSED**, or **PHYSICALLY TESTED** — and
nothing here claims a status it hasn't earned.

---

## 3. Methodology — how this was actually validated

Unlike a purely theoretical design, every behavioral claim in this project
is backed by an **automated, executed test**, not a manual trace or a
diagram read by eye. The tool is `wokwi-cli`, which can:
1. Programmatically set a simulated sensor's distance (or press a button),
2. Let the real firmware run and make its own decision,
3. Assert the real simulated GPIO pin state afterward (`expect-pin`),
4. Capture the full Serial console log as corroborating evidence.

This is closer to a hardware logic-analyzer test than a software unit test
— it reads the actual simulated circuit's output, not a value the code
claims about itself.

**Seven scenario files, four circuit-diagram variants, 44/44 assertions
pass:**

| Scenario file | Diagram variant | Assertions | Proves |
|---|---|---|---|
| `test_scenario.yaml` | main | 22 | Clear/Left/Right/Stop/SOS precedence chain, including a corrected left/right DANGER bug |
| `test_scenario_fault.yaml` | front sensor disconnected | 2 | Adaptive compensation: a failed sensor's neighbour widens its warning zone |
| `test_scenario_fault_degraded.yaml` | front sensor disconnected | 2 | The DEGRADED "reduced coverage" haptic signal is reachable and correctly timed |
| `test_scenario_dual_fault.yaml` | front + left disconnected | 6 | Correlated 2-sensor failure triggers a conservative fail-safe, without masking a genuine reading from the remaining sensor |
| `test_scenario_triple_fault.yaml` | all 3 sensors disconnected | 4 | **The system can never silently report "clear" when completely blind** — proven, not assumed |
| `test_scenario_confirm_filter.yaml` | main | 4 | A single noisy reading is suppressed (no false alert); a real, sustained one still gets through within ~600ms |
| `test_scenario_closing_speed.yaml` | main | 4 | A fast-approaching obstacle is caught even before it crosses the normal distance threshold |

Full transcripts and pass/fail detail: `docs/DISSERTATION1_TEST_PLAN.md`,
`docs/PRE_HARDWARE_VALIDATION_REPORT.md`.

---

## 4. The core contribution: Adaptive Fault-Tolerant Zone Reallocation

**The literature gap** (full citations and quotes in
`docs/NOVELTY_CONTRIBUTION.md` §1): three closely-related 2025–2026
assistive-wearable papers were reviewed in depth (Ray & Indupuru 2026;
Ikeme et al. 2025; Gao et al. 2025, *Nature Communications*). None of them
actively compensate when one of their own sensors fails — either the
failure isn't addressed at all, or (per Gao et al., the strongest paper
reviewed) the system's overall reliability is explicitly acknowledged to
drop to the level of its single weakest component.

**What was built:** when a sensor stops responding, its geometric
neighbour's WARNING threshold automatically widens (50cm → 75cm) to
partially cover the resulting blind spot. DANGER is deliberately never
widened — only the earlier heads-up zone is — so a degraded sensor can
prompt an earlier warning but never fabricate a false emergency stop. A
new haptic state, **DEGRADED**, tells the user explicitly that coverage is
reduced, instead of a silent CLEAR output that would be indistinguishable
from full protection.

**Honest framing — read this before claiming novelty to anyone:** a
25-paper deep-research literature pass found that the *general* concept
here (neighbour-sensor compensation + a reduced-confidence signal) is not
new in an absolute sense — it traces back to Luck & Ray (1991) in general
fault-tolerant control theory, and automotive/aerospace patents cover
adjacent-sensor fault compensation broadly. **What is actually being
claimed is narrower**: a *translation* of that known technique into the
cheap embedded/wearable assistive-tech niche, where the closely-reviewed
recent literature does not implement it. This is a defensible dissertation
contribution. It is explicitly **not** presented as a patentable invention
of the general concept — see §9 below.

---

## 5. Three further additions — robustness, not novelty

These were added after direct critical review asked plainly: *is this
actually safe for a blind user, or could it mislead them?* Each is labelled
honestly as closing a specific, real gap — not as strengthening the
novelty claim, which they do not.

1. **Correlated multi-fault fail-safe** (`NOVELTY_CONTRIBUTION.md` §6):
   when 2 or 3 sensors fail simultaneously — plausible on one wearable
   sharing a power rail and mounting — compensation is disabled entirely
   (a single widened threshold can't responsibly cover for two failures)
   and the system falls back to continuous STOP. Proven for both 2-of-3
   and, as of this review cycle, the complete 3-of-3 case: **the system
   has never been observed to report CLEAR when it is actually blind.**

2. **Temporal WARNING confirmation** (§9): addresses Gao et al.'s own
   named, unsolved "alert fatigue" problem — a momentary noisy reading no
   longer triggers a false alert; a genuine one is still acted on within
   ~600ms. DANGER is never delayed by this.

3. **Closing-speed escalation** (§10): a sensor reading that drops sharply
   between two consecutive cycles (≈133cm/s or faster) escalates straight
   to STOP, even before crossing the normal fixed distance thresholds —
   addressing the risk that a fast-approaching obstacle (another
   pedestrian, a cyclist) might not otherwise be caught in time. Building
   this surfaced a genuine, documented limitation: Wokwi's simulator can't
   model continuous motion, so this can only be partially validated in
   simulation — stated plainly in §10 rather than glossed over.

---

## 6. Safety scope — what this device is NOT, even once built

This is the most important section of this report, and is now stated
prominently at the top of `README.md`, not buried in an appendix.

**Not detected at all:**
- Stairs, curbs, potholes, drop-offs — the sensors face outward from the
  chest, never downward. This is arguably the single most important gap:
  ground-level hazards are among the most common serious injury risks for
  a blind pedestrian, and this device gives no warning for any of them.
- Overhead obstacles below head height (low branches, an open car door).

**Can be unreliable for what it does face:**
- Glass, mirrors, and angled smooth surfaces can reflect the ultrasonic
  pulse away from the sensor — reading identically to "nothing there."
- Soft/thin materials may not reflect enough signal to register reliably.
- No outdoor-weather, cross-talk, or real haptic-perceptibility testing
  has been done — all of it requires physical hardware.

**The SOS button does not call or message anyone.** It only logs an event
in this prototype. No phone/emergency integration exists yet.

**Conclusion of this section:** this is a plausible *supplement* to a
white cane or guide dog for close-range, roughly chest-height obstacles.
It is not, and should never be presented as, a standalone replacement.

---

## 7. Patentability — a direct, unhedged answer

**No, the core mechanism is not confidently patentable as currently
understood**, and this report would rather say that plainly than overstate
it to a panel or an agent later.

- **Patent novelty/inventive step: weak.** A real patent search would
  likely surface the automotive/aerospace prior art mentioned in §4 and
  find this an obvious application of a known technique to a new product
  category.
- **Dissertation-level contribution: defensible.** The gap in the
  specific, closely-reviewed recent literature is real, citable, and
  closed with a working, tested, hardware-tied mechanism.
- **What kind of patent, if pursued anyway:** a utility patent application
  under India's Patents Act 1970 would be the relevant instrument (method
  + system claim, tied to the specific sensor/processor/haptic hardware —
  relevant under §3(k)'s exclusion of "algorithms per se," since this is
  claimed as a system, not bare software). A Design registration under the
  Designs Act 2000 is a narrower, separate alternative if ever a specific
  physical housing/form were finalized — not applicable to the logic
  itself.
- **Before filing anything**: a professional prior-art search by a
  registered patent agent is the only way to get an actual answer. This
  report is preparation material for that conversation, not a substitute
  for it, and no claim is made that filing has occurred or would succeed.

---

## 8. Limitations and future work

- **No physical hardware exists.** Every electrical design decision
  (voltage dividers, motor driver stage, power budget) is reasoned but
  unmeasured.
- **No human testing.** Haptic pattern distinguishability, real reaction
  times, and threshold comfort are all unvalidated assumptions.
- **No hysteresis beyond WARNING.** DANGER and SAFE transitions are
  intentionally instant (safety-first); this is a stated tradeoff, not an
  oversight.
- **Ground-level/overhead hazard detection** would require a different
  sensor placement (e.g. a cane-tip-mounted downward sensor) — the single
  highest-value future addition for real safety, ahead of anything built
  so far.
- **Stage 2 (real WSN)** — a genuinely wireless, spatially-distributed
  node — remains a documented but unbuilt design (`docs/WSN_STAGE2_DESIGN.md`).

---

## 9. One-paragraph summary to say out loud at review

*"We built and fully tested, in simulation, a low-cost obstacle-sensing
wearable concept for visually-impaired users — three ultrasonic sensors
feeding a simple, auditable decision engine that drives distinct
vibration patterns. Its main contribution is noticing when one of its own
sensors fails and adapting instead of silently pretending everything is
fine — a gap we found stated directly in three recent closely-related
papers. We verified this and three further safety extensions with 44
automated, passing tests — not manual traces. We are explicit that the
general compensation idea isn't patentably new on its own, that nothing
has been physically built or tested with a real user yet, and that the
device has real, named blind spots — especially ground-level hazards —
that no amount of firmware work can close without different hardware."*
