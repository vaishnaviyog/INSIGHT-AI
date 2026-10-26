import 'package:flutter/material.dart';

import '../models/user_profile.dart';

/// Step 4 — these three preferences are genuinely consumed, not just
/// stored: [walkingSpeed] seeds
/// `BehaviourLearningService.seedFromOnboarding`, [warningDistance]
/// becomes a 4th multiplier axis in
/// `AdaptiveGuidanceService.decideObstacleWarning`, and
/// [routePreference] changes the selection rule in
/// `SafeRouteService.selectSafestRoute`. See each service's own doc
/// comment for exactly how.
class NavigationPreferencesPage extends StatelessWidget {
  final WalkingSpeedPreference walkingSpeed;
  final WarningDistancePreference warningDistance;
  final RoutePreference routePreference;
  final ValueChanged<WalkingSpeedPreference> onWalkingSpeedChanged;
  final ValueChanged<WarningDistancePreference> onWarningDistanceChanged;
  final ValueChanged<RoutePreference> onRoutePreferenceChanged;

  const NavigationPreferencesPage({
    super.key,
    required this.walkingSpeed,
    required this.warningDistance,
    required this.routePreference,
    required this.onWalkingSpeedChanged,
    required this.onWarningDistanceChanged,
    required this.onRoutePreferenceChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Semantics(
          header: true,
          child: const Text('Navigation Preferences',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        const Text(
          'These give the app a starting point — it will continue learning and '
          'adapting to you automatically as you use it.',
          style: TextStyle(fontSize: 15, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        const _Label('Preferred Walking Speed'),
        _SegmentedRow<WalkingSpeedPreference>(
          value: walkingSpeed,
          onChanged: onWalkingSpeedChanged,
          options: const {
            WalkingSpeedPreference.slow: 'Slow',
            WalkingSpeedPreference.normal: 'Normal',
            WalkingSpeedPreference.fast: 'Fast',
          },
        ),
        const SizedBox(height: 28),
        const _Label('Preferred Warning Distance'),
        _SegmentedRow<WarningDistancePreference>(
          value: warningDistance,
          onChanged: onWarningDistanceChanged,
          options: const {
            WarningDistancePreference.veryEarly: 'Very Early',
            WarningDistancePreference.early: 'Early',
            WarningDistancePreference.normal: 'Normal',
            WarningDistancePreference.late: 'Late',
          },
        ),
        const SizedBox(height: 28),
        const _Label('Route Preference'),
        _SegmentedRow<RoutePreference>(
          value: routePreference,
          onChanged: onRoutePreferenceChanged,
          options: const {
            RoutePreference.safest: 'Safest Route',
            RoutePreference.balanced: 'Balanced',
            RoutePreference.fastest: 'Fastest Route',
          },
        ),
      ],
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        header: true,
        child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

class _SegmentedRow<T> extends StatelessWidget {
  final T value;
  final ValueChanged<T> onChanged;
  final Map<T, String> options;

  const _SegmentedRow({required this.value, required this.onChanged, required this.options});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: options.entries.map((entry) {
          final selected = entry.key == value;
          return Semantics(
            button: true,
            selected: selected,
            label: entry.value,
            child: ChoiceChip(
              label: Text(entry.value),
              selected: selected,
              onSelected: (_) => onChanged(entry.key),
            ),
          );
        }).toList(),
      ),
    );
  }
}
