// Shared type definitions for main.ino, split into their own header.
//
// WHY THIS FILE EXISTS (build-fix, not a design change): the Arduino
// build system auto-generates forward declarations for every function
// in the .ino file and inserts them immediately after the last
// #include at the top of the file — BEFORE any code that follows in
// the .ino itself, including custom enum/struct definitions further
// down. A function like `logMessage(const SensorMessage &msg)` then
// gets a hoisted prototype that references `SensorMessage` before
// that type has been declared anywhere yet, which fails to compile
// ("'SensorMessage' does not name a type"). Defining these types in a
// header and #include-ing it at the top of main.ino (before the
// hoisting point) avoids the problem, because #include is resolved
// textually ahead of where the generated prototypes get inserted.
// This file changes nothing about program behaviour — same types,
// same fields, same logic.
#pragma once

#include <stdint.h>

enum class RiskLevel : uint8_t { SAFE, WARNING, DANGER, SENSOR_FAULT };
enum class Direction : uint8_t { NONE, LEFT, CENTER, RIGHT };

// Overall system state — drives the haptic outputs.
// SENSOR_FAULT (a RiskLevel, above) is deliberately NOT a SystemState
// of its own: a lone fault with no resulting obstacle reading and no
// compensation gap is reported via the status LED only, not the
// haptic motors. DEGRADED is the one case where a fault DOES reach
// the haptic motors — see docs/NOVELTY_CONTRIBUTION.md for why: when
// no obstacle is currently detected but a sensor has failed, the user
// is told coverage is reduced (DEGRADED) rather than being left with
// a silent CLEAR output indistinguishable from genuinely full
// protection. See loop() and updateStatusLed() in main.ino.
enum class SystemState : uint8_t { CLEAR, LEFT_WARNING, RIGHT_WARNING, STOP, SOS, DEGRADED };

// See docs/WSN_STAGE2_DESIGN.md for the finalised Stage 2 wire format
// and why riskLevel is NOT part of it (kept centralised at the hub).
struct SensorMessage {
  const char *nodeId;      // e.g. "NODE_FRONT" — would be the WSN node's ID
  const char *sensorType;  // "ULTRASONIC" or "BUTTON"
  float distanceCm;        // NAN for non-distance sensors (e.g. SOS button)
  RiskLevel riskLevel;     // hub-local only — see main.ino's note, not in the Stage 2 wire format
  Direction direction;
  unsigned long timestampMs; // node-local millis() since boot — NOT synchronized across nodes
  uint32_t sequenceNumber;   // increments once per sensing cycle; enables future packet-loss measurement
};
