import '../models/user_profile.dart';
import '../services/location_service.dart';

/// Resolves each non-empty `{category: addressText}` entry to real
/// coordinates via [LocationService.getCoordinatesFromAddress].
///
/// Shared by [OnboardingScreen] (Step 6) and `ProfileSettingsScreen`'s
/// Frequent Places section so the resolution logic — and its "never
/// fabricate a coordinate for an address that fails to resolve" rule
/// — exists in exactly one place. An address that can't be geocoded
/// (no network, not found, current position unavailable) is simply
/// left out of the result, never guessed at.
Future<List<FrequentPlace>> resolveFrequentPlaces(
  LocationService locationService,
  Map<FrequentPlaceCategory, String> entries,
) async {
  final nonEmpty = Map<FrequentPlaceCategory, String>.from(entries)
    ..removeWhere((_, value) => value.trim().isEmpty);
  if (nonEmpty.isEmpty) return [];

  final position = await locationService.getCurrentLocation();
  if (position == null) return [];

  final resolved = <FrequentPlace>[];
  for (final entry in nonEmpty.entries) {
    try {
      final coords = await locationService.getCoordinatesFromAddress(entry.value, position);
      if (coords != null) {
        resolved.add(FrequentPlace(
          category: entry.key,
          label: entry.value,
          latitude: coords['lat']!,
          longitude: coords['lon']!,
        ));
      }
    } catch (e) {
      // ignore: avoid_print
      print('resolveFrequentPlaces: could not resolve "${entry.value}" (skipped, not fabricated): $e');
    }
  }
  return resolved;
}
