import 'package:flutter/material.dart';

import '../models/user_profile.dart';

/// Step 2 — a controlled form: every value comes from the parent
/// (either OnboardingScreen's draft state or ProfileSettingsScreen's
/// editable state) and every change is reported back via the
/// `on...Changed` callbacks. This widget holds no persistence logic
/// of its own, so it's reusable, unmodified, in both onboarding and
/// Settings.
class ProfilePage extends StatefulWidget {
  final String name;
  final AgeGroup ageGroup;
  final VisionCondition visionCondition;
  final MobilityAid mobilityAid;
  final ValueChanged<String> onNameChanged;
  final ValueChanged<AgeGroup> onAgeGroupChanged;
  final ValueChanged<VisionCondition> onVisionConditionChanged;
  final ValueChanged<MobilityAid> onMobilityAidChanged;

  const ProfilePage({
    super.key,
    required this.name,
    required this.ageGroup,
    required this.visionCondition,
    required this.mobilityAid,
    required this.onNameChanged,
    required this.onAgeGroupChanged,
    required this.onVisionConditionChanged,
    required this.onMobilityAidChanged,
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.name);
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Semantics(
          header: true,
          child: const Text('Tell us about you', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        const Text(
          'This information improves navigation quality — for example, adjusting '
          'how warnings are timed and worded for you. All fields are optional.',
          style: TextStyle(fontSize: 15, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        Semantics(
          label: 'Name, optional',
          child: TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              labelText: 'Name (optional)',
              border: OutlineInputBorder(),
            ),
            onChanged: widget.onNameChanged,
          ),
        ),
        const SizedBox(height: 28),
        const _SectionLabel('Age Group'),
        _ChoiceGroup<AgeGroup>(
          value: widget.ageGroup,
          onChanged: widget.onAgeGroupChanged,
          options: const {
            AgeGroup.below18: 'Below 18',
            AgeGroup.age18to40: '18–40',
            AgeGroup.age41to60: '41–60',
            AgeGroup.above60: 'Above 60',
          },
        ),
        const SizedBox(height: 28),
        const _SectionLabel('Vision Condition'),
        _ChoiceGroup<VisionCondition>(
          value: widget.visionCondition,
          onChanged: widget.onVisionConditionChanged,
          options: const {
            VisionCondition.completelyBlind: 'Completely Blind',
            VisionCondition.lowVision: 'Low Vision',
            VisionCondition.progressiveVisionLoss: 'Progressive Vision Loss',
            VisionCondition.other: 'Other',
          },
        ),
        const SizedBox(height: 28),
        const _SectionLabel('Mobility Aid'),
        _ChoiceGroup<MobilityAid>(
          value: widget.mobilityAid,
          onChanged: widget.onMobilityAidChanged,
          options: const {
            MobilityAid.whiteCane: 'White Cane',
            MobilityAid.guideDog: 'Guide Dog',
            MobilityAid.none: 'None',
            MobilityAid.other: 'Other',
          },
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        header: true,
        child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
      ),
    );
  }
}

/// A single-select group of choice chips — used identically for age
/// group, vision condition, and mobility aid, so the selection
/// behavior (and its accessibility semantics) only needs to be
/// correct in one place.
class _ChoiceGroup<T> extends StatelessWidget {
  final T value;
  final ValueChanged<T> onChanged;
  final Map<T, String> options;

  const _ChoiceGroup({required this.value, required this.onChanged, required this.options});

  @override
  Widget build(BuildContext context) {
    return Wrap(
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
    );
  }
}
