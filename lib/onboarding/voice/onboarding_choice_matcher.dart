import '../../models/user_profile.dart';
import '../../services/language/translation_provider.dart';

/// Matches recognized speech against each choice-based onboarding
/// field's possible values, IN THE CURRENTLY SELECTED LANGUAGE — this
/// is the piece that makes voice onboarding actually work once past
/// English: once STT is switched to, say, Tamil (see
/// `VoiceOnboardingController`), the recognized text comes back in
/// Tamil, so matching only against English words like "slow"/"fast"
/// would silently break every choice question for every non-English
/// user. The word lists below are drawn directly from the exact
/// wording spoken in `OnboardingPhrases`' prompts for each field, so
/// what's asked and what's recognized stay in sync.
///
/// Same honesty caveat as `OnboardingPhrases`/`VoiceCommandParser`:
/// reasonable-effort translations, not native-speaker-verified.
class OnboardingChoiceMatcher {
  OnboardingChoiceMatcher._();

  static T? _match<T>(String recognizedText, SupportedLanguage language, Map<T, Map<SupportedLanguage, List<String>>> table) {
    final normalized = recognizedText.trim();
    for (final entry in table.entries) {
      final words = [...?entry.value[SupportedLanguage.english], ...?entry.value[language]];
      for (final word in words) {
        if (normalized.toLowerCase().contains(word.toLowerCase()) || normalized.contains(word)) {
          return entry.key;
        }
      }
    }
    return null;
  }

  static const Map<AgeGroup, Map<SupportedLanguage, List<String>>> _ageGroup = {
    AgeGroup.below18: {
      SupportedLanguage.english: ['below 18', 'under 18'],
      SupportedLanguage.tamil: ['18க்கு கீழ்'],
      SupportedLanguage.hindi: ['18 से कम'],
      SupportedLanguage.malayalam: ['18ന് താഴെ'],
      SupportedLanguage.telugu: ['18 కంటే తక్కువ'],
    },
    AgeGroup.age18to40: {
      SupportedLanguage.english: ['18 to 40'],
      SupportedLanguage.tamil: ['18 முதல் 40'],
      SupportedLanguage.hindi: ['18 से 40'],
      SupportedLanguage.malayalam: ['18 മുതൽ 40'],
      SupportedLanguage.telugu: ['18 నుండి 40'],
    },
    AgeGroup.age41to60: {
      SupportedLanguage.english: ['41 to 60'],
      SupportedLanguage.tamil: ['41 முதல் 60'],
      SupportedLanguage.hindi: ['41 से 60'],
      SupportedLanguage.malayalam: ['41 മുതൽ 60'],
      SupportedLanguage.telugu: ['41 నుండి 60'],
    },
    AgeGroup.above60: {
      SupportedLanguage.english: ['above 60', 'over 60'],
      SupportedLanguage.tamil: ['60க்கு மேல்'],
      SupportedLanguage.hindi: ['60 से ऊपर'],
      SupportedLanguage.malayalam: ['60ന് മുകളിൽ'],
      SupportedLanguage.telugu: ['60 కంటే ఎక్కువ'],
    },
  };

  static const Map<VisionCondition, Map<SupportedLanguage, List<String>>> _visionCondition = {
    VisionCondition.completelyBlind: {
      SupportedLanguage.english: ['completely blind', 'blind'],
      SupportedLanguage.tamil: ['முழுமையாக பார்வையற்றவர்', 'பார்வையற்ற'],
      SupportedLanguage.hindi: ['पूरी तरह से अंधे', 'अंधे'],
      SupportedLanguage.malayalam: ['പൂർണ്ണമായി അന്ധത', 'അന്ധത'],
      SupportedLanguage.telugu: ['పూర్తిగా అంధత్వం', 'అంధత్వం'],
    },
    VisionCondition.lowVision: {
      SupportedLanguage.english: ['low vision'],
      SupportedLanguage.tamil: ['குறைந்த பார்வை'],
      SupportedLanguage.hindi: ['कम दृष्टि'],
      SupportedLanguage.malayalam: ['കുറഞ്ഞ കാഴ്ച'],
      SupportedLanguage.telugu: ['తక్కువ దృష్టి'],
    },
    VisionCondition.progressiveVisionLoss: {
      SupportedLanguage.english: ['progressive vision loss', 'progressive'],
      SupportedLanguage.tamil: ['படிப்படியான பார்வை இழப்பு'],
      SupportedLanguage.hindi: ['धीरे-धीरे दृष्टि की हानि'],
      SupportedLanguage.malayalam: ['ക്രമേണയുള്ള കാഴ്ച നഷ്ടം'],
      SupportedLanguage.telugu: ['క్రమంగా దృష్టి కోల్పోవడం'],
    },
    VisionCondition.other: {
      SupportedLanguage.english: ['other'],
      SupportedLanguage.tamil: ['வேறு'],
      SupportedLanguage.hindi: ['अन्य'],
      SupportedLanguage.malayalam: ['മറ്റുള്ളവ'],
      SupportedLanguage.telugu: ['ఇతర'],
    },
  };

  static const Map<MobilityAid, Map<SupportedLanguage, List<String>>> _mobilityAid = {
    MobilityAid.whiteCane: {
      SupportedLanguage.english: ['white cane', 'cane'],
      SupportedLanguage.tamil: ['வெள்ளை கைத்தடி', 'கைத்தடி'],
      SupportedLanguage.hindi: ['सफेद छड़ी', 'छड़ी'],
      SupportedLanguage.malayalam: ['വെളുത്ത വടി', 'വടി'],
      SupportedLanguage.telugu: ['తెల్ల కర్ర', 'కర్ర'],
    },
    MobilityAid.guideDog: {
      SupportedLanguage.english: ['guide dog', 'dog'],
      SupportedLanguage.tamil: ['வழிகாட்டி நாய்', 'நாய்'],
      SupportedLanguage.hindi: ['गाइड डॉग', 'डॉग'],
      SupportedLanguage.malayalam: ['ഗൈഡ് നായ', 'നായ'],
      SupportedLanguage.telugu: ['గైడ్ డాగ్', 'డాగ్'],
    },
    MobilityAid.none: {
      SupportedLanguage.english: ['none'],
      SupportedLanguage.tamil: ['இல்லை'],
      SupportedLanguage.hindi: ['कोई नहीं'],
      SupportedLanguage.malayalam: ['ഇല്ല'],
      SupportedLanguage.telugu: ['ఏమీ లేదు'],
    },
    MobilityAid.other: {
      SupportedLanguage.english: ['other'],
      SupportedLanguage.tamil: ['வேறு'],
      SupportedLanguage.hindi: ['अन्य'],
      SupportedLanguage.malayalam: ['മറ്റുള്ളവ'],
      SupportedLanguage.telugu: ['ఇతర'],
    },
  };

  static const Map<WalkingSpeedPreference, Map<SupportedLanguage, List<String>>> _walkingSpeed = {
    WalkingSpeedPreference.slow: {
      SupportedLanguage.english: ['slow'],
      SupportedLanguage.tamil: ['மெதுவாக'],
      SupportedLanguage.hindi: ['धीमी'],
      SupportedLanguage.malayalam: ['പതുക്കെ'],
      SupportedLanguage.telugu: ['నెమ్మది'],
    },
    WalkingSpeedPreference.normal: {
      SupportedLanguage.english: ['normal'],
      SupportedLanguage.tamil: ['சாதாரணமாக', 'சாதாரணம்'],
      SupportedLanguage.hindi: ['सामान्य'],
      SupportedLanguage.malayalam: ['സാധാരണം'],
      SupportedLanguage.telugu: ['సాధారణం'],
    },
    WalkingSpeedPreference.fast: {
      SupportedLanguage.english: ['fast'],
      SupportedLanguage.tamil: ['வேகமாக'],
      SupportedLanguage.hindi: ['तेज़', 'तेज'],
      SupportedLanguage.malayalam: ['വേഗത്തിൽ'],
      SupportedLanguage.telugu: ['వేగం'],
    },
  };

  static const Map<WarningDistancePreference, Map<SupportedLanguage, List<String>>> _warningDistance = {
    WarningDistancePreference.veryEarly: {
      SupportedLanguage.english: ['very early'],
      SupportedLanguage.tamil: ['மிக முன்னதாக'],
      SupportedLanguage.hindi: ['बहुत जल्दी'],
      SupportedLanguage.malayalam: ['വളരെ നേരത്തെ'],
      SupportedLanguage.telugu: ['చాలా ముందుగా'],
    },
    WarningDistancePreference.early: {
      SupportedLanguage.english: ['early'],
      SupportedLanguage.tamil: ['முன்னதாக'],
      SupportedLanguage.hindi: ['जल्दी'],
      SupportedLanguage.malayalam: ['നേരത്തെ'],
      SupportedLanguage.telugu: ['ముందుగా'],
    },
    WarningDistancePreference.normal: {
      SupportedLanguage.english: ['normal'],
      SupportedLanguage.tamil: ['சாதாரணமாக', 'சாதாரணம்'],
      SupportedLanguage.hindi: ['सामान्य'],
      SupportedLanguage.malayalam: ['സാധാരണം'],
      SupportedLanguage.telugu: ['సాధారణం'],
    },
    WarningDistancePreference.late: {
      SupportedLanguage.english: ['late'],
      SupportedLanguage.tamil: ['தாமதமாக'],
      SupportedLanguage.hindi: ['देर से'],
      SupportedLanguage.malayalam: ['വൈകി'],
      SupportedLanguage.telugu: ['ఆలస్యంగా'],
    },
  };

  static const Map<RoutePreference, Map<SupportedLanguage, List<String>>> _routePreference = {
    RoutePreference.safest: {
      SupportedLanguage.english: ['safest', 'safe'],
      SupportedLanguage.tamil: ['பாதுகாப்பானது'],
      SupportedLanguage.hindi: ['सबसे सुरक्षित', 'सुरक्षित'],
      SupportedLanguage.malayalam: ['ഏറ്റവും സുരക്ഷിതം'],
      SupportedLanguage.telugu: ['సురక్షితమైనది'],
    },
    RoutePreference.balanced: {
      SupportedLanguage.english: ['balanced'],
      SupportedLanguage.tamil: ['சமநிலையானது'],
      SupportedLanguage.hindi: ['संतुलित'],
      SupportedLanguage.malayalam: ['സന്തുലിതം'],
      SupportedLanguage.telugu: ['సమతుల్యమైనది'],
    },
    RoutePreference.fastest: {
      SupportedLanguage.english: ['fastest'],
      SupportedLanguage.tamil: ['வேகமானது'],
      SupportedLanguage.hindi: ['सबसे तेज़', 'तेज़'],
      SupportedLanguage.malayalam: ['ഏറ്റവും വേഗതയേറിയത്'],
      SupportedLanguage.telugu: ['వేగవంతమైనది'],
    },
  };

  static AgeGroup? matchAgeGroup(String text, SupportedLanguage lang) => _match(text, lang, _ageGroup);
  static VisionCondition? matchVisionCondition(String text, SupportedLanguage lang) =>
      _match(text, lang, _visionCondition);
  static MobilityAid? matchMobilityAid(String text, SupportedLanguage lang) => _match(text, lang, _mobilityAid);
  static WalkingSpeedPreference? matchWalkingSpeed(String text, SupportedLanguage lang) =>
      _match(text, lang, _walkingSpeed);
  static WarningDistancePreference? matchWarningDistance(String text, SupportedLanguage lang) =>
      _match(text, lang, _warningDistance);
  static RoutePreference? matchRoutePreference(String text, SupportedLanguage lang) =>
      _match(text, lang, _routePreference);
}
