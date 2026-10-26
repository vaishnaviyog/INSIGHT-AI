import '../../services/language/translation_provider.dart';

enum VoiceCommand { repeat, skip, goBack, help, cancel, pause, resume }

/// Matches recognized speech against the fixed command vocabulary
/// BEFORE it's treated as an answer to whatever question was just
/// asked — checked first by every step in `VoiceOnboardingController`.
///
/// Matches in English always (a bilingual user may say an English
/// command word mid-conversation in another language — common enough
/// in practice that refusing it would be a worse experience than the
/// small risk of an English word coincidentally matching a real
/// answer, which none of these command words do: no onboarding answer
/// is literally "skip"/"repeat"/etc.) AND in whichever language is
/// currently selected, via the synonym table below. Same honesty
/// caveat as `OnboardingPhrases`: these translated command words are
/// reasonable-effort, not native-speaker-verified.
class VoiceCommandParser {
  VoiceCommandParser._();

  static const Map<VoiceCommand, List<String>> _englishSynonyms = {
    VoiceCommand.repeat: ['repeat', 'say again', 'again'],
    VoiceCommand.skip: ['skip', 'skip this', 'next'],
    VoiceCommand.goBack: ['go back', 'back', 'previous'],
    VoiceCommand.help: ['help', 'what can i say'],
    VoiceCommand.cancel: ['cancel', 'stop setup', 'exit setup'],
    VoiceCommand.pause: ['pause', 'wait'],
    VoiceCommand.resume: ['resume', 'continue', 'unpause'],
  };

  static const Map<SupportedLanguage, Map<VoiceCommand, List<String>>> _translatedSynonyms = {
    SupportedLanguage.tamil: {
      VoiceCommand.repeat: ['திரும்பச் சொல்', 'மீண்டும்'],
      VoiceCommand.skip: ['தவிர்'],
      VoiceCommand.goBack: ['பின்செல்', 'பின்னால்'],
      VoiceCommand.help: ['உதவி'],
      VoiceCommand.cancel: ['ரத்து'],
      VoiceCommand.pause: ['நிறுத்து'],
      VoiceCommand.resume: ['தொடர்'],
    },
    SupportedLanguage.hindi: {
      VoiceCommand.repeat: ['दोहराओ', 'फिर से'],
      VoiceCommand.skip: ['छोड़ो', 'छोड़ें'],
      VoiceCommand.goBack: ['पीछे जाओ', 'वापस'],
      VoiceCommand.help: ['मदद'],
      VoiceCommand.cancel: ['रद्द करो', 'रद्द'],
      VoiceCommand.pause: ['रुको', 'रोको'],
      VoiceCommand.resume: ['जारी रखो', 'जारी'],
    },
    SupportedLanguage.malayalam: {
      VoiceCommand.repeat: ['ആവർത്തിക്കുക', 'വീണ്ടും'],
      VoiceCommand.skip: ['ഒഴിവാക്കുക'],
      VoiceCommand.goBack: ['പിന്നോട്ട് പോകുക', 'തിരികെ'],
      VoiceCommand.help: ['സഹായം'],
      VoiceCommand.cancel: ['റദ്ദാക്കുക'],
      VoiceCommand.pause: ['നിർത്തുക'],
      VoiceCommand.resume: ['തുടരുക'],
    },
    SupportedLanguage.telugu: {
      VoiceCommand.repeat: ['మళ్ళీ చెప్పు', 'మళ్ళీ'],
      VoiceCommand.skip: ['దాటవేయి'],
      VoiceCommand.goBack: ['వెనక్కి వెళ్ళు', 'వెనక్కి'],
      VoiceCommand.help: ['సహాయం'],
      VoiceCommand.cancel: ['రద్దు చేయి', 'రద్దు'],
      VoiceCommand.pause: ['ఆపు'],
      VoiceCommand.resume: ['కొనసాగించు'],
    },
  };

  static const Map<SupportedLanguage, List<String>> _yesWords = {
    SupportedLanguage.english: ['yes', 'yeah', 'yep', 'correct'],
    SupportedLanguage.tamil: ['ஆம்', 'சரி'],
    SupportedLanguage.hindi: ['हाँ', 'हां', 'सही'],
    SupportedLanguage.malayalam: ['അതെ', 'ശരി'],
    SupportedLanguage.telugu: ['అవును', 'సరే'],
  };

  static const Map<SupportedLanguage, List<String>> _noWords = {
    SupportedLanguage.english: ['no', 'nope', 'incorrect', 'wrong'],
    SupportedLanguage.tamil: ['இல்லை'],
    SupportedLanguage.hindi: ['नहीं'],
    SupportedLanguage.malayalam: ['ഇല്ല'],
    SupportedLanguage.telugu: ['కాదు'],
  };

  /// Returns the matched command, or null if [recognizedText] isn't
  /// one — checked as a WHOLE-PHRASE match against each synonym (a
  /// prefix/suffix check, not exact-equals, so "please skip this one"
  /// still matches "skip") rather than a substring match anywhere in
  /// the phrase, which would risk misfiring on an answer that happens
  /// to contain a command word as part of a real address or name.
  static VoiceCommand? match(String recognizedText, SupportedLanguage language) {
    final normalized = recognizedText.trim().toLowerCase();
    for (final entry in _englishSynonyms.entries) {
      for (final phrase in entry.value) {
        if (_wholePhraseMatch(normalized, phrase)) return entry.key;
      }
    }
    final translated = _translatedSynonyms[language];
    if (translated != null) {
      for (final entry in translated.entries) {
        for (final phrase in entry.value) {
          if (recognizedText.contains(phrase)) return entry.key;
        }
      }
    }
    return null;
  }

  static bool _wholePhraseMatch(String normalized, String phrase) {
    return normalized == phrase || normalized.startsWith('$phrase ') || normalized.endsWith(' $phrase');
  }

  static bool? matchYesNo(String recognizedText, SupportedLanguage language) {
    final normalized = recognizedText.trim().toLowerCase();
    final yes = [..._yesWords[SupportedLanguage.english]!, ...?_yesWords[language]];
    final no = [..._noWords[SupportedLanguage.english]!, ...?_noWords[language]];
    for (final word in yes) {
      if (normalized.contains(word.toLowerCase()) || recognizedText.contains(word)) return true;
    }
    for (final word in no) {
      if (normalized.contains(word.toLowerCase()) || recognizedText.contains(word)) return false;
    }
    return null;
  }
}
