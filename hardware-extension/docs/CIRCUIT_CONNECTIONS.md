# Circuit Connections

Status: SIMULATED (Wokwi) for the wiring topology shown in
`wokwi/diagram.json` and implemented by `wokwi/main.ino`. The
**vibration-motor driver stage** described in §3 below is
THEORETICALLY PROPOSED ONLY — it is not present in `wokwi/diagram.json`
at all (Wokwi has no vibration-motor part and no motor to drive), and
is not physically tested. See
`docs/POWER_ARCHITECTURE.md` for the full power-path reasoning
(3.3V-vs-5V decision, boost converter, divider math) this document
summarises.

## 1. Connection Table (as simulated in `wokwi/diagram.json`)

| Component | Pin | Connected To (ESP32 devkit-v1) | Purpose |
|---|---|---|---|
| Front ultrasonic (HC‑SR04) | VCC | VIN (~5V) | Power |
| Front ultrasonic | GND | GND.1 | Ground |
| Front ultrasonic | TRIG | D5 (output) | Trigger pulse |
| Front ultrasonic | ECHO | → `r_front_top` (2.2kΩ) → node → `r_front_bot` (3.3kΩ) → GND.1; node also → **D18** (input) | Echo pulse, level-shifted from ~5V to ~3.0V — see §2 |
| Left ultrasonic (HC‑SR04) | VCC | VIN | Power |
| Left ultrasonic | GND | GND.1 | Ground |
| Left ultrasonic | TRIG | D19 (output) | Trigger pulse |
| Left ultrasonic | ECHO | → `r_left_top` (2.2kΩ) → node → `r_left_bot` (3.3kΩ) → GND.1; node also → **D21** (input) | Echo pulse, level-shifted — see §2 |
| Right ultrasonic (HC‑SR04) | VCC | VIN | Power |
| Right ultrasonic | GND | GND.1 | Ground |
| Right ultrasonic | TRIG | D22 (output) | Trigger pulse |
| Right ultrasonic | ECHO | → `r_right_top` (2.2kΩ) → node → `r_right_bot` (3.3kΩ) → GND.1; node also → **D23** (input) | Echo pulse, level-shifted — see §2 |
| LEFT haptic LED (**virtual** motor representation) | Anode | D25 → 220Ω resistor → LED anode | Drive signal — see §3 for the REAL motor circuit this stands in for |
| LEFT haptic LED | Cathode | GND.2 | Return |
| RIGHT haptic LED (**virtual** motor representation) | Anode | D26 → 220Ω resistor → LED anode | Drive signal — see §3 |
| RIGHT haptic LED | Cathode | GND.2 | Return |
| Status/debug LED | Anode | D33 → 220Ω resistor → LED anode | Heartbeat / sensor-fault indicator, debug only |
| Status/debug LED | Cathode | GND.2 | Return |
| Buzzer | Pin 2 (+) | D27 | Drive signal (STOP / SOS only) |
| Buzzer | Pin 1 (−) | GND.2 | Return |
| SOS pushbutton | Leg 1 | D32 (`INPUT_PULLUP`) | Signal (active LOW) |
| SOS pushbutton | Leg 2 | GND.2 | Return — no external resistor needed, internal pull-up is used |

Every ground reference above is the same physical ground net
(`GND.1`/`GND.2` are two pins on the same rail), split across two pins
purely for wiring-diagram clarity in Wokwi.

## 2. ECHO-Line Voltage Divider (CRITICAL audit fix — now in the diagram)

HC‑SR04's ECHO output swings to approximately its own 5V supply level
when HIGH — not safe to feed directly into an ESP32 GPIO (3.3V logic,
not 5V-tolerant; absolute max ≈3.6V on most pins). Every ECHO line now
passes through a 2-resistor divider before reaching the GPIO:

```
HC-SR04 ECHO (≈5V)
        │
     [2.2 kΩ]   (r_*_top)
        │
        ├────────────────► ESP32 GPIO (D18 / D21 / D23)
        │
     [3.3 kΩ]   (r_*_bot)
        │
       GND
```

`V_GPIO = 5.0V × 3300/(2200+3300) = 3.0V` — see
`docs/POWER_ARCHITECTURE.md` §2 for the full calculation, current draw
(~0.91mA per divider, only while ECHO is HIGH), and the reasoning for
these specific values. TRIG lines need no divider — they are ESP32
outputs (3.3V) driving HC‑SR04 inputs, which is standard, accepted
practice.

**This divider IS drawn in `wokwi/diagram.json`** (parts `r_front_top`/
`r_front_bot`/`r_left_top`/`r_left_bot`/`r_right_top`/`r_right_bot`,
all `wokwi-resistor`), so the wiring topology is visible and
reviewable in simulation. **Wokwi's digital-pin model does not
simulate analog voltage division** — its presence in the diagram is a
documentation/completeness aid, not proof the divider is electrically
correct. That must be confirmed with a multimeter on physical
hardware before trusting it.

## 3. Vibration Motor Driver Stage (CRITICAL audit fix — design only, NOT in Wokwi)

A GPIO cannot safely or adequately drive a real vibration motor
directly — insufficient current and no back-EMF protection. Wokwi has
no vibration-motor part, so `wokwi/diagram.json` continues to drive
LEDs directly from D25/D26 as a **virtual representation of haptic
output — requires physical validation.** The circuit below is the
**physical-build-only** design those GPIOs are meant to drive instead
of an LED, and is not represented in the simulation at all:

```
Motor supply (boost-converter 5V rail — see docs/POWER_ARCHITECTURE.md)
        │
      Motor (+)
        │
     [Vibration motor]  ◄──┐
        │                   │ (flyback diode, reverse-biased,
      Motor (−)              across motor terminals — e.g. 1N4148/1N4001)
        │                   │
        └───────────────────┘
        │
      MOSFET drain
        │
   [N-channel logic-level MOSFET, e.g. 2N7000 / AO3400-class]
        │
      MOSFET source ── GND (common with ESP32 GND)
        │
      MOSFET gate
        │
     [220Ω gate resistor]
        │
      ESP32 GPIO (D25 or D26)
```

**Why a MOSFET, and why this specific type**: a small **logic-level
N-channel MOSFET** (fully switches on with a 3.3V gate drive — a
"logic-level" part specifically, not a standard MOSFET that needs
10V+ at the gate to fully turn on) is preferred here over a BJT
(e.g. 2N2222) because: (a) it needs negligible steady-state gate
current (a BJT needs a continuous base current sized to the motor
current ÷ hFE, adding another resistor-sizing calculation), (b) it has
lower on-resistance for a given size/cost at these currents, and (c)
logic-level parts rated for 3.3V gate drive are cheap and widely
available (e.g. 2N7000 for very small motors, or an AO3400-class part
for more current headroom). A BJT would also work and is an acceptable
substitute if that's what's available — the specific part is less
important than **not connecting the motor to the GPIO directly**.

- **Gate resistor (220Ω)**: limits inrush current into the MOSFET's
  gate capacitance when the GPIO switches; not current-limiting for
  the motor itself (the MOSFET's gate draws negligible steady current
  once charged).
- **Flyback diode**: required across the motor terminals, reverse-
  biased relative to normal current flow, to clamp the inductive
  voltage spike generated when the motor is switched off — without it,
  that spike can exceed the MOSFET's drain-source breakdown voltage
  and damage it over repeated cycles.
- **Common ground**: the MOSFET source, the motor supply's ground, and
  the ESP32's ground must all be the same net — same requirement as
  every other component in this document.
- **PWM note**: the current firmware (`wokwi/main.ino`) drives these
  pins with plain digital HIGH/LOW, not PWM — so this driver stage as
  described gives full-intensity-only vibration. Intensity control
  (for comfort tuning, per `docs/PHYSICAL_PLACEMENT.md`) would need
  the firmware to PWM the gate signal instead — not implemented, noted
  as future work, not silently assumed.

**Do not wire a real motor to D25/D26 directly.** This section defines
what belongs between the GPIO and the motor before any physical
assembly.

## 4. Power Switch (physical build only, not in Wokwi)

An SPST switch sits in series on the battery-positive line, ahead of
both the ESP32's power input and the boost converter feeding the
HC‑SR04 sensors — see `docs/POWER_ARCHITECTURE.md` §5 for the full
power-path diagram. Not added to `wokwi/diagram.json`: Wokwi's
simulated ESP32 runs on an always-on virtual USB supply, and a switch
part would not change or validate anything about the simulation.

## 5. Simplified Connection Diagram

```
                         ESP32 DevKit V1
                              │
        ┌──────────┬──────────┼──────────┬──────────┬─────────┐
        │          │          │          │          │         │
     D5/D18*    D19/D21*   D22/D23*      D25        D26       D27
   Front HC-SR04 Left HC-SR04 Right HC-SR04  LEFT LED    RIGHT LED   Buzzer
   (TRIG/ECHO)  (TRIG/ECHO)  (TRIG/ECHO)   (haptic sim)(haptic sim) (STOP/SOS)
        │          │          │          (real build: via MOSFET driver, §3)
      VIN/GND    VIN/GND    VIN/GND  (shared power/ground rail)
   * ECHO lines pass through a 2.2k/3.3k divider before the GPIO — see §2

        D32 ── SOS pushbutton ── GND.2   (INPUT_PULLUP, active LOW)
        D33 ── Status LED ── GND.2       (heartbeat + sensor-fault blink, not haptic)
```

## 6. Pins Deliberately Avoided

GPIO 0, 2, 12, 15 (boot-strapping pins) and GPIO 34/35/36/39
(input-only, no internal pull-up/down) were avoided for every output
and the pulled-up button input, to prevent boot-mode or floating-input
issues — this matters for the physical build; Wokwi's ESP32 model does
not always penalise strapping-pin misuse the way real silicon does, so
it cannot be relied on to catch this class of mistake.
