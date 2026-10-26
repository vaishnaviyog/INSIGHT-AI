# INSIGHT

An Android assistive-navigation app that helps visually impaired pedestrians travel by public transit, entirely by voice. It resolves a spoken destination, plans a real multi-leg transit journey (walk → bus/metro/suburban rail → walk), and guides the rider step by step while an on-device camera watches for obstacles and adapts hazard warnings to the individual rider over time.

## What it does

- **Voice-first navigation** — destination capture, journey selection, and turn-by-turn guidance all by voice, with typed/tapped fallback if speech input isn't available.
- **Real transit routing** — a RAPTOR-based journey planner over a merged GTFS feed (bus, metro, and suburban rail), with real street-level walking directions for the first/last mile.
- **On-device hazard detection** — a YOLOv8n object detector, temporal confirmation, and a time-to-collision estimate feed a transparent, explainable risk-scoring engine.
- **Transit-aware camera control** — a journey-state machine automatically pauses hazard detection while the rider is seated inside a vehicle and resumes it once they get off.
- **Behaviour-adaptive warnings** — the app learns a per-user profile (walking speed, warning responsiveness, route familiarity) and uses it to personalise future hazard-warning urgency.
- **Emergency SOS** — manual trigger and automatic fall detection, both routing to the same cancellable countdown and SMS/call flow.

## Project structure

| Path | Contents |
|---|---|
| `lib/services/transit/` | Journey-state machine driving camera on/off behaviour |
| `lib/services/behaviour_learning_service.dart` | Per-user behaviour/reaction profile |
| `lib/services/journey/`, `lib/services/gtfs/` | Transit routing (RAPTOR) and GTFS data handling |
| `lib/services/hazard_detectors/`, `lib/services/hazard_detection_service.dart` | On-device object detection pipeline |
| `lib/services/risk_assessment_service.dart`, `lib/services/adaptive_risk/` | Hazard risk scoring and warning prioritisation |
| `lib/services/voice_understanding/` | Spoken destination resolution |
| `lib/onboarding/` | Voice-driven onboarding flow |
| `lib/ui/` | App screens |
| `test/unit/` | Automated test suite |

## Building

Two optional features read their API keys at build time rather than from source:

```
flutter build apk --release \
  --dart-define=GEMINI_API_KEY=your_gemini_key \
  --dart-define=ORS_API_KEY=your_openrouteservice_key
```

- `GEMINI_API_KEY` — enables the on-demand scene-description feature (Google Gemini).
- `ORS_API_KEY` — enables real street-level walking directions (OpenRouteService). Without it, walking routes fall back to an OSRM public demo endpoint automatically.

Both are optional — the app builds and runs normally without either, with the corresponding feature degrading gracefully.

## Testing

```
flutter test
flutter analyze
```

## Tech stack

Flutter/Dart · TensorFlow Lite (YOLOv8n) · SQLite (GTFS data) · Hive (local persistence) · OpenRouteService · Google Gemini
