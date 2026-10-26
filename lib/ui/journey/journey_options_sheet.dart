import 'package:flutter/material.dart';

import '../../models/journey/journey.dart';
import '../../services/audio_service.dart';
import '../../services/language_service.dart';

/// Shows the journey-selection bottom sheet and speaks a one-line
/// summary of the top-ranked option first — reuses the SAME
/// `LanguageService`/`AudioService` `NavigationScreen` already uses
/// elsewhere (not the onboarding module, which this stage must not
/// touch). Returns the [Journey] the user picked, or null if they
/// chose "walk only" / dismissed the sheet.
Future<Journey?> showJourneyOptionsSheet(
  BuildContext context, {
  required List<Journey> journeys,
  required LanguageService languageService,
  required AudioService audioService,
}) async {
  if (journeys.isNotEmpty) {
    final top = journeys.first;
    final tightCount = journeys.where((j) => j.hasTightConnection).length;
    final tightNote = tightCount == 0
        ? ''
        : ' $tightCount of these require quick boarding with little margin for error — listed as extra options.';
    await languageService.speak(
      audioService,
      'Found ${journeys.length} public transport option${journeys.length == 1 ? '' : 's'}. '
      'The fastest safe option: ${top.summary}.$tightNote',
    );
  }

  if (!context.mounted) return null;
  return showModalBottomSheet<Journey?>(
    context: context,
    isScrollControlled: true,
    builder: (context) => _JourneyOptionsSheet(journeys: journeys),
  );
}

class _JourneyOptionsSheet extends StatelessWidget {
  final List<Journey> journeys;
  const _JourneyOptionsSheet({required this.journeys});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      minChildSize: 0.3,
      expand: false,
      builder: (context, scrollController) => Container(
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                journeys.isEmpty ? 'No public transport options found' : 'Public Transport Options',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            if (journeys.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'No nearby bus or metro connection was found for this trip — walking directions will be used instead.',
                  style: TextStyle(color: Colors.grey),
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: journeys.length + 1,
                itemBuilder: (context, index) {
                  if (index == journeys.length) {
                    return Padding(
                      padding: const EdgeInsets.all(16),
                      child: OutlinedButton(
                        onPressed: () => Navigator.of(context).pop(null),
                        child: const Text('Walk only (skip public transport)'),
                      ),
                    );
                  }
                  return _JourneyCard(journey: journeys[index], onSelect: () => Navigator.of(context).pop(journeys[index]));
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JourneyCard extends StatelessWidget {
  final Journey journey;
  final VoidCallback onSelect;
  const _JourneyCard({required this.journey, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final busLabels = journey.busRouteLabels;
    final metroLabels = journey.metroLineLabels;
    final trainLabels = journey.trainLineLabels;
    // AUDIT ADD (real-device validation phase — "Kumaran Kundram"
    // investigation): a tight-connection journey can be genuinely
    // faster, but only if the rider makes a specific, infrequent
    // departure with little margin for error — this must be spoken and
    // shown, never presented as identical to a comfortable-buffer
    // option. See `Journey.hasTightConnection`'s doc comment.
    final tightWarning = journey.hasTightConnection
        ? 'Requires quick boarding — this connection has little time to spare, and missing it may mean a long wait '
            'for the next one. '
        : '';
    final semanticSummary = 'Journey option: ${journey.totalTravelTime.inMinutes} minutes, '
        '${journey.transferCount} transfer${journey.transferCount == 1 ? '' : 's'}, '
        '${journey.totalWalkingDistanceMeters.round()} meters walking. '
        '$tightWarning'
        '${busLabels.isNotEmpty ? 'Bus ${busLabels.join(', ')}. ' : ''}'
        '${metroLabels.isNotEmpty ? 'Metro ${metroLabels.join(', ')}. ' : ''}'
        '${trainLabels.isNotEmpty ? 'Train ${trainLabels.join(', ')}.' : ''}';

    return Semantics(
      button: true,
      label: semanticSummary,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: InkWell(
          onTap: onSelect,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 6,
                  children: [
                    ...busLabels.map((l) => _ModeChip(label: 'Bus $l', color: Colors.blueAccent)),
                    ...metroLabels.map((l) => _ModeChip(label: 'Metro $l', color: Colors.deepPurpleAccent)),
                    ...trainLabels.map((l) => _ModeChip(label: 'Train $l', color: Colors.teal)),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${journey.totalTravelTime.inMinutes} min  •  '
                  '${journey.totalWalkingDistanceMeters.round()} m walking  •  '
                  '${journey.transferCount} transfer${journey.transferCount == 1 ? '' : 's'}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (journey.hasTightConnection) ...[
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade800),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Requires quick boarding — little margin if delayed',
                          style: TextStyle(fontSize: 12, color: Colors.orange.shade800, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                ...journey.segments.map((s) => Text('• ${s.description}', style: const TextStyle(fontSize: 12, color: Colors.grey))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ModeChip extends StatelessWidget {
  final String label;
  final Color color;
  const _ModeChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12)),
      backgroundColor: color,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
