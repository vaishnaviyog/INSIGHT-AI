# Physical Placement (Conceptual)

Status: THEORETICALLY PROPOSED. Nothing in this document has been
built, worn, or tested. It exists to give the dissertation guide a
concrete starting point for discussion, and to surface constraints
that must be resolved before any physical purchase. This is the
**Stage 1** placement only (chest-worn sensor cluster) — see
`docs/WSN_STAGE2_DESIGN.md` for the separate, not-yet-designed
cane-tip node placement, which has materially different constraints
(ruggedness against ground impact, not just comfort).

## Proposed Layout

A chest-worn harness (or a cross-body strap pouch) rather than a cane
attachment, for one concrete reason: three separate ultrasonic sensors
(front/left/right) need a stable, forward-facing spread that a
constantly-rotating handheld cane cannot provide consistently.

```
                     ┌───────────────────────┐
                     │   Chest harness pouch  │
                     │  ┌─────────────────┐   │
                     │  │  ESP32 + wiring │   │
                     │  │  LiPo battery   │   │
                     │  └─────────────────┘   │
                     └───────────┬───────────┘
                    LEFT US ◄────┼────► RIGHT US
                                 │
                            FRONT US
                        (forward-facing,
                         chest height)

        Left shoulder strap: LEFT vibration motor (against collarbone/shoulder)
        Right shoulder strap: RIGHT vibration motor (against collarbone/shoulder)
        Strap-mounted: SOS button (thumb-reachable, e.g. near a strap buckle)
```

## Component-by-Component Placement Reasoning

| Component | Proposed location | Reasoning | Open concern |
|---|---|---|---|
| ESP32 + battery + boost converter + ECHO dividers | Chest pouch, centred | Shortest average wire run to all 3 ultrasonic sensors; centre of mass close to body; keeps the divider resistors and boost converter (both passive/small) with the rest of the electronics rather than distributed at each sensor | Pouch adds bulk/heat against the chest; needs ventilation |
| Power switch | Pouch exterior or edge, easily reachable | Must be operable without opening the enclosure | Needs a tactile/distinct switch, same accessibility reasoning as the SOS button below |
| Front HC‑SR04 | Chest height, forward-facing | Matches typical obstacle height (torso-level) for the "stop" case | Chin/head-height obstacles (e.g. low branches) are missed — same blind spot a chest mount always has |
| Left / Right HC‑SR04 | Angled ~30° outward from front, either side of the pouch | Gives lateral coverage for the LEFT/RIGHT warning states | Angled mounts are more fragile and easier to knock out of alignment than a flush front sensor; possible coverage gaps between the three fixed cones, unresolved without physical testing |
| LEFT / RIGHT vibration motors + their MOSFET driver stage | Motor at the shoulder strap (against skin/thin clothing); its small MOSFET+resistor+diode driver stays in the chest pouch with the rest of the electronics, with only 2 wires running out to each motor | Directly maps to the LEFT/RIGHT haptic convention; keeping the driver components centralised (not at the shoulder) minimises what's mounted at a flexing joint | Sweat/moisture contact with skin-mounted motors; must be washable/removable; the flyback diode must be physically close to the motor terminals it protects, not left behind in the pouch — see `docs/CIRCUIT_CONNECTIONS.md` §3 |
| SOS button | Strap-mounted, thumb-reachable, physically distinct shape (e.g. large, recessed) | Must be findable and pressable without looking, including under stress | Accidental triggering while adjusting the strap is a real risk — needs a debounce/hold design decision, which is exactly why `main.ino`'s SOS is debounced and held rather than a single-press instant fire |
| Buzzer | Chest pouch, facing outward | Audible warning for STOP/SOS as a secondary channel to haptics | May be too quiet outdoors, or socially undesirable (draws public attention) — needs user testing, not assumed |

## Wearability Constraints Considered (and NOT dismissed)

- **Weight**: 3× HC‑SR04 (~15g each) + ESP32 (~10g) + battery + 2×
  vibration motors + enclosure is estimated in the 150–250g range,
  which is plausible for a chest harness but has not been weighed
  against a real build.
- **Wiring**: six sensor wires (TRIG/ECHO ×3) plus two motor leads and
  a button lead is a non-trivial wiring harness for a worn device;
  strain relief at every connector is required, or connectors will
  fail from repeated movement — not solved here, flagged as a real
  physical-build risk.
- **Battery**: a single LiPo cell sized for a multi-hour walk needs an
  actual current-draw measurement from the physical prototype (three
  continuously-polled HC‑SR04 units plus Wi‑Fi/ESP‑NOW radio use is
  not power-trivial) — no runtime estimate is claimed here.
- **Heat**: ESP32 with Wi‑Fi/ESP‑NOW active can get noticeably warm;
  a chest pouch reduces airflow — needs to be checked against skin
  contact temperature in the physical build, not assumed safe.
- **Vibration**: motor intensity that is noticeable but not painful or
  startling is a calibration question that can only be answered with a
  real motor against real skin — the PWM duty cycle is not even wired
  up in the current firmware (it's simple digitalWrite HIGH/LOW),
  which is itself a gap to close before physical testing.
- **Enclosure**: none designed. A 3D-printed or off-the-shelf project
  box is assumed but not selected, sized, or costed here.
- **Accessibility**: controls (SOS button especially) must be operable
  without sight and without fine motor precision — shape-coding
  (distinct button shape/texture) is recommended but not designed.
- **Safety**: no strap/harness should risk restricting breathing or
  movement, or presenting a strangulation/snag risk — needs a real
  fitting review, ideally with accessibility/occupational-therapy
  input, not just engineering judgement.

## Explicitly Not Decided Here

- Exact strap/harness product or pattern (off-the-shelf modification
  vs custom-made)
- Final enclosure material/manufacturing method
- Cable routing/protection method
- Whether left/right motors are better placed on shoulders vs wrists
  vs waist — shoulders were chosen as a first guess for the reasons
  above, but this is exactly the kind of question the dissertation
  guide demo should raise, not something already settled.
