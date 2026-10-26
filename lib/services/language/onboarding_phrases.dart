import 'translation_provider.dart';

/// Every distinct spoken line in the voice onboarding conversation
/// (Stage 1), keyed rather than pattern-matched — unlike
/// `StaticTranslationProvider`, which translates arbitrary English
/// text it recognizes the SHAPE of, onboarding prompts are a small,
/// fixed, known set, so a direct key→translation lookup is simpler
/// and more reliable than running them through that pattern matcher
/// (which explicitly does NOT cover this kind of free-form question
/// text — see its own doc comment).
///
/// SAME HONESTY REQUIREMENT AS StaticTranslationProvider: these are
/// reasonable-effort, common-vocabulary translations, NOT verified by
/// a native speaker of Tamil, Hindi, Malayalam, or Telugu. For a
/// safety-relevant accessibility application, have each language
/// reviewed by a native speaker before relying on it in production.
///
/// Command words (repeat/skip/go back/help/cancel/pause/resume) and
/// yes/no are matched in BOTH English and the phrases below by
/// `VoiceCommandParser` — see that file — since a bilingual user may
/// naturally say the English word for a command even mid-conversation
/// in another language.
enum OnboardingPhraseKey {
  continuingSetup,
  askName,
  heardPrefix,
  isThatCorrect,
  sorryRetry,
  pleaseYesOrNo,
  pleaseTypeAnswer,
  askAgeGroup,
  askVisionCondition,
  askMobilityAid,
  askWalkingSpeed,
  askWarningDistance,
  askRoutePreference,
  emergencyIntro,
  askContactName,
  askContactPhone,
  askAddAnotherContact,
  placesIntro,
  askPlaceHome,
  askPlaceWork,
  askPlaceHospital,
  askPlaceBusStop,
  askPlaceGrocery,
  askPlacePharmacy,
  askPlaceOther,
  voicePreviewIntro,
  permissionsIntro,
  finishMessage,
  helpText,
  skippedAck,
  goingBackAck,
  pausedAck,
  resumedAck,
  cancelConfirm,
}

class OnboardingPhrases {
  OnboardingPhrases._();

  static const Map<OnboardingPhraseKey, Map<SupportedLanguage, String>> _phrases = {
    OnboardingPhraseKey.continuingSetup: {
      SupportedLanguage.english: "Okay, continuing setup now.",
      SupportedLanguage.tamil: "சரி, அமைப்பைத் தொடர்கிறோம்.",
      SupportedLanguage.hindi: "ठीक है, अब सेटअप जारी रखते हैं.",
      SupportedLanguage.malayalam: "ശരി, സെറ്റപ്പ് തുടരാം.",
      SupportedLanguage.telugu: "సరే, సెటప్ కొనసాగిస్తున్నాము.",
    },
    OnboardingPhraseKey.askName: {
      SupportedLanguage.english: "What should I call you? Say your name, or say skip.",
      SupportedLanguage.tamil: "நான் உங்களை என்ன அழைக்கலாம்? உங்கள் பெயரைச் சொல்லுங்கள், அல்லது skip என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi: "मैं आपको क्या कहूँ? अपना नाम बताएं, या skip कहें.",
      SupportedLanguage.malayalam: "ഞാൻ നിങ്ങളെ എന്ത് വിളിക്കണം? നിങ്ങളുടെ പേര് പറയുക, അല്ലെങ്കിൽ skip എന്ന് പറയുക.",
      SupportedLanguage.telugu: "నేను మిమ్మల్ని ఏమని పిలవాలి? మీ పేరు చెప్పండి, లేదా skip అని చెప్పండి.",
    },
    OnboardingPhraseKey.heardPrefix: {
      SupportedLanguage.english: "You said:",
      SupportedLanguage.tamil: "நீங்கள் சொன்னது:",
      SupportedLanguage.hindi: "आपने कहा:",
      SupportedLanguage.malayalam: "നിങ്ങൾ പറഞ്ഞത്:",
      SupportedLanguage.telugu: "మీరు చెప్పింది:",
    },
    OnboardingPhraseKey.isThatCorrect: {
      SupportedLanguage.english: "Is that correct? Say yes, or no.",
      SupportedLanguage.tamil: "இது சரியா? ஆம் அல்லது இல்லை என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi: "क्या यह सही है? हाँ या नहीं कहें.",
      SupportedLanguage.malayalam: "ഇത് ശരിയാണോ? അതെ അല്ലെങ്കിൽ ഇല്ല എന്ന് പറയുക.",
      SupportedLanguage.telugu: "ఇది సరైనదేనా? అవును లేదా కాదు అని చెప్పండి.",
    },
    OnboardingPhraseKey.sorryRetry: {
      SupportedLanguage.english: "Sorry, I didn't catch that. Let me ask again.",
      SupportedLanguage.tamil: "மன்னிக்கவும், எனக்குப் புரியவில்லை. மீண்டும் கேட்கிறேன்.",
      SupportedLanguage.hindi: "माफ़ कीजिए, मैं समझ नहीं पाया. फिर से पूछता हूँ.",
      SupportedLanguage.malayalam: "ക്ഷമിക്കണം, എനിക്ക് മനസ്സിലായില്ല. ഞാൻ വീണ്ടും ചോദിക്കാം.",
      SupportedLanguage.telugu: "క్షమించండి, నాకు అర్థం కాలేదు. మళ్ళీ అడుగుతాను.",
    },
    OnboardingPhraseKey.pleaseYesOrNo: {
      SupportedLanguage.english: "Please say yes or no.",
      SupportedLanguage.tamil: "தயவுசெய்து ஆம் அல்லது இல்லை என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi: "कृपया हाँ या नहीं कहें.",
      SupportedLanguage.malayalam: "ദയവായി അതെ അല്ലെങ്കിൽ ഇല്ല എന്ന് പറയുക.",
      SupportedLanguage.telugu: "దయచేసి అవును లేదా కాదు అని చెప్పండి.",
    },
    // AUDIT ADD (P1-14): spoken once voice recognition has failed
    // several times in a row for the SAME question, instead of
    // repeating `sorryRetry` verbatim indefinitely — matches the
    // original spec's explicit requirement ("Voice recognition isn't
    // clear. Please type your answer. Do NOT trap the user in
    // endless retries."). See VoiceOnboardingController's
    // _maxVoiceAttemptsBeforeTextFallback.
    OnboardingPhraseKey.pleaseTypeAnswer: {
      SupportedLanguage.english: "Voice recognition isn't clear. Please type your answer instead.",
      SupportedLanguage.tamil: "குரல் அடையாளம் தெளிவாக இல்லை. தயவுசெய்து உங்கள் பதிலைத் தட்டச்சு செய்யுங்கள்.",
      SupportedLanguage.hindi: "आवाज़ स्पष्ट रूप से पहचानी नहीं जा रही. कृपया अपना उत्तर टाइप करें.",
      SupportedLanguage.malayalam: "ശബ്ദം വ്യക്തമായി തിരിച്ചറിയാൻ കഴിയുന്നില്ല. ദയവായി നിങ്ങളുടെ ഉത്തരം ടൈപ്പ് ചെയ്യുക.",
      SupportedLanguage.telugu: "వాయిస్ స్పష్టంగా గుర్తించబడలేదు. దయచేసి మీ సమాధానం టైప్ చేయండి.",
    },
    OnboardingPhraseKey.askAgeGroup: {
      SupportedLanguage.english:
          "What is your age group? Say: below 18, 18 to 40, 41 to 60, or above 60. Or say skip.",
      SupportedLanguage.tamil:
          "உங்கள் வயது பிரிவு என்ன? சொல்லுங்கள்: 18க்கு கீழ், 18 முதல் 40, 41 முதல் 60, அல்லது 60க்கு மேல். அல்லது skip என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi:
          "आपका आयु वर्ग क्या है? कहें: 18 से कम, 18 से 40, 41 से 60, या 60 से ऊपर. या skip कहें.",
      SupportedLanguage.malayalam:
          "നിങ്ങളുടെ പ്രായപരിധി എന്താണ്? പറയുക: 18ന് താഴെ, 18 മുതൽ 40 വരെ, 41 മുതൽ 60 വരെ, അല്ലെങ്കിൽ 60ന് മുകളിൽ. അല്ലെങ്കിൽ skip എന്ന് പറയുക.",
      SupportedLanguage.telugu:
          "మీ వయస్సు వర్గం ఏమిటి? చెప్పండి: 18 కంటే తక్కువ, 18 నుండి 40, 41 నుండి 60, లేదా 60 కంటే ఎక్కువ. లేదా skip అని చెప్పండి.",
    },
    OnboardingPhraseKey.askVisionCondition: {
      SupportedLanguage.english:
          "What is your vision condition? Say: completely blind, low vision, progressive vision loss, or other. Or say skip.",
      SupportedLanguage.tamil:
          "உங்கள் பார்வை நிலை என்ன? சொல்லுங்கள்: முழுமையாக பார்வையற்றவர், குறைந்த பார்வை, படிப்படியான பார்வை இழப்பு, அல்லது வேறு. அல்லது skip என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi:
          "आपकी दृष्टि की स्थिति क्या है? कहें: पूरी तरह से अंधे, कम दृष्टि, धीरे-धीरे दृष्टि की हानि, या अन्य. या skip कहें.",
      SupportedLanguage.malayalam:
          "നിങ്ങളുടെ കാഴ്ച നില എന്താണ്? പറയുക: പൂർണ്ണമായി അന്ധത, കുറഞ്ഞ കാഴ്ച, ക്രമേണയുള്ള കാഴ്ച നഷ്ടം, അല്ലെങ്കിൽ മറ്റുള്ളവ. അല്ലെങ്കിൽ skip എന്ന് പറയുക.",
      SupportedLanguage.telugu:
          "మీ దృష్టి పరిస్థితి ఏమిటి? చెప్పండి: పూర్తిగా అంధత్వం, తక్కువ దృష్టి, క్రమంగా దృష్టి కోల్పోవడం, లేదా ఇతర. లేదా skip అని చెప్పండి.",
    },
    OnboardingPhraseKey.askMobilityAid: {
      SupportedLanguage.english:
          "Do you use a mobility aid? Say: white cane, guide dog, none, or other. Or say skip.",
      SupportedLanguage.tamil:
          "நீங்கள் ஏதேனும் நடமாட்ட உதவி பயன்படுத்துகிறீர்களா? சொல்லுங்கள்: வெள்ளை கைத்தடி, வழிகாட்டி நாய், இல்லை, அல்லது வேறு. அல்லது skip என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi:
          "क्या आप कोई सहायक उपकरण उपयोग करते हैं? कहें: सफेद छड़ी, गाइड डॉग, कोई नहीं, या अन्य. या skip कहें.",
      SupportedLanguage.malayalam:
          "നിങ്ങൾ ഒരു സഞ്ചാര സഹായി ഉപയോഗിക്കുന്നുണ്ടോ? പറയുക: വെളുത്ത വടി, ഗൈഡ് നായ, ഇല്ല, അല്ലെങ്കിൽ മറ്റുള്ളവ. അല്ലെങ്കിൽ skip എന്ന് പറയുക.",
      SupportedLanguage.telugu:
          "మీరు ఏదైనా చలన సహాయం ఉపయోగిస్తున్నారా? చెప్పండి: తెల్ల కర్ర, గైడ్ డాగ్, ఏమీ లేదు, లేదా ఇతర. లేదా skip అని చెప్పండి.",
    },
    OnboardingPhraseKey.askWalkingSpeed: {
      SupportedLanguage.english: "What is your preferred walking speed? Say: slow, normal, or fast.",
      SupportedLanguage.tamil: "உங்கள் விருப்பமான நடை வேகம் என்ன? சொல்லுங்கள்: மெதுவாக, சாதாரணமாக, அல்லது வேகமாக.",
      SupportedLanguage.hindi: "आपकी पसंदीदा चलने की गति क्या है? कहें: धीमी, सामान्य, या तेज़.",
      SupportedLanguage.malayalam: "നിങ്ങളുടെ ഇഷ്ടപ്പെട്ട നടത്ത വേഗത എന്താണ്? പറയുക: പതുക്കെ, സാധാരണം, അല്ലെങ്കിൽ വേഗത്തിൽ.",
      SupportedLanguage.telugu: "మీకు నచ్చిన నడక వేగం ఏమిటి? చెప్పండి: నెమ్మది, సాధారణం, లేదా వేగం.",
    },
    OnboardingPhraseKey.askWarningDistance: {
      SupportedLanguage.english:
          "How early would you like hazard warnings? Say: very early, early, normal, or late.",
      SupportedLanguage.tamil:
          "ஆபத்து எச்சரிக்கைகளை எவ்வளவு முன்னதாக விரும்புகிறீர்கள்? சொல்லுங்கள்: மிக முன்னதாக, முன்னதாக, சாதாரணமாக, அல்லது தாமதமாக.",
      SupportedLanguage.hindi:
          "आप खतरे की चेतावनी कितनी जल्दी चाहते हैं? कहें: बहुत जल्दी, जल्दी, सामान्य, या देर से.",
      SupportedLanguage.malayalam:
          "അപകട മുന്നറിയിപ്പുകൾ എത്ര നേരത്തെ വേണം? പറയുക: വളരെ നേരത്തെ, നേരത്തെ, സാധാരണം, അല്ലെങ്കിൽ വൈകി.",
      SupportedLanguage.telugu:
          "ప్రమాద హెచ్చరికలు ఎంత ముందుగా కావాలి? చెప్పండి: చాలా ముందుగా, ముందుగా, సాధారణం, లేదా ఆలస్యంగా.",
    },
    OnboardingPhraseKey.askRoutePreference: {
      SupportedLanguage.english: "What route would you prefer? Say: safest, balanced, or fastest.",
      SupportedLanguage.tamil: "எந்த பாதையை விரும்புகிறீர்கள்? சொல்லுங்கள்: பாதுகாப்பானது, சமநிலையானது, அல்லது வேகமானது.",
      SupportedLanguage.hindi: "आप कौन सा मार्ग पसंद करेंगे? कहें: सबसे सुरक्षित, संतुलित, या सबसे तेज़.",
      SupportedLanguage.malayalam: "ഏത് വഴിയാണ് ഇഷ്ടപ്പെടുന്നത്? പറയുക: ഏറ്റവും സുരക്ഷിതം, സന്തുലിതം, അല്ലെങ്കിൽ ഏറ്റവും വേഗതയേറിയത്.",
      SupportedLanguage.telugu: "మీరు ఏ మార్గాన్ని ఇష్టపడతారు? చెప్పండి: సురక్షితమైనది, సమతుల్యమైనది, లేదా వేగవంతమైనది.",
    },
    OnboardingPhraseKey.emergencyIntro: {
      SupportedLanguage.english: "Now let's add an emergency contact. Say skip if you don't want to add one.",
      SupportedLanguage.tamil: "இப்போது ஒரு அவசர தொடர்பைச் சேர்க்கலாம். சேர்க்க விரும்பவில்லை என்றால் skip என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi: "अब एक आपातकालीन संपर्क जोड़ते हैं. यदि नहीं जोड़ना चाहते तो skip कहें.",
      SupportedLanguage.malayalam: "ഇപ്പോൾ ഒരു അടിയന്തര ബന്ധം ചേർക്കാം. വേണ്ടെങ്കിൽ skip എന്ന് പറയുക.",
      SupportedLanguage.telugu: "ఇప్పుడు ఒక అత్యవసర సంప్రదింపును జోడిద్దాం. జోడించకూడదనుకుంటే skip అని చెప్పండి.",
    },
    OnboardingPhraseKey.askContactName: {
      SupportedLanguage.english: "What is the contact's name?",
      SupportedLanguage.tamil: "தொடர்பின் பெயர் என்ன?",
      SupportedLanguage.hindi: "संपर्क का नाम क्या है?",
      SupportedLanguage.malayalam: "ബന്ധത്തിന്റെ പേര് എന്താണ്?",
      SupportedLanguage.telugu: "సంప్రదింపు పేరు ఏమిటి?",
    },
    OnboardingPhraseKey.askContactPhone: {
      SupportedLanguage.english: "What is their phone number?",
      SupportedLanguage.tamil: "அவர்களின் தொலைபேசி எண் என்ன?",
      SupportedLanguage.hindi: "उनका फ़ोन नंबर क्या है?",
      SupportedLanguage.malayalam: "അവരുടെ ഫോൺ നമ്പർ എന്താണ്?",
      SupportedLanguage.telugu: "వారి ఫోన్ నంబర్ ఏమిటి?",
    },
    OnboardingPhraseKey.askAddAnotherContact: {
      SupportedLanguage.english: "Would you like to add another contact? Say yes or no.",
      SupportedLanguage.tamil: "மற்றொரு தொடர்பைச் சேர்க்க விரும்புகிறீர்களா? ஆம் அல்லது இல்லை என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi: "क्या आप एक और संपर्क जोड़ना चाहते हैं? हाँ या नहीं कहें.",
      SupportedLanguage.malayalam: "മറ്റൊരു ബന്ധം കൂടി ചേർക്കണോ? അതെ അല്ലെങ്കിൽ ഇല്ല എന്ന് പറയുക.",
      SupportedLanguage.telugu: "మరొక సంప్రదింపును జోడించాలనుకుంటున్నారా? అవును లేదా కాదు అని చెప్పండి.",
    },
    OnboardingPhraseKey.placesIntro: {
      SupportedLanguage.english:
          "Now let's save some frequently visited places. For each one, say the address, or say skip.",
      SupportedLanguage.tamil:
          "இப்போது அடிக்கடி செல்லும் இடங்களைச் சேமிக்கலாம். ஒவ்வொன்றுக்கும் முகவரியைச் சொல்லுங்கள், அல்லது skip என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi:
          "अब कुछ अक्सर जाने वाली जगहों को सहेजते हैं. हर एक के लिए पता बताएं, या skip कहें.",
      SupportedLanguage.malayalam:
          "ഇപ്പോൾ പതിവായി പോകുന്ന സ്ഥലങ്ങൾ സൂക്ഷിക്കാം. ഓരോന്നിനും വിലാസം പറയുക, അല്ലെങ്കിൽ skip എന്ന് പറയുക.",
      SupportedLanguage.telugu:
          "ఇప్పుడు తరచుగా వెళ్ళే స్థలాలను సేవ్ చేద్దాం. ప్రతి దానికి చిరునామా చెప్పండి, లేదా skip అని చెప్పండి.",
    },
    OnboardingPhraseKey.askPlaceHome: {
      SupportedLanguage.english: "What is your Home address?",
      SupportedLanguage.tamil: "உங்கள் வீட்டு முகவரி என்ன?",
      SupportedLanguage.hindi: "आपके घर का पता क्या है?",
      SupportedLanguage.malayalam: "നിങ്ങളുടെ വീട്ടിന്റെ വിലാസം എന്താണ്?",
      SupportedLanguage.telugu: "మీ ఇంటి చిరునామా ఏమిటి?",
    },
    OnboardingPhraseKey.askPlaceWork: {
      SupportedLanguage.english: "What is your College or Workplace address?",
      SupportedLanguage.tamil: "உங்கள் கல்லூரி அல்லது பணியிட முகவரி என்ன?",
      SupportedLanguage.hindi: "आपके कॉलेज या कार्यस्थल का पता क्या है?",
      SupportedLanguage.malayalam: "നിങ്ങളുടെ കോളേജിന്റെ അല്ലെങ്കിൽ ജോലിസ്ഥലത്തിന്റെ വിലാസം എന്താണ്?",
      SupportedLanguage.telugu: "మీ కళాశాల లేదా పని స్థలం చిరునామా ఏమిటి?",
    },
    OnboardingPhraseKey.askPlaceHospital: {
      SupportedLanguage.english: "What is your Hospital address?",
      SupportedLanguage.tamil: "உங்கள் மருத்துவமனை முகவரி என்ன?",
      SupportedLanguage.hindi: "आपके अस्पताल का पता क्या है?",
      SupportedLanguage.malayalam: "നിങ്ങളുടെ ആശുപത്രിയുടെ വിലാസം എന്താണ്?",
      SupportedLanguage.telugu: "మీ ఆసుపత్రి చిరునామా ఏమిటి?",
    },
    OnboardingPhraseKey.askPlaceBusStop: {
      SupportedLanguage.english: "What is your usual Bus Stop address?",
      SupportedLanguage.tamil: "நீங்கள் வழக்கமாகப் பயன்படுத்தும் பேருந்து நிறுத்த முகவரி என்ன?",
      SupportedLanguage.hindi: "आपके सामान्य बस स्टॉप का पता क्या है?",
      SupportedLanguage.malayalam: "നിങ്ങൾ സാധാരണ ഉപയോഗിക്കുന്ന ബസ് സ്റ്റോപ്പിന്റെ വിലാസം എന്താണ്?",
      SupportedLanguage.telugu: "మీరు సాధారణంగా వాడే బస్ స్టాప్ చిరునామా ఏమిటి?",
    },
    OnboardingPhraseKey.askPlaceGrocery: {
      SupportedLanguage.english: "What is your Grocery Store address?",
      SupportedLanguage.tamil: "உங்கள் மளிகைக் கடை முகவரி என்ன?",
      SupportedLanguage.hindi: "आपकी किराने की दुकान का पता क्या है?",
      SupportedLanguage.malayalam: "നിങ്ങളുടെ പലചരക്ക് കടയുടെ വിലാസം എന്താണ്?",
      SupportedLanguage.telugu: "మీ కిరాణా దుకాణం చిరునామా ఏమిటి?",
    },
    OnboardingPhraseKey.askPlacePharmacy: {
      SupportedLanguage.english: "What is your Pharmacy address?",
      SupportedLanguage.tamil: "உங்கள் மருந்தகத்தின் முகவரி என்ன?",
      SupportedLanguage.hindi: "आपकी दवा दुकान का पता क्या है?",
      SupportedLanguage.malayalam: "നിങ്ങളുടെ ഫാർമസിയുടെ വിലാസം എന്താണ്?",
      SupportedLanguage.telugu: "మీ మందుల దుకాణం చిరునామా ఏమిటి?",
    },
    OnboardingPhraseKey.askPlaceOther: {
      SupportedLanguage.english: "Any other place you'd like to save? Say the address, or say skip.",
      SupportedLanguage.tamil: "வேறு ஏதேனும் இடத்தைச் சேமிக்க விரும்புகிறீர்களா? முகவரியைச் சொல்லுங்கள், அல்லது skip என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi: "कोई और जगह जो आप सहेजना चाहते हैं? पता बताएं, या skip कहें.",
      SupportedLanguage.malayalam: "സൂക്ഷിക്കാൻ ആഗ്രഹിക്കുന്ന വേറെ സ്ഥലം ഉണ്ടോ? വിലാസം പറയുക, അല്ലെങ്കിൽ skip എന്ന് പറയുക.",
      SupportedLanguage.telugu: "సేవ్ చేయాలనుకుంటున్న మరో స్థలం ఏదైనా ఉందా? చిరునామా చెప్పండి, లేదా skip అని చెప్పండి.",
    },
    OnboardingPhraseKey.voicePreviewIntro: {
      SupportedLanguage.english: "Here is a sample of how navigation guidance will sound.",
      SupportedLanguage.tamil: "வழிசெலுத்தல் வழிகாட்டுதல் எப்படி ஒலிக்கும் என்பதற்கான ஒரு மாதிரி இது.",
      SupportedLanguage.hindi: "यह एक नमूना है कि नेविगेशन मार्गदर्शन कैसा सुनाई देगा.",
      SupportedLanguage.malayalam: "നാവിഗേഷൻ മാർഗ്ഗനിർദ്ദേശം എങ്ങനെ കേൾക്കും എന്നതിന്റെ ഒരു സാമ്പിൾ ഇതാ.",
      SupportedLanguage.telugu: "నావిగేషన్ మార్గదర్శకత్వం ఎలా వినిపిస్తుందో దీనికి ఒక నమూనా.",
    },
    // AUDIT FIX (Phase F10 — privacy disclosure): appended one sentence
    // to the existing permissions-intro phrase, the natural place this
    // app already explains what camera/location/microphone access is
    // for. Before this, NOTHING anywhere in onboarding (or elsewhere)
    // ever disclosed that the "describe what's around me" feature
    // (SceneDescriptionService) sends a real camera photo to Google's
    // Gemini cloud API — a real, previously-undisclosed data flow,
    // even though it's user-triggered and not continuous (confirmed:
    // only wired to an explicit tap/long-press/double-tap gesture, not
    // the regular on-device hazard-detection frame stream). Every
    // language's addition below is a good-faith, non-professional
    // translation of the same English sentence (this codebase already
    // has an established pattern of translating onboarding strings
    // in-house — see the rest of this file) — flagged here, honestly,
    // as not independently verified by a native speaker, same
    // disclosure standard this phase applies to itself throughout.
    OnboardingPhraseKey.permissionsIntro: {
      SupportedLanguage.english:
          "INSIGHT needs a few permissions. Camera, to detect hazards. Location, for navigation. "
              "Microphone, so you can talk to the app. And notifications, for emergency alerts. Requesting them now. "
              "One more thing: when you ask INSIGHT to describe what's around you, a photo from the camera is sent "
              "to an online service to answer — that only happens when you ask.",
      SupportedLanguage.tamil:
          "INSIGHT-க்கு சில அனுமதிகள் தேவை. ஆபத்துகளைக் கண்டறிய கேமரா. வழிசெலுத்தலுக்கு இருப்பிடம். "
              "பயன்பாட்டுடன் பேச மைக்ரோஃபோன். அவசர எச்சரிக்கைகளுக்கு அறிவிப்புகள். இப்போது கேட்கிறோம். "
              "மேலும் ஒன்று: உங்களைச் சுற்றி என்ன இருக்கிறது என்று INSIGHT-ஐ விவரிக்கச் சொன்னால், கேமராவிலிருந்து ஒரு "
              "புகைப்படம் பதிலளிக்க ஆன்லைன் சேவைக்கு அனுப்பப்படும் — நீங்கள் கேட்கும்போது மட்டுமே இது நடக்கும்.",
      SupportedLanguage.hindi:
          "INSIGHT को कुछ अनुमतियों की आवश्यकता है. खतरों का पता लगाने के लिए कैमरा. नेविगेशन के लिए लोकेशन. "
              "ऐप से बात करने के लिए माइक्रोफ़ोन. और आपातकालीन अलर्ट के लिए सूचनाएं. अभी अनुरोध कर रहे हैं. "
              "एक और बात: जब आप इनसाइट से अपने आस-पास के बारे में बताने के लिए कहते हैं, तो जवाब देने के लिए कैमरे से एक "
              "फोटो एक ऑनलाइन सेवा को भेजी जाती है — यह केवल तब होता है जब आप पूछते हैं.",
      SupportedLanguage.malayalam:
          "INSIGHT-ന് കുറച്ച് അനുമതികൾ ആവശ്യമാണ്. അപകടങ്ങൾ കണ്ടെത്താൻ ക്യാമറ. നാവിഗേഷനായി ലൊക്കേഷൻ. "
              "ആപ്പുമായി സംസാരിക്കാൻ മൈക്രോഫോൺ. അടിയന്തര അലേർട്ടുകൾക്കായി അറിയിപ്പുകൾ. ഇപ്പോൾ അഭ്യർത്ഥിക്കുന്നു. "
              "ഒരു കാര്യം കൂടി: നിങ്ങളുടെ ചുറ്റുപാടിനെക്കുറിച്ച് വിവരിക്കാൻ INSIGHT-നോട് ആവശ്യപ്പെടുമ്പോൾ, ക്യാമറയിൽ "
              "നിന്നുള്ള ഒരു ഫോട്ടോ ഒരു ഓൺലൈൻ സേവനത്തിലേക്ക് അയയ്ക്കുന്നു — നിങ്ങൾ ചോദിക്കുമ്പോൾ മാത്രമേ ഇത് സംഭവിക്കൂ.",
      SupportedLanguage.telugu:
          "INSIGHT కు కొన్ని అనుమతులు అవసరం. ప్రమాదాలను గుర్తించడానికి కెమెరా. నావిగేషన్ కోసం లొకేషన్. "
              "యాప్‌తో మాట్లాడటానికి మైక్రోఫోన్. అత్యవసర హెచ్చరికల కోసం నోటిఫికేషన్లు. ఇప్పుడు అభ్యర్థిస్తున్నాము. "
              "ఇంకొక విషయం: మీ చుట్టుపక్కల ఏముందో వివరించమని మీరు INSIGHTని అడిగినప్పుడు, సమాధానం ఇవ్వడానికి కెమెరా "
              "నుండి ఒక ఫోటో ఆన్‌లైన్ సేవకు పంపబడుతుంది — మీరు అడిగినప్పుడు మాత్రమే ఇది జరుగుతుంది.",
    },
    OnboardingPhraseKey.finishMessage: {
      SupportedLanguage.english: "Setup is complete. INSIGHT is ready to help you.",
      SupportedLanguage.tamil: "அமைப்பு முடிந்தது. INSIGHT உங்களுக்கு உதவத் தயாராக உள்ளது.",
      SupportedLanguage.hindi: "सेटअप पूरा हो गया है. INSIGHT आपकी मदद के लिए तैयार है.",
      SupportedLanguage.malayalam: "സെറ്റപ്പ് പൂർത്തിയായി. INSIGHT നിങ്ങളെ സഹായിക്കാൻ തയ്യാറാണ്.",
      SupportedLanguage.telugu: "సెటప్ పూర్తయింది. INSIGHT మీకు సహాయం చేయడానికి సిద్ధంగా ఉంది.",
    },
    OnboardingPhraseKey.helpText: {
      SupportedLanguage.english:
          "You can say: repeat, to hear the question again. Skip, to move on. Go back, to return to "
              "the previous question. Pause, to pause. Resume, to continue. Or cancel, to finish setup "
              "early with your current answers.",
      SupportedLanguage.tamil:
          "நீங்கள் சொல்லலாம்: repeat, கேள்வியை மீண்டும் கேட்க. skip, தொடர. go back, முந்தைய கேள்விக்குச் "
              "செல்ல. pause, இடைநிறுத்த. resume, தொடர. அல்லது cancel, தற்போதைய பதில்களுடன் அமைப்பை முடிக்க.",
      SupportedLanguage.hindi:
          "आप कह सकते हैं: repeat, प्रश्न फिर से सुनने के लिए. skip, आगे बढ़ने के लिए. go back, पिछले "
              "प्रश्न पर जाने के लिए. pause, रोकने के लिए. resume, जारी रखने के लिए. या cancel, वर्तमान "
              "उत्तरों के साथ सेटअप जल्दी समाप्त करने के लिए.",
      SupportedLanguage.malayalam:
          "നിങ്ങൾക്ക് പറയാം: repeat, ചോദ്യം വീണ്ടും കേൾക്കാൻ. skip, മുന്നോട്ട് പോകാൻ. go back, മുൻ "
              "ചോദ്യത്തിലേക്ക് പോകാൻ. pause, നിർത്താൻ. resume, തുടരാൻ. അല്ലെങ്കിൽ cancel, നിലവിലെ "
              "ഉത്തരങ്ങളോടെ സെറ്റപ്പ് നേരത്തെ പൂർത്തിയാക്കാൻ.",
      SupportedLanguage.telugu:
          "మీరు చెప్పవచ్చు: repeat, ప్రశ్నను మళ్ళీ వినడానికి. skip, ముందుకు వెళ్ళడానికి. go back, "
              "మునుపటి ప్రశ్నకు వెళ్ళడానికి. pause, ఆపడానికి. resume, కొనసాగించడానికి. లేదా cancel, "
              "ప్రస్తుత సమాధానాలతో సెటప్‌ను ముందుగానే పూర్తి చేయడానికి.",
    },
    OnboardingPhraseKey.skippedAck: {
      SupportedLanguage.english: "Skipped.",
      SupportedLanguage.tamil: "தவிர்க்கப்பட்டது.",
      SupportedLanguage.hindi: "छोड़ दिया गया.",
      SupportedLanguage.malayalam: "ഒഴിവാക്കി.",
      SupportedLanguage.telugu: "దాటవేయబడింది.",
    },
    OnboardingPhraseKey.goingBackAck: {
      SupportedLanguage.english: "Going back.",
      SupportedLanguage.tamil: "பின்செல்கிறோம்.",
      SupportedLanguage.hindi: "पीछे जा रहे हैं.",
      SupportedLanguage.malayalam: "പിന്നോട്ട് പോകുന്നു.",
      SupportedLanguage.telugu: "వెనక్కి వెళ్తున్నాము.",
    },
    OnboardingPhraseKey.pausedAck: {
      SupportedLanguage.english: "Paused. Say resume, or tap resume, when you're ready to continue.",
      SupportedLanguage.tamil: "இடைநிறுத்தப்பட்டது. தொடர தயாராக இருக்கும்போது resume என்று சொல்லுங்கள் அல்லது தட்டவும்.",
      SupportedLanguage.hindi: "रोका गया. जारी रखने के लिए तैयार होने पर resume कहें या टैप करें.",
      SupportedLanguage.malayalam: "നിർത്തിവച്ചു. തുടരാൻ തയ്യാറാകുമ്പോൾ resume എന്ന് പറയുക അല്ലെങ്കിൽ ടാപ്പ് ചെയ്യുക.",
      SupportedLanguage.telugu: "ఆపివేయబడింది. కొనసాగించడానికి సిద్ధంగా ఉన్నప్పుడు resume అని చెప్పండి లేదా నొక్కండి.",
    },
    OnboardingPhraseKey.resumedAck: {
      SupportedLanguage.english: "Resuming.",
      SupportedLanguage.tamil: "தொடர்கிறோம்.",
      SupportedLanguage.hindi: "जारी रख रहे हैं.",
      SupportedLanguage.malayalam: "തുടരുന്നു.",
      SupportedLanguage.telugu: "కొనసాగిస్తున్నాము.",
    },
    OnboardingPhraseKey.cancelConfirm: {
      SupportedLanguage.english: "Finish setup now with your current answers? Say yes or no.",
      SupportedLanguage.tamil: "தற்போதைய பதில்களுடன் இப்போது அமைப்பை முடிக்கவா? ஆம் அல்லது இல்லை என்று சொல்லுங்கள்.",
      SupportedLanguage.hindi: "क्या अभी वर्तमान उत्तरों के साथ सेटअप समाप्त करें? हाँ या नहीं कहें.",
      SupportedLanguage.malayalam: "നിലവിലെ ഉത്തരങ്ങളോടെ ഇപ്പോൾ സെറ്റപ്പ് പൂർത്തിയാക്കണോ? അതെ അല്ലെങ്കിൽ ഇല്ല എന്ന് പറയുക.",
      SupportedLanguage.telugu: "ప్రస్తుత సమాధానాలతో ఇప్పుడు సెటప్ పూర్తి చేయాలా? అవును లేదా కాదు అని చెప్పండి.",
    },
  };

  static String of(OnboardingPhraseKey key, SupportedLanguage language) {
    final entry = _phrases[key];
    if (entry == null) return '';
    return entry[language] ?? entry[SupportedLanguage.english] ?? '';
  }
}
