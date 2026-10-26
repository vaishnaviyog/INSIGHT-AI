/*
 * INSIGHT — Dissertation 1: IoT/WSN Hardware Prototype (Stage 1)
 * -----------------------------------------------------
 * STATUS: SIMULATED (Wokwi) ONLY. Not physically tested.
 *
 * WHAT THIS IS
 *   A minimal ESP32 firmware demonstrating the sensing -> hardware-
 *   local risk classification -> directional haptic feedback pipeline
 *   proposed for the Dissertation 1 wearable extension of INSIGHT.
 *   See docs/DISSERTATION1_ARCHITECTURE_ANALYSIS.md for how this
 *   relates to the existing (software-only) INSIGHT risk engine —
 *   this firmware does NOT reimplement RiskAssessmentService or
 *   AdaptiveRiskEngine. It is a deliberately simpler, hardware-local
 *   prototype decision layer.
 *
 * THIS IS STAGE 1 — EMBEDDED SENSING, NOT A WSN
 *   All three ultrasonic sensors are wired directly to ONE ESP32,
 *   which makes this an embedded/IoT sensing prototype, not a
 *   wireless sensor network —
 *   a WSN implies independently-powered, spatially-distributed,
 *   wirelessly-linked nodes, none of which exist yet. The message
 *   format below (see SensorMessage / logMessage()) is written so a
 *   real Stage 2 wireless node's data would slot into the same
 *   decision logic largely unchanged — see docs/WSN_STAGE2_DESIGN.md
 *   for that future architecture. This file implements Stage 1 only.
 *
 * ELECTRICAL SAFETY (audit fix)
 *   HC-SR04 is powered at 5V (see docs/POWER_ARCHITECTURE.md). Its
 *   ECHO output therefore swings to ~5V, which is NOT safe to feed
 *   directly into an ESP32 GPIO (3.3V logic, not 5V-tolerant). Every
 *   ECHO line in wokwi/diagram.json now passes through a resistor
 *   voltage divider (2.2k / 3.3k, ~3.0V at the GPIO) before reaching
 *   FRONT_ECHO_PIN / LEFT_ECHO_PIN / RIGHT_ECHO_PIN — see
 *   docs/CIRCUIT_CONNECTIONS.md for the exact calculation. This
 *   firmware's GPIO usage is unchanged by that fix (the divider is a
 *   hardware-only change); it is documented here so this file is not
 *   read in isolation from that safety requirement.
 *
 * HAPTIC OUTPUT
 *   Wokwi has no vibration-motor part. LEFT_HAPTIC_LED_PIN and
 *   RIGHT_HAPTIC_LED_PIN are VIRTUAL REPRESENTATIONS of the LEFT and
 *   RIGHT vibration motors — requires physical validation with real
 *   ERM/coin motors before any claim about how they actually feel.
 *   In the physical build, each of these pins drives a MOSFET-based
 *   motor driver stage, NEVER the motor directly — see
 *   docs/CIRCUIT_CONNECTIONS.md "Vibration Motor Driver Stage".
 *
 * SENSOR FAULT HANDLING (audit fix)
 *   A sensor that returns no echo (NAN) is now classified as
 *   RiskLevel::SENSOR_FAULT, not RiskLevel::SAFE — a broken sensor
 *   must not be indistinguishable from a genuinely clear path. A
 *   faulted sensor contributes no directional signal of its own (it
 *   cannot trigger LEFT/RIGHT/STOP by itself), and its fault is
 *   logged separately and shown on the status LED (fast blink) — see
 *   the fault-detection block inside loop() and updateStatusLed()
 *   below. This does NOT make the system fail-safe; it only makes a
 *   failure visible instead of silent.
 *
 * ADAPTIVE FAULT-TOLERANT ZONE REALLOCATION (novel contribution — see
 * docs/NOVELTY_CONTRIBUTION.md for the full writeup and the literature
 * gap it addresses)
 *   Going a step beyond "visible instead of silent": when a sensor
 *   fails, the WARNING threshold of its geometric neighbour(s) widens
 *   by DEGRADED_THRESHOLD_MULTIPLIER (classifyWithCompensation()
 *   below), so the working sensors partially cover the blind spot
 *   left by the failed one, instead of the system's overall
 *   reliability dropping to that of its weakest/failed component.
 *   When this compensation is active and currently detects nothing,
 *   the system enters SystemState::DEGRADED — a distinct slow-pulse
 *   haptic signal (actuate() below) telling the user "reduced but
 *   non-zero coverage," rather than a silent CLEAR output that would
 *   be indistinguishable from full protection. DANGER_DISTANCE_CM is
 *   deliberately NOT widened by compensation — only the earlier
 *   WARNING zone is — so a degraded sensor cannot be made to trigger
 *   STOP on its own, only an earlier, gentler heads-up.
 *
 *   CORRELATED/MULTIPLE-FAULT FALLBACK: compensation above is only
 *   trusted when EXACTLY one sensor has failed (compensationTrusted
 *   in loop()). With 2+ sensors down — plausible on one wearable
 *   where all three sensors share a power rail, mounting, and
 *   acoustic environment, i.e. a correlated rather than independent
 *   failure — a single widened threshold is stretched too thin to
 *   trust with the same confidence as the single-fault case, so
 *   compensation is disabled and the system falls back to the
 *   conservative STOP pattern instead of the gentler DEGRADED one,
 *   UNLESS a genuine direct (non-compensated) reading from whichever
 *   sensor is still healthy says otherwise. See
 *   docs/NOVELTY_CONTRIBUTION.md for the literature finding this
 *   responds to.
 *
 * HOW TO READ THE OUTPUT
 *   Open the Serial Monitor at 115200 baud. Every sensing cycle
 *   prints one MSG line per sensor node (the message a real WSN node
 *   would transmit, plus a sequence number — see SensorMessage),
 *   one FAULT line per faulted sensor (if any), and one DECISION line
 *   (what the central controller/hub decided and why).
 */

// Custom types (RiskLevel, Direction, SensorMessage) live in
// wokwi_types.h, included here — see that file's header comment for
// why: it works around an Arduino build-system quirk with
// auto-generated function prototypes, not a design choice.
#include "wokwi_types.h"

// ----------------------------------------------------------------
// Pin map — see docs/CIRCUIT_CONNECTIONS.md for the full wiring table
// ----------------------------------------------------------------
const uint8_t FRONT_TRIG_PIN = 5;
const uint8_t FRONT_ECHO_PIN = 18;   // via 2.2k/3.3k divider — see docs/CIRCUIT_CONNECTIONS.md
const uint8_t LEFT_TRIG_PIN = 19;
const uint8_t LEFT_ECHO_PIN = 21;    // via 2.2k/3.3k divider
const uint8_t RIGHT_TRIG_PIN = 22;
const uint8_t RIGHT_ECHO_PIN = 23;   // via 2.2k/3.3k divider

const uint8_t LEFT_HAPTIC_LED_PIN = 25;   // virtual rep. of LEFT vibration motor (real build: via MOSFET driver)
const uint8_t RIGHT_HAPTIC_LED_PIN = 26;  // virtual rep. of RIGHT vibration motor (real build: via MOSFET driver)
const uint8_t BUZZER_PIN = 27;
const uint8_t STATUS_LED_PIN = 33;        // debug/status heartbeat AND fault indicator, not haptic
const uint8_t SOS_BUTTON_PIN = 32;        // INPUT_PULLUP, active LOW

// ----------------------------------------------------------------
// Configuration — thresholds are prototype placeholders, NOT derived
// from accessibility research. Centralised here so they can be
// recalibrated later against real HC-SR04 behaviour without hunting
// through the rest of the file. See docs/DISSERTATION1_TEST_PLAN.md.
// ----------------------------------------------------------------
const float SAFE_DISTANCE_CM = 100.0;     // > this: no risk
const float WARNING_DISTANCE_CM = 50.0;   // between this and DANGER: directional warning
const float DANGER_DISTANCE_CM = 25.0;    // <= this: immediate stop

const unsigned long SENSOR_CYCLE_MS = 300;     // time between full sensing cycles
const unsigned long ULTRASONIC_TIMEOUT_US = 25000UL; // ~4.3 m max range guard

// Settling delay between one sensor's echo ending and the next
// sensor's trigger firing. Sensors are
// already triggered strictly sequentially (never simultaneously), so
// this is a secondary precaution against residual acoustic
// reverberation from a just-fired sensor being picked up by the next
// one, plausible given the three sensors sit ~20-30cm apart on one
// harness. 15ms is a conservative, cheap starting value chosen to fit
// comfortably inside the existing 300ms cycle budget (worst case:
// 3 x 25ms timeout + 2 x 15ms settle = ~105ms) — it is NOT derived
// from a physical measurement. Real cross-talk behaviour can only be
// confirmed by physical testing (Wokwi's simulated HC-SR04 has no
// acoustic model at all); tune this value once real hardware exists.
const unsigned long SENSOR_SETTLE_DELAY_MS = 15;

const unsigned long SOS_HOLD_MS = 5000;        // how long the SOS pattern/event lasts
const unsigned long SOS_DEBOUNCE_MS = 250;

// Status LED fault-blink interval — deliberately faster/more
// insistent than either of the normal heartbeat intervals below, so
// a sensor fault is visually distinct from ordinary CLEAR/active
// heartbeat blinking, not just "the LED is on."
const unsigned long FAULT_BLINK_MS = 80;

// Adaptive fault-tolerant zone reallocation (see header comment and
// docs/NOVELTY_CONTRIBUTION.md). 1.5x is a reasoned starting point —
// wide enough to meaningfully extend coverage, conservative enough
// not to flood the user with warnings for anything merely "nearby" —
// NOT derived from physical measurement; a candidate for
// recalibration once real HC-SR04 noise/coverage data exists, same
// status as every other threshold in this section.
const float DEGRADED_THRESHOLD_MULTIPLIER = 1.5;

// DEGRADED's haptic signature: a slow synchronized double-pulse,
// deliberately distinct from both STOP (continuous) and SOS (fast
// ~200ms alternation) — see actuate(). A gentle heads-up, not an
// alarm, which is also why DEGRADED never drives the buzzer. 300ms
// ON (not the originally-drafted 150ms) — long enough to be reliably
// perceptible as a real pulse rather than a flicker, a correction
// made after the automated test scenario made the original 150ms
// window's tightness concrete, not merely a guess.
const unsigned long DEGRADED_PULSE_ON_MS = 300;
const unsigned long DEGRADED_PULSE_PERIOD_MS = 1000;

// CLOSING-SPEED ESCALATION (safety gap-fill, NOT claimed as novel —
// see docs/NOVELTY_CONTRIBUTION.md §10). The normal decision chain
// only looks at a sensor's CURRENT absolute distance against fixed
// thresholds, so something closing in quickly — another pedestrian,
// a cyclist — gets no response until it happens to cross DANGER_CM,
// by which point reaction time may already be too short. This adds a
// second, independent signal: if a sensor's reading drops by at least
// CLOSING_RATE_DANGER_CM between two CONSECUTIVE cycles (SENSOR_CYCLE_MS
// apart) while still within CLOSING_RATE_ZONE_CM, that sensor escalates
// straight to STOP — bypassing the normal WARNING confirmation delay
// entirely, the same way DANGER does, since a fast rate-of-closure is
// itself already a stronger signal than one raw reading. 40cm/cycle is
// roughly 133cm/s — brisk jogging speed — a reasoned placeholder, not
// derived from real human-approach-speed data (no physical testing
// exists for this, same caveat as every other threshold here). This
// does NOT reconstruct true velocity/physics — it is a simple
// consecutive-reading delta, deliberately kept this simple so it is
// easy to reason about on a prototype that has never been physically
// tested, consistent with this project's stated hysteresis philosophy.
const float CLOSING_RATE_DANGER_CM = 40.0;
const float CLOSING_RATE_ZONE_CM = 150.0; // ignore closure far outside any zone the user could react within

bool isClosingFast(float previousCm, float currentCm) {
  if (isnan(previousCm) || isnan(currentCm)) return false; // never trigger from/into a fault reading
  if (currentCm > CLOSING_RATE_ZONE_CM) return false;      // still far enough away to not matter yet
  return (previousCm - currentCm) >= CLOSING_RATE_DANGER_CM;
}

// ----------------------------------------------------------------
// Message format — mirrors what a real WSN sensor node would
// transmit (see docs/WSN_STAGE2_DESIGN.md for the finalised Stage 2
// wire format). Kept deliberately small. Types (RiskLevel, Direction,
// SensorMessage) are defined in wokwi_types.h, included above.
//
// NOTE ON riskLevel: in this Stage 1, single-board prototype,
// classification happens centrally (right here, in classify()) for
// every "node" regardless. docs/WSN_STAGE2_DESIGN.md documents the
// decision that a real Stage 2 wireless node would transmit only
// NODE_ID/SENSOR_TYPE/DISTANCE/DIRECTION/TIMESTAMP/SEQUENCE_NUMBER —
// NOT a pre-computed risk level — with classification staying
// centralised at the hub (one place that knows the thresholds, not
// N places that must all agree). The riskLevel field here exists
// purely for convenient Serial logging in this single-board
// simulation and is explicitly NOT part of the proposed Stage 2 wire
// format.
// ----------------------------------------------------------------
const char *riskLevelName(RiskLevel r) {
  switch (r) {
    case RiskLevel::SAFE: return "SAFE";
    case RiskLevel::WARNING: return "WARNING";
    case RiskLevel::DANGER: return "DANGER";
    case RiskLevel::SENSOR_FAULT: return "SENSOR_FAULT";
  }
  return "UNKNOWN";
}

const char *directionName(Direction d) {
  switch (d) {
    case Direction::LEFT: return "LEFT";
    case Direction::CENTER: return "CENTER";
    case Direction::RIGHT: return "RIGHT";
    default: return "NONE";
  }
}

void logMessage(const SensorMessage &msg) {
  Serial.print("MSG node=");
  Serial.print(msg.nodeId);
  Serial.print(" type=");
  Serial.print(msg.sensorType);
  Serial.print(" distance_cm=");
  if (isnan(msg.distanceCm)) {
    Serial.print("NA");
  } else {
    Serial.print(msg.distanceCm, 1);
  }
  Serial.print(" risk=");
  Serial.print(riskLevelName(msg.riskLevel));
  Serial.print(" direction=");
  Serial.print(directionName(msg.direction));
  Serial.print(" seq=");
  Serial.print(msg.sequenceNumber);
  Serial.print(" t_ms=");
  Serial.println(msg.timestampMs);
}

// ----------------------------------------------------------------
// SystemState is defined in wokwi_types.h (same build-order reason as
// the other custom types there).
// ----------------------------------------------------------------
SystemState currentState = SystemState::CLEAR;
bool faultActive = false; // true if any sensor was SENSOR_FAULT on the most recent cycle

// ----------------------------------------------------------------
// HC-SR04 read helper. Blocking (pulseIn) is a known, accepted
// simplification for this prototype — see
// docs/SIMULATION_LIMITATIONS.md. Returns NAN on timeout/no echo.
// ----------------------------------------------------------------
float readDistanceCm(uint8_t trigPin, uint8_t echoPin) {
  digitalWrite(trigPin, LOW);
  delayMicroseconds(2);
  digitalWrite(trigPin, HIGH);
  delayMicroseconds(10);
  digitalWrite(trigPin, LOW);

  unsigned long durationUs = pulseIn(echoPin, HIGH, ULTRASONIC_TIMEOUT_US);
  if (durationUs == 0) {
    return NAN; // no echo within timeout — treat as a fault, not "clear"; see classify()
  }
  return durationUs / 58.0; // standard HC-SR04 us-to-cm conversion
}

// compensate=true widens the WARNING boundary (not DANGER) by
// DEGRADED_THRESHOLD_MULTIPLIER — see the header comment "ADAPTIVE
// FAULT-TOLERANT ZONE REALLOCATION" and docs/NOVELTY_CONTRIBUTION.md.
// A sensor's own NAN always returns SENSOR_FAULT regardless of
// compensate — a failed sensor cannot compensate for itself.
RiskLevel classifyWithCompensation(float distanceCm, bool compensate) {
  if (isnan(distanceCm)) return RiskLevel::SENSOR_FAULT; // no reading -> cannot assert risk OR safety
  if (distanceCm <= DANGER_DISTANCE_CM) return RiskLevel::DANGER;
  float effectiveWarningCm = compensate ? (WARNING_DISTANCE_CM * DEGRADED_THRESHOLD_MULTIPLIER) : WARNING_DISTANCE_CM;
  if (distanceCm <= effectiveWarningCm) return RiskLevel::WARNING;
  return RiskLevel::SAFE;
}

// Uncompensated classification — used where no neighbour-fault
// context applies (kept as a thin wrapper so the common case reads
// exactly as it did before this feature was added).
RiskLevel classify(float distanceCm) {
  return classifyWithCompensation(distanceCm, false);
}

// ----------------------------------------------------------------
// TEMPORAL WARNING CONFIRMATION — addresses a specific, still-open
// limitation named by Gao et al. (2025, Nature Communications), the
// strongest paper reviewed for this dissertation: their own user
// survey identified "alert fatigue" from oversensitive single-mode
// detection, and "refining detection algorithms to reduce false
// positives" is listed as THEIR future work, not solved there either.
// See docs/NOVELTY_CONTRIBUTION.md §9.
//
// NOT claimed as novel: N-of-M temporal confirmation/hysteresis is one
// of the oldest techniques in embedded sensing, and was in fact
// explicitly deferred earlier in this project's own history (classified
// MINOR, "not worth over-engineering before physical testing shows
// it's needed"). What changed: the deep-research literature pass
// surfaced a specific, named, still-unsolved limitation in the closest
// paper that this directly answers, which is a better reason to add it
// than a general engineering instinct that it "might help later."
//
// Deliberately asymmetric, for safety: ONLY a WARNING-level reading is
// delayed pending confirmation — DANGER, SENSOR_FAULT, and a return to
// SAFE all pass through on the very next cycle, completely unfiltered.
// An actual close-range obstacle must never wait to be "confirmed"
// before the user is stopped; the oversensitivity/alert-fatigue problem
// Gao et al. describe is specifically about the more moderate WARNING
// case, not DANGER. A sensor's raw classification (used for the MSG/
// FAULT Serial lines and faultActive) is NEVER altered by this filter —
// only the value fed into the DECISION layer below is; this keeps the
// raw per-cycle sensor log fully transparent even when the haptic
// output doesn't react to a single transient blip.
const int WARNING_CONFIRM_CYCLES = 2; // reasoned placeholder, not physically tuned — see docs/DISSERTATION1_TEST_PLAN.md

RiskLevel confirmWarning(RiskLevel raw, int &warningStreak) {
  if (raw != RiskLevel::WARNING) {
    warningStreak = 0;
    return raw; // SAFE / DANGER / SENSOR_FAULT: always immediate, never delayed
  }
  warningStreak++;
  return (warningStreak >= WARNING_CONFIRM_CYCLES) ? RiskLevel::WARNING : RiskLevel::SAFE;
}

// ----------------------------------------------------------------
// SOS button state (debounced, edge-triggered, non-blocking)
// ----------------------------------------------------------------
bool sosActive = false;
unsigned long sosStartedAtMs = 0;
int lastRawButtonState = HIGH;
unsigned long lastButtonChangeMs = 0;

void pollSosButton() {
  int raw = digitalRead(SOS_BUTTON_PIN);
  unsigned long now = millis();

  if (raw != lastRawButtonState && (now - lastButtonChangeMs) > SOS_DEBOUNCE_MS) {
    lastButtonChangeMs = now;
    lastRawButtonState = raw;
    if (raw == LOW && !sosActive) { // active LOW (INPUT_PULLUP)
      sosActive = true;
      sosStartedAtMs = now;
      SensorMessage msg = {"NODE_SOS", "BUTTON", NAN, RiskLevel::DANGER, Direction::NONE, now, 0};
      logMessage(msg);
      Serial.println("EVENT sos_triggered — this is the event a physical build would "
                      "forward to the companion phone app / EmergencyService. "
                      "No SMS/call is sent from this prototype.");
    }
    // AUDIT TEST CASE: if the button is held through the entire
    // SOS_HOLD_MS window (see the auto-expiry check below), sosActive
    // becomes false while raw is still LOW. Because re-triggering
    // requires a fresh HIGH->LOW EDGE (the `raw != lastRawButtonState`
    // check above), holding the button down will NOT re-trigger SOS —
    // a release-then-fresh-press is required. This is intentional
    // (avoids continuous re-triggering while held) and is covered by
    // docs/DISSERTATION1_TEST_PLAN.md tests 15/16.
  }

  if (sosActive && (now - sosStartedAtMs) >= SOS_HOLD_MS) {
    sosActive = false;
    Serial.println("EVENT sos_hold_elapsed — prototype SOS display ends, resuming obstacle detection.");
  }
}

// ----------------------------------------------------------------
// Haptic + buzzer actuation for each SystemState. See
// docs/CIRCUIT_CONNECTIONS.md and README.md "Haptic Feedback" for
// the documented vibration-pattern table this implements.
// ----------------------------------------------------------------
unsigned long lastPatternToggleMs = 0;
bool patternPhaseOn = false;

unsigned long lastDegradedPulseMs = 0;
bool degradedPulseOn = false;

void actuate(SystemState state) {
  unsigned long now = millis();

  switch (state) {
    case SystemState::CLEAR:
      digitalWrite(LEFT_HAPTIC_LED_PIN, LOW);
      digitalWrite(RIGHT_HAPTIC_LED_PIN, LOW);
      digitalWrite(BUZZER_PIN, LOW);
      break;

    case SystemState::LEFT_WARNING:
      digitalWrite(LEFT_HAPTIC_LED_PIN, HIGH);
      digitalWrite(RIGHT_HAPTIC_LED_PIN, LOW);
      digitalWrite(BUZZER_PIN, LOW);
      break;

    case SystemState::RIGHT_WARNING:
      digitalWrite(LEFT_HAPTIC_LED_PIN, LOW);
      digitalWrite(RIGHT_HAPTIC_LED_PIN, HIGH);
      digitalWrite(BUZZER_PIN, LOW);
      break;

    case SystemState::STOP:
      digitalWrite(LEFT_HAPTIC_LED_PIN, HIGH);
      digitalWrite(RIGHT_HAPTIC_LED_PIN, HIGH);
      digitalWrite(BUZZER_PIN, HIGH); // continuous tone while DANGER persists
      break;

    case SystemState::SOS:
      // Distinct alternating pattern (LEFT/RIGHT/buzzer toggle together
      // every 200ms) so it is not confused with STOP's steady-on
      // pattern. This is a simple alternating pulse, not real Morse
      // code — documented here rather than overstated as such.
      if (now - lastPatternToggleMs >= 200) {
        lastPatternToggleMs = now;
        patternPhaseOn = !patternPhaseOn;
      }
      digitalWrite(LEFT_HAPTIC_LED_PIN, patternPhaseOn ? HIGH : LOW);
      digitalWrite(RIGHT_HAPTIC_LED_PIN, patternPhaseOn ? HIGH : LOW);
      digitalWrite(BUZZER_PIN, patternPhaseOn ? HIGH : LOW);
      break;

    case SystemState::DEGRADED:
      // Slow synchronized double-pulse (150ms on, 1000ms period) —
      // a gentle, non-alarming heads-up that coverage is reduced but
      // a neighbouring sensor is compensating; never drives the
      // buzzer (see header comment and docs/NOVELTY_CONTRIBUTION.md).
      // Deliberately far slower than SOS's ~200ms alternation so the
      // two are never confusable.
      if (now - lastDegradedPulseMs >= DEGRADED_PULSE_PERIOD_MS) {
        lastDegradedPulseMs = now;
        degradedPulseOn = true;
      } else if (degradedPulseOn && (now - lastDegradedPulseMs >= DEGRADED_PULSE_ON_MS)) {
        degradedPulseOn = false;
      }
      digitalWrite(LEFT_HAPTIC_LED_PIN, degradedPulseOn ? HIGH : LOW);
      digitalWrite(RIGHT_HAPTIC_LED_PIN, degradedPulseOn ? HIGH : LOW);
      digitalWrite(BUZZER_PIN, LOW);
      break;
  }
}

// ----------------------------------------------------------------
// Status LED: normally a slow/fast heartbeat so a reviewer can see
// the firmware is alive. When faultActive is true, it instead blinks
// rapidly (FAULT_BLINK_MS) as a distinct fault indicator — audit fix,
// see header comment "SENSOR FAULT HANDLING". Debug/status only —
// not part of the haptic feedback contract.
// ----------------------------------------------------------------
unsigned long lastHeartbeatMs = 0;
bool heartbeatOn = false;

void updateStatusLed() {
  unsigned long now = millis();
  unsigned long interval;
  if (faultActive) {
    interval = FAULT_BLINK_MS;
  } else {
    interval = (currentState == SystemState::CLEAR) ? 1000 : 250;
  }
  if (now - lastHeartbeatMs >= interval) {
    lastHeartbeatMs = now;
    heartbeatOn = !heartbeatOn;
    digitalWrite(STATUS_LED_PIN, heartbeatOn ? HIGH : LOW);
  }
}

// ----------------------------------------------------------------
unsigned long lastCycleMs = 0;
uint32_t cycleSequenceNumber = 0;

void setup() {
  Serial.begin(115200);
  delay(200);

  pinMode(FRONT_TRIG_PIN, OUTPUT);
  pinMode(FRONT_ECHO_PIN, INPUT);
  pinMode(LEFT_TRIG_PIN, OUTPUT);
  pinMode(LEFT_ECHO_PIN, INPUT);
  pinMode(RIGHT_TRIG_PIN, OUTPUT);
  pinMode(RIGHT_ECHO_PIN, INPUT);

  pinMode(LEFT_HAPTIC_LED_PIN, OUTPUT);
  pinMode(RIGHT_HAPTIC_LED_PIN, OUTPUT);
  pinMode(BUZZER_PIN, OUTPUT);
  pinMode(STATUS_LED_PIN, OUTPUT);
  pinMode(SOS_BUTTON_PIN, INPUT_PULLUP);

  Serial.println("INSIGHT Dissertation 1 — Stage 1 embedded sensing prototype boot OK (SIMULATED).");
  Serial.println("This is NOT a WSN — see README.md sec 5 for the terminology distinction.");
  Serial.println("This firmware is a simplified hardware-local risk layer.");
  Serial.println("It does NOT reproduce INSIGHT's RiskAssessmentService / AdaptiveRiskEngine.");
}

void loop() {
  pollSosButton();

  unsigned long now = millis();
  if (now - lastCycleMs >= SENSOR_CYCLE_MS) {
    lastCycleMs = now;
    cycleSequenceNumber++;

    // Sequential triggering (never simultaneous) plus an explicit
    // settling delay between sensors — see SENSOR_SETTLE_DELAY_MS.
    float frontCm = readDistanceCm(FRONT_TRIG_PIN, FRONT_ECHO_PIN);
    delay(SENSOR_SETTLE_DELAY_MS);
    float leftCm = readDistanceCm(LEFT_TRIG_PIN, LEFT_ECHO_PIN);
    delay(SENSOR_SETTLE_DELAY_MS);
    float rightCm = readDistanceCm(RIGHT_TRIG_PIN, RIGHT_ECHO_PIN);

    // Raw fault status first (before classification), so each
    // sensor's compensation flag reflects its NEIGHBOUR's health, not
    // its own — see "ADAPTIVE FAULT-TOLERANT ZONE REALLOCATION" above.
    // Front's neighbours are left+right (either failing widens front);
    // each side sensor's one neighbour, for this purpose, is front
    // (the centrally-mounted sensor, the best available approximation
    // without true geometric sensor fusion — see
    // docs/NOVELTY_CONTRIBUTION.md for why this mapping was chosen).
    bool frontFaulted = isnan(frontCm);
    bool leftFaulted = isnan(leftCm);
    bool rightFaulted = isnan(rightCm);
    int faultCount = (frontFaulted ? 1 : 0) + (leftFaulted ? 1 : 0) + (rightFaulted ? 1 : 0);

    // Compensation is only trusted when EXACTLY one sensor has failed.
    // Literature finding (docs/NOVELTY_CONTRIBUTION.md §6, citing
    // Muzychenko 2025): simple fault-tolerance schemes like this one
    // "lose effectiveness with ... multiple correlated faults" — and
    // three sensors sharing one wearable's power rail, mounting, and
    // acoustic environment are a plausible correlated-fault scenario,
    // not an independent one. With 2+ sensors down, a single widened
    // threshold is stretched too thin to be presented with the same
    // confidence as the single-fault case, so compensation is disabled
    // entirely rather than silently applied anyway — see the
    // faultCount>=2 fail-safe branch in the decision logic below.
    bool compensationTrusted = (faultCount == 1);

    RiskLevel frontRisk = classifyWithCompensation(frontCm, compensationTrusted && (leftFaulted || rightFaulted));
    RiskLevel leftRisk = classifyWithCompensation(leftCm, compensationTrusted && frontFaulted);
    RiskLevel rightRisk = classifyWithCompensation(rightCm, compensationTrusted && frontFaulted);

    // Temporal WARNING confirmation (see confirmWarning() above) — applied
    // ONLY to what the decision layer acts on. frontRisk/leftRisk/rightRisk
    // above stay RAW and are what the MSG/FAULT Serial lines and
    // faultActive below use, so a transient blip is still visible in the
    // log even on a cycle where the haptic output doesn't react to it.
    static int frontWarningStreak = 0, leftWarningStreak = 0, rightWarningStreak = 0;
    RiskLevel frontRiskConfirmed = confirmWarning(frontRisk, frontWarningStreak);
    RiskLevel leftRiskConfirmed = confirmWarning(leftRisk, leftWarningStreak);
    RiskLevel rightRiskConfirmed = confirmWarning(rightRisk, rightWarningStreak);

    // Closing-speed escalation (see CLOSING_RATE_DANGER_CM above) —
    // compared against the PREVIOUS cycle's raw reading, captured
    // before this cycle's value overwrites it below.
    static float frontPrevCm = NAN, leftPrevCm = NAN, rightPrevCm = NAN;
    bool frontClosingFast = isClosingFast(frontPrevCm, frontCm);
    bool leftClosingFast = isClosingFast(leftPrevCm, leftCm);
    bool rightClosingFast = isClosingFast(rightPrevCm, rightCm);
    frontPrevCm = frontCm;
    leftPrevCm = leftCm;
    rightPrevCm = rightCm;

    SensorMessage frontMsg = {"NODE_FRONT", "ULTRASONIC", frontCm, frontRisk, Direction::CENTER, now, cycleSequenceNumber};
    SensorMessage leftMsg = {"NODE_LEFT", "ULTRASONIC", leftCm, leftRisk, Direction::LEFT, now, cycleSequenceNumber};
    SensorMessage rightMsg = {"NODE_RIGHT", "ULTRASONIC", rightCm, rightRisk, Direction::RIGHT, now, cycleSequenceNumber};
    logMessage(frontMsg);
    logMessage(leftMsg);
    logMessage(rightMsg);

    // ---- Fault detection/logging (audit fix — see header comment
    // "SENSOR FAULT HANDLING"). A faulted sensor is reported here,
    // distinctly from the MSG lines above, and drives the status LED
    // fault-blink in updateStatusLed(). A fault itself still can
    // never directly trigger LEFT/RIGHT/STOP (SENSOR_FAULT is a
    // distinct enum value from WARNING/DANGER) — but, as of the
    // adaptive-compensation feature above, it DOES now (a) widen a
    // neighbour's effective WARNING threshold via
    // classifyWithCompensation(), and (b) drive the new DEGRADED
    // haptic state below when nothing else is currently detected.
    // Both are deliberate, documented exceptions to the original
    // "fault never reaches the haptic motors" rule — see
    // docs/NOVELTY_CONTRIBUTION.md for why.
    faultActive = (frontRisk == RiskLevel::SENSOR_FAULT) ||
                  (leftRisk == RiskLevel::SENSOR_FAULT) ||
                  (rightRisk == RiskLevel::SENSOR_FAULT);
    if (frontRisk == RiskLevel::SENSOR_FAULT) Serial.println("FAULT node=NODE_FRONT reason=no_echo_within_timeout");
    if (leftRisk == RiskLevel::SENSOR_FAULT) Serial.println("FAULT node=NODE_LEFT reason=no_echo_within_timeout");
    if (rightRisk == RiskLevel::SENSOR_FAULT) Serial.println("FAULT node=NODE_RIGHT reason=no_echo_within_timeout");

    // ---- Decision logic (fixed precedence, not a weighted blend —
    // same philosophy as NavigationDecisionEngine, deliberately much
    // simpler here). See DISSERTATION1_ARCHITECTURE_ANALYSIS.md §6.
    // SENSOR_FAULT never equals DANGER/WARNING, so a faulted sensor
    // is automatically excluded from every branch below — it cannot
    // trigger a directional warning, and cannot be mistaken for SAFE
    // either, since SAFE is a distinct enum value from SENSOR_FAULT.
    SystemState decided;
    const char *reason;

    if (sosActive) {
      decided = SystemState::SOS;
      reason = "SOS button active";
    } else if (frontRiskConfirmed == RiskLevel::DANGER) {
      decided = SystemState::STOP;
      reason = "front sensor DANGER (immediate obstacle ahead)";
    } else if (leftRiskConfirmed == RiskLevel::DANGER) {
      // Bug fix: the original precedence chain only ever checked
      // frontRisk for DANGER — a DANGER-level (<=25cm) reading from
      // the LEFT or RIGHT sensor alone fell through every branch
      // below (WARNING != DANGER, so it never matched the
      // leftRisk==WARNING/rightRisk==WARNING checks either) all the
      // way to CLEAR/DEGRADED, producing no warning at all for an
      // obstacle as close as the front-DANGER case already treats as
      // an immediate stop. Found while designing the dual-fault test
      // below, confirmed by direct code search, fixed here — same
      // severity as front DANGER deserves the same STOP response,
      // regardless of which of the three sensors detected it.
      decided = SystemState::STOP;
      reason = "left sensor DANGER (immediate obstacle ahead)";
    } else if (rightRiskConfirmed == RiskLevel::DANGER) {
      decided = SystemState::STOP;
      reason = "right sensor DANGER (immediate obstacle ahead)";
    } else if (frontClosingFast || leftClosingFast || rightClosingFast) {
      // Closing-speed escalation (see CLOSING_RATE_DANGER_CM above) —
      // checked after direct DANGER (a genuine DANGER reading is
      // always at least this urgent) but before the WARNING checks,
      // so something closing in fast gets STOP immediately rather
      // than waiting out confirmWarning()'s 2-cycle delay or sitting
      // at a plain WARNING while it's still outside the fixed
      // DANGER_DISTANCE_CM boundary.
      decided = SystemState::STOP;
      reason = "rapid closing speed detected on at least one sensor; escalated ahead of normal threshold crossing";
    } else if (leftRiskConfirmed == RiskLevel::WARNING && rightRiskConfirmed == RiskLevel::WARNING) {
      decided = SystemState::STOP;
      reason = "both sides in WARNING range (narrow passage / closing on both sides)";
    } else if (leftRiskConfirmed == RiskLevel::WARNING) {
      decided = SystemState::LEFT_WARNING;
      reason = "left sensor WARNING";
    } else if (rightRiskConfirmed == RiskLevel::WARNING) {
      decided = SystemState::RIGHT_WARNING;
      reason = "right sensor WARNING";
    } else if (faultCount >= 2) {
      // Correlated/multiple-fault fail-safe (docs/NOVELTY_CONTRIBUTION.md
      // §6). Reached only if no DIRECT (non-compensated) DANGER/WARNING
      // fired above — a genuine reading from whichever sensor is still
      // healthy always takes precedence over this branch, since real
      // sensor data is trustworthy regardless of how many OTHER sensors
      // have failed. This branch exists for the remaining case: 2+
      // sensors down, compensation deliberately disabled
      // (compensationTrusted above), and nothing dangerous detected by
      // the one sensor left — i.e. coverage is now severe enough that
      // presenting the gentle DEGRADED pulse would overstate confidence
      // in a reading from a single uncompensated sensor. Collapses to
      // the same conservative STOP pattern as a genuine DANGER reading,
      // deliberately reusing the existing haptic state rather than
      // adding a new one.
      decided = SystemState::STOP;
      reason = "2+ sensors faulted simultaneously; compensation untrustworthy under correlated faults, fail-safe engaged";
    } else if (faultActive) {
      // Novel branch — see header comment "ADAPTIVE FAULT-TOLERANT
      // ZONE REALLOCATION" and docs/NOVELTY_CONTRIBUTION.md. Reached
      // only when no SOS/DANGER/WARNING condition fired even with
      // compensation applied: nothing is currently detected, but
      // coverage is reduced, so the user is told that explicitly
      // instead of receiving a CLEAR output indistinguishable from
      // full protection.
      decided = SystemState::DEGRADED;
      reason = "sensor fault present; neighbour threshold widened, no obstacle currently detected";
    } else {
      decided = SystemState::CLEAR;
      reason = "no sensor within warning/danger range";
    }

    // On a fresh transition INTO DEGRADED, restart its pulse phase so
    // the user gets an immediate ON signal the moment coverage
    // becomes reduced — same immediate-feedback principle SOS already
    // uses (sosStartedAtMs/patternPhaseOn above), rather than waiting
    // on whatever point of its boot-aligned 1000ms cycle happens to
    // be in progress. Without this, DEGRADED's first appearance could
    // silently coincide with its own OFF phase for up to ~1000ms.
    if (decided == SystemState::DEGRADED && currentState != SystemState::DEGRADED) {
      lastDegradedPulseMs = now;
      degradedPulseOn = true;
    }

    currentState = decided;

    Serial.print("DECISION state=");
    switch (decided) {
      case SystemState::CLEAR: Serial.print("CLEAR"); break;
      case SystemState::LEFT_WARNING: Serial.print("LEFT"); break;
      case SystemState::RIGHT_WARNING: Serial.print("RIGHT"); break;
      case SystemState::STOP: Serial.print("STOP"); break;
      case SystemState::SOS: Serial.print("SOS"); break;
      case SystemState::DEGRADED: Serial.print("DEGRADED"); break;
    }
    Serial.print(" reason=\"");
    Serial.print(reason);
    Serial.print("\" fault=");
    Serial.println(faultActive ? "true" : "false");
  }

  // SOS state, once triggered, overrides obstacle state visually
  // until its hold period elapses, even between sensing cycles.
  actuate(sosActive ? SystemState::SOS : currentState);
  updateStatusLed();
}
