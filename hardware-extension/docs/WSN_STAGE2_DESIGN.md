# Stage 2 — Future Wireless Sensor Network Extension

Status: THEORETICALLY PROPOSED. **Nothing in this document is built,
simulated, or tested.** No wireless hardware exists yet. This document
exists so Stage 2 has a concrete, minimal, reviewable design *before*
any of it is built.

## 1. Why Stage 2 exists, and why it is scoped this small

Stage 1 (this workspace's simulated/wired prototype — three ultrasonic
sensors on one chest-worn ESP32) is **not** a WSN: every sensor is
~20–30cm from the hub, and a wired connection between co-located
sensors is simpler, cheaper, and more reliable than a radio link for
no corresponding benefit (see README.md §5). Building three fully
independent wireless nodes for sensors that never leave arm's reach of
each other would be complexity added to *look like* a WSN rather than
to *be* one.

**Stage 2 therefore adds exactly one genuinely spatially-separated
wireless node — not three.** A cane-tip-mounted sensor is the
motivating example throughout this document: it is physically
separated from the chest hub by a moving joint (the user's arm), which
a wired connection cannot practically cross, making wireless the
correct engineering choice for this one node specifically, not a
default applied to sensors that didn't need it.

## 2. Stage 2 architecture

```
Cane-tip node (ESP32 + 1 ultrasonic/IR sensor, own battery)
        │  ESP-NOW
        ▼
Chest hub (ESP32 — same board Stage 1 already validates)
        │  (front/left/right ultrasonic, still wired, unchanged from Stage 1)
        ▼
Central decision logic (extended, not replaced — see §5)
        │
        ▼
Haptic feedback (unchanged from Stage 1)
```

- **Topology**: star (one wireless node → one hub). No mesh, no
  multi-hop, no peer-to-peer — not justified at this scale (audit §2).
- **Transport**: ESP‑NOW, chosen over Wi‑Fi/MQTT because it needs no
  access point or broker (the wearable must work anywhere outdoors),
  and over BLE because both ends are already ESP32 (native ESP‑NOW
  support, lower implementation overhead than a BLE GATT service for
  this specific link). BLE remains the better choice specifically
  *if and when* a direct phone-side bridge is designed (see §7) —
  that is a separate, still-open decision, not resolved here.

## 3. Message format (finalised for Stage 2)

Per the audit's review of the original 6-field design, **RISK_LEVEL is
dropped from the wire format** — classification stays centralised at
the hub (the one place that owns the SAFE/WARNING/DANGER thresholds),
rather than duplicated per-node where thresholds could drift out of
sync. **SEQUENCE_NUMBER is added**, enabling packet-loss measurement,
which the original design lacked.

| Field | Type | Notes |
|---|---|---|
| `NODE_ID` | string | e.g. `NODE_CANE` |
| `SENSOR_TYPE` | string | e.g. `ULTRASONIC` |
| `DISTANCE` | float (cm) | raw measurement only — no pre-classification |
| `DIRECTION` | enum | `LEFT` / `CENTER` / `RIGHT` / `NONE` — fixed per node's mounting, same convention Stage 1 already uses |
| `TIMESTAMP` | uint32 | **node-local** `millis()` since that node's own boot — explicitly NOT synchronized against the hub's clock or any other node's. Do not compare timestamps numerically across nodes without accounting for this. If cross-node timing ever matters, that requires an explicit sync mechanism, which is out of scope for Stage 2's first version. |
| `SEQUENCE_NUMBER` | uint8 or uint16 | increments once per message from that node; the hub tracks the last-seen value per node and reports a gap as (probable) packet loss |

This mirrors Stage 1's `SensorMessage` struct in `wokwi/main.ino`
closely by design (same field names/spirit), specifically so the hub's
existing per-node classification logic (`classify()`) can be reused
almost unchanged — the hub would call `classify(msg.distanceCm)` on an
arriving wireless message exactly as it already does today on a
locally-read value.

## 4. What is deliberately NOT included in Stage 2 v1

Per the audit's "do not overengineer the first physical prototype"
guidance:

- **No application-level acknowledgement/retry protocol.** ESP‑NOW
  already exposes a send-callback at the driver level; a full
  ACK/retry scheme is real complexity with limited payoff for a
  1-node link. Packet loss is measured passively via sequence-number
  gaps instead of actively prevented.
- **No duplicate-packet suppression.** Unlikely to occur without a
  retry loop generating them; sequence numbers make any duplicate
  detectable after the fact if it ever happens.
- **No time synchronization.** Not needed for a star topology where
  the hub simply acts on each node's most recent message.
- **No RSSI logging.** Could be added cheaply later as a bonus
  signal-quality metric if ESP‑NOW exposes it without extra work, but
  is not a Stage 2 v1 requirement.
- **No mesh/multi-hop routing.** Not justified below ~4 nodes.

## 5. Node timeout (hub-side design, not yet implemented — no wireless node exists to time out)

The hub must distinguish **"a valid recent message arrived"** from
**"no recent message has arrived"** — the second case must NOT be
silently treated as SAFE, for the same reason Stage 1's NAN→SAFE
fallback was flagged as a design risk in the audit (§1.B) and fixed to
`SENSOR_FAULT` in Stage 1's firmware.

- **Design**: the hub records `lastSeenMs` per known `NODE_ID`. If
  `millis() - lastSeenMs > NODE_TIMEOUT_MS`, that node's most recent
  reading is treated as `SENSOR_FAULT` (or a Stage‑2-specific
  `NODE_UNREACHABLE`, TBD when implemented), the same way Stage 1
  already treats a local NAN reading — excluded from directional
  decisions, logged distinctly, and shown on the status indicator.
- **Suggested starting value**: `NODE_TIMEOUT_MS` = a small integer
  multiple (e.g. 3×) of the wireless node's own expected send
  interval — configurable, not hardcoded, mirroring how Stage 1's
  thresholds are all named constants. The exact multiple is a
  judgement call to be tuned once real message-loss behaviour is
  observed physically; no specific number is claimed as correct here.
- **Why this isn't implemented in Stage 1's firmware today**: there is
  no wireless node yet to time out — implementing this now would be
  untestable dead code. It is documented here so the hub-side
  extension is a known, planned change, not a surprise, once the §2
  cane-tip node exists.

## 6. Metrics Stage 2 is specifically for

These are the metrics that **cannot** be measured without Stage 2
existing physically:

- Wireless message latency (send → hub receipt)
- Packet delivery ratio / loss rate (via `SEQUENCE_NUMBER` gaps)
- Node-timeout/failure response behaviour (deliberately power off the
  cane-tip node mid-test and observe the hub's fallback)

No numbers for any of these are claimed anywhere in this workspace —
this document defines how they *would* be measured once Stage 2 is
built, not what the results are.

## 7. Explicitly still open (not designed here)

- **Phone bridge**: whether/how the hub should ever forward events to
  INSIGHT's `IEmergencySignalSource` on the phone — still an open
  question per `docs/DISSERTATION1_ARCHITECTURE_ANALYSIS.md` §8, not
  resolved by this document. If pursued, BLE (native to both ESP32 and
  the phone) is the more likely transport for *that specific link*,
  separate from the ESP‑NOW cane-tip link this document defines.
- **Cane-tip node's physical ruggedness** (ground impact, weather) —
  flagged in the audit §12 as a materially different engineering
  problem from chest-mounted sensor placement; not solved here.
- **Whether a 2nd wireless node is ever justified** — only if physical
  testing of the 1-node version demonstrates a concrete need, per the
  audit's "do not scale until physical testing shows it's needed"
  principle applied throughout this workspace.
