# Power Architecture

Status: THEORETICALLY PROPOSED, with one part (the ECHO voltage
divider) also reflected in the Wokwi simulation for wiring-diagram
purposes only — see the caveat in §4. Nothing here is physically
measured. This document resolves the 3.3V-vs-5V question, and is the
single source of truth for the power path — other docs should link
here rather than restate these numbers.

## 1. Decision: HC‑SR04 stays at 5V (not 3.3V)

| | 3.3V operation | 5V operation (chosen) |
|---|---|---|
| Datasheet compliance | Out of spec on most HC‑SR04/clone datasheets (nominal 5V ±0.2V) | In spec |
| Reliability across clone boards | Inconsistent — many cheap clones are reported to under-range, mis-trigger, or simply not work reliably below ~4.5V; behaviour varies by manufacturer batch | Consistent, matches what the sensor was designed and characterised for |
| Range/sensitivity | Reduced, and not quantified for whichever specific board is purchased | Full rated range |
| Extra components needed | None | A 5V boost converter (LiPo 3.7V nominal → regulated 5V), plus the ECHO-line divider either way (see §2) |
| Research validity risk | Introduces an **unvalidated variable** — "does this specific purchased HC‑SR04 actually work reliably at 3.3V" — into every subsequent distance-accuracy experiment | No such variable; sensor behaviour matches its datasheet |

**Decision: power all three HC‑SR04 units at 5V**, via a small boost
converter from the LiPo battery. The reasoning is not "avoid the
divider" — a divider is required either way to protect the ESP32 GPIO
from the ECHO line's HIGH level, which tracks whatever HC‑SR04's own
supply voltage is (see §2). The reasoning is specifically to avoid
introducing an *additional, unvalidated reliability question* (3.3V
clone-board behaviour) into a dissertation that already has enough
open experimental variables (§10 of the audit). If physical testing
later shows the boost converter is impractical (cost, size, noise),
3.3V operation remains a documented fallback — but it must then be
treated as its own explicit experimental variable, not a free
simplification.

## 2. ECHO-line voltage divider (required regardless of §1's outcome)

HC‑SR04's ECHO output swings to approximately its own VCC when HIGH.
At 5V supply, that is ~5V into a GPIO whose absolute maximum rating is
roughly 3.6V (ESP32, most variants) — not safe to connect directly, as
identified as CRITICAL in the audit.

**Divider design** (per ECHO line, ×3 — front/left/right):

```
HC-SR04 ECHO (≈5V when HIGH)
        │
       [R_top = 2.2 kΩ]
        │
        ├──────────────► ESP32 GPIO (D18 / D21 / D23)
        │
       [R_bot = 3.3 kΩ]
        │
       GND
```

**Calculation**:

- `V_out = V_in × R_bot / (R_top + R_bot) = 5.0V × 3300 / (2200 + 3300) = 5.0V × 0.6 = 3.0V`
- This is comfortably above a typical CMOS logic-HIGH detection
  threshold (~0.7 × 3.3V ≈ 2.31V for the ESP32's 3.3V logic) and
  comfortably below the ~3.6V absolute maximum, leaving margin on both
  sides.
- **Current draw**: `I = V_in / (R_top + R_bot) = 5.0V / 5500Ω ≈ 0.91 mA`,
  and only while ECHO is actually HIGH (a few hundred µs to low
  milliseconds per reading, not continuous) — negligible against
  HC‑SR04's own ~15mA typical draw and negligible for battery budget.
- **Loading effect on the divider itself**: ESP32 GPIO input leakage
  current is in the low-µA range, several orders of magnitude below
  the divider's ~0.91mA, so it does not meaningfully change the
  ideal-divider calculation above.
- **TRIG lines need no divider**: TRIG is an ESP32 **output** driving
  an HC‑SR04 **input**. A 3.3V logic HIGH from the ESP32 is
  commonly accepted as a valid trigger HIGH by HC‑SR04's TRIG input
  (this is standard, widely-used practice) — the direction of concern
  (driving a higher-voltage input into a lower-voltage output pin) does
  not apply here.

**Components required** (×3 sets, one per sensor): 2.2kΩ resistor,
3.3kΩ resistor — both common E12-series values, negligible cost (see
`docs/BILL_OF_MATERIALS.md`).

This divider is a simple, well-understood, low-parts-count solution
appropriate for a student prototype — a dedicated level-shifter IC
was considered and rejected as unnecessary complexity/cost for a
single-direction (HIGH-only) digital signal at this data rate.

## 3. Boost converter (5V rail from LiPo)

- **Component**: a small MT3608-class boost converter module (or
  equivalent) — LiPo (3.0–4.2V, nominal 3.7V) → regulated 5V output.
- **Load**: 3× HC‑SR04 (~15mA each typical, ~45mA total) — comfortably
  within a typical low-cost boost module's output rating (commonly
  ≥500mA), leaving large headroom.
- **Placement in the power path**:

```
LiPo battery (3.7V nominal)
        │
   [Power switch]  — see §5
        │
        ├──────────────► ESP32 5V/VIN pin path... see note below
        │
   [Boost converter 3.7V → 5V]
        │
        ├──► Front HC-SR04 VCC
        ├──► Left HC-SR04 VCC
        └──► Right HC-SR04 VCC
```

  Note: the ESP32 devkit itself is normally powered via its own `5V`/
  `VIN` input pin (from USB in the simulator) or, in a battery build,
  by feeding regulated 5V into `VIN` as well (the board's onboard
  regulator then derives its own 3.3V rail from that). This document
  treats "the boost converter's 5V output" as the shared rail feeding
  both the ESP32's `VIN` and the three HC‑SR04 `VCC` pins in the
  physical build — a single boost converter, not one per sensor.
- **Ground**: the boost converter's ground, the LiPo's ground, and the
  ESP32's ground must all be tied to one common ground net, same as
  everything else in `docs/CIRCUIT_CONNECTIONS.md`.

## 4. What Wokwi simulates vs what this document decides

The ECHO voltage divider (§2) **is** drawn in `wokwi/diagram.json`, so
the wiring topology is visible and reviewable in the simulation.
**This is a documentation/completeness aid, not electrical proof.**
Wokwi's digital-pin model does not simulate analog voltage division —
it does not validate the 3.0V calculation above, and it cannot
distinguish this "safe" divider from an unsafe one electrically. The
boost converter (§3) is **not** represented in Wokwi at all: the
simulator runs on virtual USB power with no battery/boost-converter
model, and adding a non-functional placeholder part would not
validate anything either. **Physical validation of this entire power
path (§1–§3) is required before it is trusted** — see
`docs/SIMULATION_LIMITATIONS.md`.

## 5. Power switch

An SPST (single-pole single-throw) toggle or slide switch is placed in
series on the battery-positive line, before the boost converter and
before the ESP32's power input — i.e. it switches the entire device
off, not just one subsystem:

```
LiPo (+) ──[Power switch]──┬──► ESP32 VIN/5V
                             └──► Boost converter input ──► HC-SR04 VCC ×3
```

Not represented in `wokwi/diagram.json` — Wokwi's simulated ESP32
already has an implicit always-on virtual USB supply, and a switch
part would not meaningfully change or validate anything about the
simulation. It is documented here purely as a physical-build BOM/wiring
item — see `docs/BILL_OF_MATERIALS.md` and
`docs/CIRCUIT_CONNECTIONS.md`.

## 6. Current budget (estimated, NOT measured)

| Load | Approx. current |
|---|---|
| ESP32 (active, no Wi‑Fi/ESP‑NOW in Stage 1) | ~80–160mA typical, higher in bursts |
| 3× HC‑SR04 | ~45mA total while all active (brief per-cycle pulses, not continuous) |
| 2× vibration motors (when driven) | Depends on motor selected — not yet purchased; typically tens to ~100mA each for a small coin motor |
| Boost converter conversion losses | Non-trivial (~10–20% typical for a cheap module) — not quantified here |

**No battery-life estimate is claimed.** This table exists to justify
that a boost module's typical current rating (≥500mA) has comfortable
headroom for this load — it is not a runtime prediction. Actual
current draw ("energy/battery endurance") must be measured on physical
hardware.
