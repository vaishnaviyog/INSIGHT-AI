import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/emergency_contact.dart';
import '../../models/user_behaviour_profile.dart';
import '../../models/user_profile.dart';
import '../../services/audio_service.dart';
import '../../services/behaviour_learning_service.dart';
import '../../services/emergency_service.dart';
import '../../services/language/onboarding_phrases.dart';
import '../../services/language/translation_provider.dart';
import '../../services/language_service.dart';
import '../../services/location_service.dart';
import '../../services/user_profile_service.dart';
import '../../services/metrics/runtime_metrics_collector.dart';
import '../frequent_place_resolver.dart';
import 'onboarding_choice_matcher.dart';
import 'voice_command_parser.dart';

/// Thrown internally to unwind the current step and move the step
/// cursor back one — caught only in [VoiceOnboardingController.start]'s
/// main loop. Not a real error; a normal control-flow signal for the
/// "go back" command.
class _GoBackSignal implements Exception {}

/// Thrown internally when the user confirms "cancel" — caught only in
/// [VoiceOnboardingController.start], which then jumps straight to
/// [VoiceOnboardingController._finish] with whatever's been collected
/// so far. There is no account/login here to "cancel out of"; onboarding
/// is a mandatory one-time setup gating [HomeScreen], so "cancel" means
/// "finish now with my current answers," not "abandon and exit the app"
/// — the same principle the Stage 0 review's "must still function
/// correctly even if onboarding is partially skipped" already commits to.
class _CancelSignal implements Exception {}

enum _StepAction { retry, skip }

/// A single recognized answer — either spoken (STT) or tapped (a
/// choice chip / the language buttons / the Resume button). A tapped
/// answer is treated as unambiguous and skips voice confirmation
/// entirely (tapping IS the confirmation); a spoken answer always
/// gets echoed back and confirmed before being accepted.
class _RawAnswer {
  final String? text;
  final bool wasTapped;
  final dynamic tappedValue;
  _RawAnswer.text(this.text)
      : wasTapped = false,
        tappedValue = null;
  _RawAnswer.tapped(this.tappedValue)
      : wasTapped = true,
        text = null;
}

enum _Step {
  name,
  ageGroup,
  visionCondition,
  mobilityAid,
  walkingSpeed,
  warningDistance,
  routePreference,
  emergencyContacts,
  placeHome,
  placeWork,
  placeHospital,
  placeBusStop,
  placeGrocery,
  placePharmacy,
  placeOther,
  voicePreview,
  permissions,
}

/// All voice-onboarding conversation logic — the state machine, every
/// spoken prompt, every listen/confirm/retry cycle, the emergency-
/// contacts and frequent-places sub-flows, and final persistence.
/// [OnboardingScreen] only renders whatever this exposes and forwards
/// taps back via [submitTapChoice] — see this class's field docs for
/// exactly what a thin UI needs to show.
///
/// REUSES, DOES NOT DUPLICATE: [UserProfileService], [LanguageService],
/// [EmergencyService], [BehaviourLearningService], [LocationService],
/// and [AudioService] are the exact same services `OnboardingScreen`
/// used before this stage — same persistence calls, same
/// `resolveFrequentPlaces` helper, same [UserProfile] construction.
/// Only the interaction layer (PageView/buttons -> speak/listen) changed.
class VoiceOnboardingController extends ChangeNotifier {
  final VoidCallback onOnboardingComplete;

  VoiceOnboardingController({required this.onOnboardingComplete});

  /// AUDIT ADD (P1-14): after this many consecutive failed/unmatched
  /// voice attempts on the SAME question, the loop stops calling
  /// listen() again and switches to text-only input instead —
  /// preventing the indefinite "say it again" loop the original spec
  /// explicitly disallowed. Kept as one named constant so it's
  /// consistent and easy to retune across every question type
  /// (_askFreeText/_askChoice/_askYesNoQuestion/_confirmRaw all use
  /// it identically), not a magic number repeated four times.
  static const int _maxVoiceAttemptsBeforeTextFallback = 3;

  /// Test-only mirror of [_maxVoiceAttemptsBeforeTextFallback] — lets
  /// tests reuse the real threshold instead of hardcoding a duplicate
  /// "3" that could silently drift out of sync with production.
  @visibleForTesting
  static int get maxVoiceAttemptsBeforeTextFallback => _maxVoiceAttemptsBeforeTextFallback;

  /// AUDIT FIX (BLOCKER 4): outer safety-net timeout for one voice
  /// attempt — previously 40 seconds, which (on top of
  /// AudioService's own internal listenFor/pauseFor, also reduced —
  /// see that class) meant a genuinely failed/silent attempt could
  /// leave the user waiting the better part of a minute before even
  /// hearing a retry prompt. This is a SAFETY NET only (AudioService's
  /// own onError/status callbacks are expected to resolve first, well
  /// within this window) — not the primary timeout mechanism, so it
  /// stays a little longer than AudioService.defaultListenFor +
  /// AudioService.defaultPauseFor (10s + 2s) to give that normal path
  /// room to complete, without approaching the old 40s.
  static const Duration _voiceAnswerSafetyNetTimeout = Duration(seconds: 15);

  final UserProfileService userProfileService = UserProfileService();
  final LanguageService languageService = LanguageService();
  final EmergencyService emergencyService = EmergencyService();
  final BehaviourLearningService behaviourLearningService = BehaviourLearningService();
  final LocationService locationService = LocationService();
  final AudioService audioService = AudioService();

  SupportedLanguage _language = SupportedLanguage.english;
  SupportedLanguage get language => _language;

  // --- Draft state — identical fields/types to the old OnboardingScreen ---
  String _name = '';
  AgeGroup _ageGroup = AgeGroup.unspecified;
  VisionCondition _visionCondition = VisionCondition.unspecified;
  MobilityAid _mobilityAid = MobilityAid.unspecified;
  WalkingSpeedPreference _walkingSpeed = WalkingSpeedPreference.normal;
  WarningDistancePreference _warningDistance = WarningDistancePreference.normal;
  RoutePreference _routePreference = RoutePreference.balanced;
  List<EmergencyContact> _contacts = [];
  final Map<FrequentPlaceCategory, String> _placeEntries = {};

  // --- UI-facing state ---------------------------------------------------
  String displayText = '';
  String? lastHeardText;
  bool isPaused = false;
  bool isComplete = false;
  bool isSaving = false;
  String? errorMessage;
  double progress = 0.0;

  /// Label -> value, for the CURRENT question only — null when the
  /// current question has no tap fallback (free-text questions like
  /// name/contact details/addresses have none, per the "no typing
  /// required" review requirement; every fixed-choice question,
  /// including language selection, does) — UNLESS [microphoneAvailable]
  /// is false, in which case the UI shows a typed-answer field for
  /// every question regardless of type (see [microphoneAvailable]'s
  /// doc comment).
  Map<String, dynamic>? tapChoices;

  /// AUDIT FIX (mic-permission handling): set once, early in [start],
  /// by explicitly requesting microphone access — see
  /// AudioService.requestMicrophonePermission's doc comment for why
  /// that request happens with a spoken explanation first. When this
  /// is false, [_awaitAnswer] never calls `audioService.listen(...)`
  /// at all (previously it always tried, which just hung silently for
  /// ~40 seconds per question with no way out on free-text steps —
  /// the exact gap flagged in the Stage 1 validation checklist). The
  /// UI (`OnboardingScreen`) shows a typed-answer field for every
  /// question when this is false, wired to [submitTypedAnswer], so
  /// onboarding can still be completed without voice at all.
  bool microphoneAvailable = true;

  /// AUDIT FIX (P0 — onboarding text-fallback keyboard gap): true
  /// whenever [_awaitAnswer] is waiting for a TAPPED/TYPED answer
  /// instead of listening — either because [microphoneAvailable] is
  /// false (denied entirely) OR because THIS specific question has
  /// hit [_maxVoiceAttemptsBeforeTextFallback] failed voice attempts
  /// (the `forceTextOnly` case). Previously the UI (`OnboardingScreen`)
  /// only checked [microphoneAvailable] to decide whether to render a
  /// text field, so the `forceTextOnly` case — mic working fine, but
  /// THIS question failed 3 times — spoke "please type your answer"
  /// with no field to type into: the app told the user to do
  /// something it gave them no way to do. This single flag is what the
  /// UI should actually key its text-field visibility off of.
  bool isTextFallbackActive = false;

  bool get isSpeaking => audioService.isSpeaking;
  bool get isListening => audioService.isListening;

  Completer<_RawAnswer>? _pendingCompleter;
  bool _disposed = false;

  /// Called by the UI when a chip/button is tapped for the current
  /// question (including the Resume button shown while [isPaused]).
  void submitTapChoice(dynamic value) {
    final completer = _pendingCompleter;
    if (completer != null && !completer.isCompleted) {
      audioService.stopListening();
      completer.complete(_RawAnswer.tapped(value));
    }
  }

  /// AUDIT FIX (mic-permission handling): the typed-answer counterpart
  /// to [submitTapChoice] — completes the SAME pending answer with
  /// plain text, which then goes through the exact same command-
  /// parsing/confirmation pipeline a spoken answer would (so "skip"/
  /// "repeat"/etc. still work when typed). Shown by the UI on every
  /// question, not just choice ones, whenever [microphoneAvailable]
  /// is false.
  void submitTypedAnswer(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final completer = _pendingCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(_RawAnswer.text(trimmed));
    }
  }

  Future<void> start() async {
    try {
      await _initializeServices();
      await _requestMicrophonePermission();
      await _runLanguageSelection();

      final steps = _Step.values;
      int index = 0;
      while (index < steps.length) {
        progress = index / steps.length;
        notifyListeners();
        try {
          await _runStep(steps[index]);
          index++;
        } on _GoBackSignal {
          index = (index - 1).clamp(0, steps.length - 1);
        } on _CancelSignal {
          break;
        }
      }
      await _finish();
    } catch (e) {
      // ignore: avoid_print
      print('VoiceOnboardingController.start: unexpected failure: $e');
      errorMessage = 'Something went wrong during setup. Please restart the app to try again.';
      notifyListeners();
    }
  }

  /// AUDIT FIX (mic-permission handling): explicitly requests the
  /// microphone WITH a spoken explanation first, before anything else
  /// tries to listen — this is what used to happen implicitly and
  /// uncontrolled (see AudioService's constructor doc comment) during
  /// the very first `listen()` call, with no prior context and no way
  /// to know it failed until a step silently hung. Runs in English,
  /// same as the rest of this English-only phase before language
  /// selection.
  Future<void> _requestMicrophonePermission() async {
    await audioService.setLanguage(SupportedLanguage.english.ttsLocaleCode);
    await _speakRaw(
        "INSIGHT works best when you can answer with your voice, so it needs microphone access. Requesting that now.");
    microphoneAvailable = await audioService.requestMicrophonePermission();
    if (!microphoneAvailable) {
      await _speakRaw(
          "Microphone access isn't available right now, so you'll type your answers instead. You can still complete setup this way.");
    }
    notifyListeners();
  }

  Future<void> _initializeServices() async {
    await userProfileService.initialize();
    await languageService.initialize();
    await emergencyService.initialize();
    await behaviourLearningService.initialize();

    final existingProfile = userProfileService.profile;
    _name = existingProfile.name;
    _ageGroup = existingProfile.ageGroup;
    _visionCondition = existingProfile.visionCondition;
    _mobilityAid = existingProfile.mobilityAid;
    _walkingSpeed = existingProfile.walkingSpeedPreference;
    _warningDistance = existingProfile.warningDistancePreference;
    _routePreference = existingProfile.routePreference;
    _contacts = emergencyService.contacts;
    _placeEntries.addEntries(existingProfile.frequentPlaces.map((p) => MapEntry(p.category, p.label)));
  }

  // ---------------------------------------------------------------------
  // Language selection (English-only phase — requirements 1-3)
  // ---------------------------------------------------------------------

  Future<void> _runLanguageSelection() async {
    await audioService.setLanguage(SupportedLanguage.english.ttsLocaleCode);
    await _speakRaw("Welcome to INSIGHT. Let's set things up together, using your voice.");
    await _speakRaw(
        "Which language would you like to use? Say, or tap: English, Tamil, Hindi, Malayalam, or Telugu.");

    tapChoices = {
      'English': SupportedLanguage.english,
      'Tamil': SupportedLanguage.tamil,
      'Hindi': SupportedLanguage.hindi,
      'Malayalam': SupportedLanguage.malayalam,
      'Telugu': SupportedLanguage.telugu,
    };
    notifyListeners();

    SupportedLanguage? selected;
    while (selected == null) {
      // Deliberately still English-locale STT here — this whole phase
      // is English-only by requirement 1, before any switch happens.
      final answer = await _awaitAnswer(localeOverride: SupportedLanguage.english.sttLocaleId);
      if (answer.wasTapped) {
        selected = answer.tappedValue as SupportedLanguage;
        break;
      }
      final raw = answer.text;
      if (raw == null) {
        await _speakRaw("Sorry, I didn't catch that. Let me ask again.");
        continue;
      }
      selected = _matchLanguageWord(raw);
      if (selected == null) {
        await _speakRaw("Sorry, I didn't catch that. Let me ask again.");
      }
    }

    tapChoices = null;
    _language = selected;
    await languageService.setLanguage(selected);
    await audioService.setLanguage(selected.ttsLocaleCode); // switch TTS immediately (requirement 3)
    await _speakPhrase(OnboardingPhraseKey.continuingSetup); // first line spoken in the new language
  }

  SupportedLanguage? _matchLanguageWord(String text) {
    final normalized = text.trim().toLowerCase();
    if (normalized.contains('english')) return SupportedLanguage.english;
    if (normalized.contains('tamil')) return SupportedLanguage.tamil;
    if (normalized.contains('hindi')) return SupportedLanguage.hindi;
    if (normalized.contains('malayalam')) return SupportedLanguage.malayalam;
    if (normalized.contains('telugu')) return SupportedLanguage.telugu;
    return null;
  }

  // ---------------------------------------------------------------------
  // Step dispatch
  // ---------------------------------------------------------------------

  Future<void> _runStep(_Step step) async {
    switch (step) {
      case _Step.name:
        final v = await _askFreeText(OnboardingPhraseKey.askName);
        if (v != null) _name = v;
        break;
      case _Step.ageGroup:
        final v = await _askChoice<AgeGroup>(
          promptKey: OnboardingPhraseKey.askAgeGroup,
          matcher: OnboardingChoiceMatcher.matchAgeGroup,
          tapOptions: {
            'Below 18': AgeGroup.below18,
            '18–40': AgeGroup.age18to40,
            '41–60': AgeGroup.age41to60,
            'Above 60': AgeGroup.above60,
          },
        );
        if (v != null) _ageGroup = v;
        break;
      case _Step.visionCondition:
        final v = await _askChoice<VisionCondition>(
          promptKey: OnboardingPhraseKey.askVisionCondition,
          matcher: OnboardingChoiceMatcher.matchVisionCondition,
          tapOptions: {
            'Completely Blind': VisionCondition.completelyBlind,
            'Low Vision': VisionCondition.lowVision,
            'Progressive Vision Loss': VisionCondition.progressiveVisionLoss,
            'Other': VisionCondition.other,
          },
        );
        if (v != null) _visionCondition = v;
        break;
      case _Step.mobilityAid:
        final v = await _askChoice<MobilityAid>(
          promptKey: OnboardingPhraseKey.askMobilityAid,
          matcher: OnboardingChoiceMatcher.matchMobilityAid,
          tapOptions: {
            'White Cane': MobilityAid.whiteCane,
            'Guide Dog': MobilityAid.guideDog,
            'None': MobilityAid.none,
            'Other': MobilityAid.other,
          },
        );
        if (v != null) _mobilityAid = v;
        break;
      case _Step.walkingSpeed:
        final v = await _askChoice<WalkingSpeedPreference>(
          promptKey: OnboardingPhraseKey.askWalkingSpeed,
          matcher: OnboardingChoiceMatcher.matchWalkingSpeed,
          tapOptions: {
            'Slow': WalkingSpeedPreference.slow,
            'Normal': WalkingSpeedPreference.normal,
            'Fast': WalkingSpeedPreference.fast,
          },
        );
        if (v != null) _walkingSpeed = v;
        break;
      case _Step.warningDistance:
        final v = await _askChoice<WarningDistancePreference>(
          promptKey: OnboardingPhraseKey.askWarningDistance,
          matcher: OnboardingChoiceMatcher.matchWarningDistance,
          tapOptions: {
            'Very Early': WarningDistancePreference.veryEarly,
            'Early': WarningDistancePreference.early,
            'Normal': WarningDistancePreference.normal,
            'Late': WarningDistancePreference.late,
          },
        );
        if (v != null) _warningDistance = v;
        break;
      case _Step.routePreference:
        final v = await _askChoice<RoutePreference>(
          promptKey: OnboardingPhraseKey.askRoutePreference,
          matcher: OnboardingChoiceMatcher.matchRoutePreference,
          tapOptions: {
            'Safest': RoutePreference.safest,
            'Balanced': RoutePreference.balanced,
            'Fastest': RoutePreference.fastest,
          },
        );
        if (v != null) _routePreference = v;
        break;
      case _Step.emergencyContacts:
        await _runEmergencyContactsStep();
        break;
      case _Step.placeHome:
        await _speakPhrase(OnboardingPhraseKey.placesIntro);
        await _runPlaceStep(FrequentPlaceCategory.home, OnboardingPhraseKey.askPlaceHome);
        break;
      case _Step.placeWork:
        await _runPlaceStep(FrequentPlaceCategory.workOrCollege, OnboardingPhraseKey.askPlaceWork);
        break;
      case _Step.placeHospital:
        await _runPlaceStep(FrequentPlaceCategory.hospital, OnboardingPhraseKey.askPlaceHospital);
        break;
      case _Step.placeBusStop:
        await _runPlaceStep(FrequentPlaceCategory.busStop, OnboardingPhraseKey.askPlaceBusStop);
        break;
      case _Step.placeGrocery:
        await _runPlaceStep(FrequentPlaceCategory.groceryStore, OnboardingPhraseKey.askPlaceGrocery);
        break;
      case _Step.placePharmacy:
        await _runPlaceStep(FrequentPlaceCategory.pharmacy, OnboardingPhraseKey.askPlacePharmacy);
        break;
      case _Step.placeOther:
        await _runPlaceStep(FrequentPlaceCategory.other, OnboardingPhraseKey.askPlaceOther);
        break;
      case _Step.voicePreview:
        await _speakPhrase(OnboardingPhraseKey.voicePreviewIntro);
        // Reuses the SAME LanguageService.speak pipeline production
        // hazard warnings use — this phrase is already covered by
        // StaticTranslationProvider's hazard-warning template, unlike
        // every other line in this controller (see OnboardingPhrases'
        // doc comment for why onboarding-specific lines use a
        // dedicated dictionary instead of that pattern-matcher).
        await languageService.speak(audioService, 'Obstacle ahead. Please move slightly left.');
        break;
      case _Step.permissions:
        await _speakPhrase(OnboardingPhraseKey.permissionsIntro);
        await _requestPermissions();
        break;
    }
  }

  Future<void> _runPlaceStep(FrequentPlaceCategory category, OnboardingPhraseKey promptKey) async {
    final v = await _askFreeText(promptKey);
    if (v != null) {
      _placeEntries[category] = v;
    } else {
      _placeEntries.remove(category);
    }
  }

  /// Emergency contacts is a variable-length loop, unlike every other
  /// step — SIMPLIFICATION, DOCUMENTED: "go back" said while adding a
  /// contact restarts entering THAT contact (re-asks its name) rather
  /// than unwinding through a full undo history of a dynamic list;
  /// "go back" said before any contact has been started in this
  /// session propagates outward to the previous top-level step
  /// normally, via [firstPrompt].
  Future<void> _runEmergencyContactsStep() async {
    await _speakPhrase(OnboardingPhraseKey.emergencyIntro);
    bool firstPrompt = true;
    while (true) {
      String? name;
      try {
        name = await _askFreeText(OnboardingPhraseKey.askContactName);
      } on _GoBackSignal {
        if (firstPrompt) rethrow;
        continue;
      }
      firstPrompt = false;
      if (name == null) return;

      String? phone;
      try {
        phone = await _askFreeText(OnboardingPhraseKey.askContactPhone);
      } on _GoBackSignal {
        continue;
      }
      if (phone == null) continue;

      _contacts = [
        ..._contacts,
        EmergencyContact(id: DateTime.now().millisecondsSinceEpoch.toString(), name: name, phoneNumber: phone),
      ];

      final addAnother = await _askYesNoQuestion(OnboardingPhraseKey.askAddAnotherContact);
      if (addAnother != true) return;
    }
  }

  // ---------------------------------------------------------------------
  // Generic question helpers
  // ---------------------------------------------------------------------

  Future<String?> _askFreeText(OnboardingPhraseKey promptKey) async {
    int attempt = 0;
    while (true) {
      // AUDIT ADD (P1-14): once voice has failed this question
      // _maxVoiceAttemptsBeforeTextFallback times, stop asking the
      // user to repeat themselves by voice — switch to a text-only
      // wait instead (see _awaitAnswer's forceTextOnly doc comment).
      final forceTextOnly = attempt >= _maxVoiceAttemptsBeforeTextFallback;
      await _speakPhrase(promptKey);
      if (forceTextOnly) await _speakPhrase(OnboardingPhraseKey.pleaseTypeAnswer);
      final answer = await _awaitAnswer(attempt: attempt, forceTextOnly: forceTextOnly);
      attempt++;
      if (answer.wasTapped) return answer.tappedValue as String?;
      final raw = answer.text;
      if (raw == null) {
        // Structurally only reachable when NOT forceTextOnly — a
        // forced text-only wait has no listen()/timeout to fail.
        await _speakPhrase(OnboardingPhraseKey.sorryRetry);
        continue; // requirement 10: repeat only the current question
      }
      final command = VoiceCommandParser.match(raw, _language);
      if (command != null) {
        final action = await _handleCommand(command);
        if (action == _StepAction.retry) continue;
        if (action == _StepAction.skip) return null;
      }
      final confirmed = await _confirmRaw(raw);
      if (confirmed) return raw;
      // rejected — loop re-asks the original prompt from scratch
    }
  }

  Future<T?> _askChoice<T>({
    required OnboardingPhraseKey promptKey,
    required T? Function(String text, SupportedLanguage lang) matcher,
    required Map<String, T> tapOptions,
  }) async {
    int attempt = 0;
    while (true) {
      final forceTextOnly = attempt >= _maxVoiceAttemptsBeforeTextFallback;
      await _speakPhrase(promptKey);
      if (forceTextOnly) await _speakPhrase(OnboardingPhraseKey.pleaseTypeAnswer);
      tapChoices = tapOptions;
      notifyListeners();
      final answer = await _awaitAnswer(attempt: attempt, forceTextOnly: forceTextOnly);
      attempt++;
      tapChoices = null;
      if (answer.wasTapped) return answer.tappedValue as T;
      final raw = answer.text;
      if (raw == null) {
        await _speakPhrase(OnboardingPhraseKey.sorryRetry);
        continue;
      }
      final command = VoiceCommandParser.match(raw, _language);
      if (command != null) {
        final action = await _handleCommand(command);
        if (action == _StepAction.retry) continue;
        if (action == _StepAction.skip) return null;
      }
      final matched = matcher(raw, _language);
      if (matched == null) {
        await _speakPhrase(OnboardingPhraseKey.sorryRetry);
        continue;
      }
      final confirmed = await _confirmRaw(raw);
      if (confirmed) return matched;
    }
  }

  Future<bool> _askYesNoQuestion(OnboardingPhraseKey promptKey) async {
    int attempt = 0;
    while (true) {
      final forceTextOnly = attempt >= _maxVoiceAttemptsBeforeTextFallback;
      await _speakPhrase(promptKey);
      if (forceTextOnly) await _speakPhrase(OnboardingPhraseKey.pleaseTypeAnswer);
      final answer = await _awaitAnswer(attempt: attempt, forceTextOnly: forceTextOnly);
      attempt++;
      if (answer.wasTapped) return answer.tappedValue as bool;
      final raw = answer.text;
      if (raw == null) {
        await _speakPhrase(OnboardingPhraseKey.sorryRetry);
        continue;
      }
      final command = VoiceCommandParser.match(raw, _language);
      if (command != null) {
        final action = await _handleCommand(command);
        if (action == _StepAction.retry) continue;
        if (action == _StepAction.skip) return false;
      }
      final yesNo = VoiceCommandParser.matchYesNo(raw, _language);
      if (yesNo == null) {
        await _speakPhrase(OnboardingPhraseKey.pleaseYesOrNo);
        continue;
      }
      return yesNo;
    }
  }

  /// Echoes [raw] back and asks for yes/no confirmation. A "skip"
  /// command said DURING confirmation is treated as rejection (not a
  /// true skip — true skip must be said in response to the question
  /// itself), so the caller's loop re-asks from scratch.
  Future<bool> _confirmRaw(String raw) async {
    int attempt = 0;
    while (true) {
      final forceTextOnly = attempt >= _maxVoiceAttemptsBeforeTextFallback;
      await _speakPhrase(OnboardingPhraseKey.heardPrefix);
      await audioService.speak(raw); // echo the user's own words, untranslated
      await _speakPhrase(OnboardingPhraseKey.isThatCorrect);
      if (forceTextOnly) await _speakPhrase(OnboardingPhraseKey.pleaseTypeAnswer);
      final answer = await _awaitAnswer(attempt: attempt, forceTextOnly: forceTextOnly);
      attempt++;
      if (answer.wasTapped) return answer.tappedValue as bool;
      final text = answer.text;
      if (text == null) {
        await _speakPhrase(OnboardingPhraseKey.sorryRetry);
        continue;
      }
      final command = VoiceCommandParser.match(text, _language);
      if (command != null) {
        final action = await _handleCommand(command);
        if (action == _StepAction.retry) continue; // re-echo + re-ask
        if (action == _StepAction.skip) return false;
      }
      final yesNo = VoiceCommandParser.matchYesNo(text, _language);
      if (yesNo == null) {
        await _speakPhrase(OnboardingPhraseKey.pleaseYesOrNo);
        continue;
      }
      return yesNo;
    }
  }

  // ---------------------------------------------------------------------
  // Global commands
  // ---------------------------------------------------------------------

  Future<_StepAction> _handleCommand(VoiceCommand command) async {
    switch (command) {
      case VoiceCommand.repeat:
        return _StepAction.retry;
      case VoiceCommand.skip:
        await _speakPhrase(OnboardingPhraseKey.skippedAck);
        return _StepAction.skip;
      case VoiceCommand.goBack:
        await _speakPhrase(OnboardingPhraseKey.goingBackAck);
        throw _GoBackSignal();
      case VoiceCommand.help:
        await _speakPhrase(OnboardingPhraseKey.helpText);
        return _StepAction.retry;
      case VoiceCommand.cancel:
        final confirmed = await _confirmCancel();
        if (confirmed) throw _CancelSignal();
        return _StepAction.retry;
      case VoiceCommand.pause:
        await _pauseAndWaitForResume();
        return _StepAction.retry;
      case VoiceCommand.resume:
        return _StepAction.retry; // 'resume' said while not paused — harmless no-op
    }
  }

  Future<bool> _confirmCancel() async {
    while (true) {
      await _speakPhrase(OnboardingPhraseKey.cancelConfirm);
      final answer = await _awaitAnswer();
      if (answer.wasTapped) return answer.tappedValue as bool;
      final text = answer.text;
      if (text == null) continue;
      final yesNo = VoiceCommandParser.matchYesNo(text, _language);
      // A nested "cancel" or unrecognized answer here is treated as
      // "no, keep going" rather than opening a recursive confirmation
      // — deliberate simplification to avoid a confirm-within-confirm
      // loop.
      return yesNo ?? false;
    }
  }

  /// Preserves conversation state across interruptions (requirement 9):
  /// nothing in draft state is touched here — pausing/resuming just
  /// suspends the listen loop and, once resumed, the caller re-asks
  /// the exact same question it was already on.
  Future<void> _pauseAndWaitForResume() async {
    isPaused = true;
    notifyListeners();
    await _speakPhrase(OnboardingPhraseKey.pausedAck);
    while (true) {
      final answer = await _awaitAnswer(pausedMode: true);
      if (answer.wasTapped) break; // UI's Resume button
      final text = answer.text;
      if (text == null) continue; // keep waiting quietly
      final command = VoiceCommandParser.match(text, _language);
      if (command == VoiceCommand.resume) break;
      if (command == VoiceCommand.help) await _speakPhrase(OnboardingPhraseKey.helpText);
      // anything else said while paused is ignored — still paused
    }
    isPaused = false;
    await _speakPhrase(OnboardingPhraseKey.resumedAck);
    notifyListeners();
  }

  // ---------------------------------------------------------------------
  // Speech I/O
  // ---------------------------------------------------------------------

  Future<void> _speakPhrase(OnboardingPhraseKey key) => _speakRaw(OnboardingPhrases.of(key, _language));

  Future<void> _speakRaw(String text) async {
    if (_disposed) return;
    displayText = text;
    notifyListeners();
    await audioService.speak(text);
  }

  Future<_RawAnswer> _awaitAnswer({
    String? localeOverride,
    bool pausedMode = false,
    int attempt = 0,
    bool forceTextOnly = false,
  }) async {
    final completer = Completer<_RawAnswer>();
    _pendingCompleter = completer;
    notifyListeners();

    // AUDIT FIX (mic-permission handling): previously always called
    // listen() here regardless of whether the microphone was actually
    // available, which — when permission was denied — hit
    // AudioService's silent "not initialized" branch and never
    // resolved on its own, relying entirely on the 40s timeout below
    // to eventually surface a retry. That retry then called listen()
    // again, repeating the same silent failure indefinitely on any
    // free-text step (no tap fallback existed there). When the
    // microphone isn't available, this now skips the listen() call
    // entirely and waits ONLY for a tap or typed answer — both of
    // which OnboardingScreen always offers once [microphoneAvailable]
    // is false — with no arbitrary timeout, since there's no STT
    // session in flight to time out.
    //
    // AUDIT ADD (P1-14): [forceTextOnly] reuses this exact same
    // wait-for-tap/type path once a question has already failed
    // _maxVoiceAttemptsBeforeTextFallback times — the mic may be
    // perfectly available, but repeating the same failed listen()
    // call again is exactly the "endless retry" loop the original
    // spec disallowed.
    if (!microphoneAvailable || forceTextOnly) {
      // AUDIT FIX (P0 — onboarding text-fallback keyboard gap):
      // audioService.listen() only stops a PRIOR in-flight STT
      // session when STARTING a new one (see its own doc comment on
      // "preventing multiple simultaneous listeners") — this branch
      // never calls listen() again, so without an explicit stop here,
      // a recognizer session from the last voice attempt that
      // resolved via this method's own safety-net timeout below
      // (rather than the plugin's own status/error callback actually
      // finishing) could keep running silently for the rest of this
      // question. A late callback from it can't corrupt the typed
      // answer — each _awaitAnswer call owns its own Completer, and
      // submitTypedAnswer/submitTapChoice only ever touch
      // [_pendingCompleter], so a stale closure completing an old,
      // already-resolved Completer is a harmless no-op — but the mic
      // must actually stop once the user is looking at a text field,
      // not keep secretly listening in the background.
      if (forceTextOnly) await audioService.stopListening();
      isTextFallbackActive = true;
      notifyListeners();
      final result = await completer.future;
      isTextFallbackActive = false;
      _pendingCompleter = null;
      notifyListeners();
      return result;
    }

    final latencyStopwatch = Stopwatch()..start();
    await audioService.listen(
      (text) {
        lastHeardText = text;
        if (!completer.isCompleted) completer.complete(_RawAnswer.text(text));
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete(_RawAnswer.text(null));
      },
      localeId: localeOverride ?? _language.sttLocaleId,
    );
    final result = await completer.future.timeout(
      _voiceAnswerSafetyNetTimeout,
      onTimeout: () => _RawAnswer.text(null),
    );
    latencyStopwatch.stop();
    // Phase 1H (evaluation logging): a tapped/typed answer bypassed
    // STT entirely, so it isn't a recognition event — only genuine
    // voice attempts (spoken text OR a spoken attempt that failed)
    // are logged here.
    if (!result.wasTapped) {
      RuntimeMetricsCollector.instance.recordVoiceRecognitionEvent(
        language: _language.name,
        recognizedText: result.text ?? '',
        success: result.text != null,
        confidence: audioService.lastConfidence,
        latencyMs: latencyStopwatch.elapsedMicroseconds / 1000.0,
        retryCount: attempt,
      );
    }
    _pendingCompleter = null;
    notifyListeners();
    return result;
  }

  /// Test-only entry point into [_awaitAnswer] — the answer-processing
  /// wait it drives is otherwise only reachable through the full
  /// [start] conversation loop (real Hive/permission/speech-plugin
  /// services, no test doubles), so this calls the EXACT SAME private
  /// method production code uses rather than re-implementing any of
  /// its logic, letting tests drive the [forceTextOnly] wait/resolve
  /// cycle directly. Returns a plain record (not the private
  /// [_RawAnswer]) so it's usable from another library. Only ever call
  /// this with [forceTextOnly] true (or leave [microphoneAvailable]
  /// false) in tests — the non-force branch calls
  /// `audioService.listen(...)`, which needs a real speech-recognition
  /// platform this test harness doesn't have.
  @visibleForTesting
  Future<({String? text, bool wasTapped, dynamic tappedValue})> debugAwaitAnswerForTest({
    int attempt = 0,
    bool forceTextOnly = false,
  }) async {
    final answer = await _awaitAnswer(attempt: attempt, forceTextOnly: forceTextOnly);
    return (text: answer.text, wasTapped: answer.wasTapped, tappedValue: answer.tappedValue);
  }

  // ---------------------------------------------------------------------
  // Permissions (same request set as the old PermissionsPage)
  // ---------------------------------------------------------------------

  Future<void> _requestPermissions() async {
    try {
      await [
        Permission.camera,
        Permission.location,
        Permission.microphone,
        Permission.notification,
      ].request();
    } catch (e) {
      // ignore: avoid_print
      print('VoiceOnboardingController: permission request failed (PermissionGateScreen will catch any denial): $e');
    }
  }

  // ---------------------------------------------------------------------
  // Finish — identical persistence logic to the old OnboardingScreen._finish
  // ---------------------------------------------------------------------

  Future<void> _finish() async {
    isSaving = true;
    notifyListeners();

    try {
      final resolvedPlaces = await resolveFrequentPlaces(locationService, _placeEntries);

      behaviourLearningService.seedFromOnboarding(
        preferredWalkingSpeedMetersPerSecond: _walkingSpeed.metersPerSecond,
        initialFrequentPlaces: resolvedPlaces
            .map((p) => VisitedLocation(
                  latitude: p.latitude,
                  longitude: p.longitude,
                  visitCount: 3,
                  lastVisited: DateTime.now(),
                ))
            .toList(),
      );

      await emergencyService.syncContacts(_contacts);

      final profile = UserProfile(
        name: _name,
        ageGroup: _ageGroup,
        visionCondition: _visionCondition,
        mobilityAid: _mobilityAid,
        walkingSpeedPreference: _walkingSpeed,
        warningDistancePreference: _warningDistance,
        routePreference: _routePreference,
        frequentPlaces: resolvedPlaces,
      );
      await userProfileService.saveProfile(profile);
      await userProfileService.completeOnboarding();

      await _speakPhrase(OnboardingPhraseKey.finishMessage);

      isSaving = false;
      isComplete = true;
      notifyListeners();
      onOnboardingComplete();
    } catch (e) {
      // ignore: avoid_print
      print('VoiceOnboardingController._finish failed: $e');
      isSaving = false;
      errorMessage = 'Something went wrong saving your setup. Please try again.';
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    behaviourLearningService.dispose();
    emergencyService.dispose();
    languageService.dispose();
    userProfileService.dispose();
    audioService.dispose();
    super.dispose();
  }
}
