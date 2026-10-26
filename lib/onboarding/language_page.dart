import 'package:flutter/material.dart';

import '../services/language/translation_provider.dart';

/// Step 3 — reuses [SupportedLanguage] directly from LanguageService's
/// own model rather than a separate onboarding-only language list, so
/// this page can never drift out of sync with what LanguageService
/// actually supports (adding a 6th language there automatically shows
/// up here with no change to this file).
class LanguagePage extends StatelessWidget {
  final SupportedLanguage selected;
  final ValueChanged<SupportedLanguage> onChanged;

  const LanguagePage({super.key, required this.selected, required this.onChanged});

  static const Map<SupportedLanguage, String> _displayNames = {
    SupportedLanguage.english: 'English',
    SupportedLanguage.tamil: 'தமிழ் (Tamil)',
    SupportedLanguage.hindi: 'हिन्दी (Hindi)',
    SupportedLanguage.malayalam: 'മലയാളം (Malayalam)',
    SupportedLanguage.telugu: 'తెలుగు (Telugu)',
  };

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24.0),
      children: [
        Semantics(
          header: true,
          child: const Text('Preferred Language',
              style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
        ),
        const SizedBox(height: 8),
        const Text(
          'This becomes your default voice guidance language. You can change it '
          'any time from Settings.',
          style: TextStyle(fontSize: 15, color: Colors.grey),
        ),
        const SizedBox(height: 24),
        ...SupportedLanguage.values.map((language) {
          final isSelected = language == selected;
          return Card(
            color: isSelected ? Colors.deepPurpleAccent.withOpacity(0.25) : null,
            child: Semantics(
              button: true,
              selected: isSelected,
              label: _displayNames[language],
              child: RadioListTile<SupportedLanguage>(
                title: Text(_displayNames[language] ?? language.name,
                    style: const TextStyle(fontSize: 18)),
                value: language,
                groupValue: selected,
                onChanged: (value) {
                  if (value != null) onChanged(value);
                },
              ),
            ),
          );
        }),
      ],
    );
  }
}
