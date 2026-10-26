import 'package:flutter/material.dart';

import '../models/user_profile.dart';

/// Step 6 — collects a plain address/name string per category; this
/// page does NOT geocode anything itself (no LocationService
/// dependency, no async work, no network call) — it just reports the
/// current `{category: addressText}` map back via [onEntriesChanged].
/// The parent (OnboardingScreen) resolves each non-empty entry to real
/// coordinates via `LocationService.getCoordinatesFromAddress` only
/// when the user moves past this step, and only a successfully
/// resolved address becomes a [FrequentPlace] — an address that fails
/// to resolve is simply not saved, never guessed at.
class PlacesPage extends StatefulWidget {
  final Map<FrequentPlaceCategory, String> entries;
  final ValueChanged<Map<FrequentPlaceCategory, String>> onEntriesChanged;

  const PlacesPage({super.key, required this.entries, required this.onEntriesChanged});

  @override
  State<PlacesPage> createState() => _PlacesPageState();
}

class _PlacesPageState extends State<PlacesPage> {
  static const Map<FrequentPlaceCategory, String> _labels = {
    FrequentPlaceCategory.home: 'Home',
    FrequentPlaceCategory.workOrCollege: 'College / Workplace',
    FrequentPlaceCategory.hospital: 'Hospital',
    FrequentPlaceCategory.busStop: 'Bus Stop',
    FrequentPlaceCategory.groceryStore: 'Grocery Store',
    FrequentPlaceCategory.pharmacy: 'Pharmacy',
    FrequentPlaceCategory.other: 'Other',
  };

  late final Map<FrequentPlaceCategory, TextEditingController> _controllers;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final category in FrequentPlaceCategory.values)
        category: TextEditingController(text: widget.entries[category] ?? ''),
    };
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onChanged(FrequentPlaceCategory category, String value) {
    final updated = Map<FrequentPlaceCategory, String>.from(widget.entries);
    if (value.trim().isEmpty) {
      updated.remove(category);
    } else {
      updated[category] = value;
    }
    widget.onEntriesChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Semantics(
          header: true,
          child: const Text('Frequently Visited Places',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        const Text(
          'Save important destinations to help with route safety and smarter '
          'guidance. Enter an address or place name for any that apply — feel '
          'free to skip any you don\'t want to save.',
          style: TextStyle(fontSize: 15, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        ...FrequentPlaceCategory.values.map((category) => Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Semantics(
                label: '${_labels[category]}, optional address',
                child: TextField(
                  controller: _controllers[category],
                  decoration: InputDecoration(
                    labelText: _labels[category],
                    hintText: 'Address or place name (optional)',
                    border: const OutlineInputBorder(),
                    prefixIcon: Icon(_iconFor(category)),
                  ),
                  onChanged: (value) => _onChanged(category, value),
                ),
              ),
            )),
      ],
    );
  }

  IconData _iconFor(FrequentPlaceCategory category) => switch (category) {
        FrequentPlaceCategory.home => Icons.home,
        FrequentPlaceCategory.workOrCollege => Icons.work,
        FrequentPlaceCategory.hospital => Icons.local_hospital,
        FrequentPlaceCategory.busStop => Icons.directions_bus,
        FrequentPlaceCategory.groceryStore => Icons.shopping_cart,
        FrequentPlaceCategory.pharmacy => Icons.local_pharmacy,
        FrequentPlaceCategory.other => Icons.place,
      };
}
