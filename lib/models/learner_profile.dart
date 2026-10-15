import 'package:flutter/foundation.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/models/language.dart';

/// How much scaffolding the tutor provides.
///
/// Each level changes three concrete things: the system-prompt instruction, the
/// sentence budget the model is asked to respect, and the TTS speaking rate.
enum ProficiencyLevel {
  beginner(
    label: 'Beginner',
    cefr: 'A1–A2',
    description: 'Short sentences, lots of support, slow speech. '
        'Corrections are frequent but gentle.',
    speechRate: 0.42,
    sentenceBudget: 2,
    maxWords: 14,
    explainInNative: true,
    allowNativeHelp: true,
  ),
  intermediate(
    label: 'Intermediate',
    cefr: 'B1–B2',
    description: 'Everyday conversations with natural pacing. '
        'Corrections focus on the mistakes that break meaning.',
    speechRate: 0.5,
    sentenceBudget: 3,
    maxWords: 26,
    explainInNative: false,
    allowNativeHelp: true,
  ),
  advanced(
    label: 'Advanced',
    cefr: 'C1–C2',
    description: 'Fast, idiomatic speech with nuance. Corrections are precise '
        'and about style, register and collocation.',
    speechRate: 0.58,
    sentenceBudget: 4,
    maxWords: 42,
    explainInNative: false,
    allowNativeHelp: false,
  );

  const ProficiencyLevel({
    required this.label,
    required this.cefr,
    required this.description,
    required this.speechRate,
    required this.sentenceBudget,
    required this.maxWords,
    required this.explainInNative,
    required this.allowNativeHelp,
  });

  final String label;
  final String cefr;
  final String description;

  /// `flutter_tts` rate (0.0–1.0). Android maps 1.0 to "normal"; ~0.5 is a
  /// comfortable tutor pace and 0.42 gives a beginner time to parse.
  final double speechRate;

  /// How many sentences the reply should contain at most.
  final int sentenceBudget;

  /// Hard word ceiling for `reply_target_language`.
  final int maxWords;

  /// Whether the *explanation* should be written in the learner's native
  /// language instead of the target language.
  final bool explainInNative;

  /// Whether the model may fall back to the native language when the learner
  /// is clearly lost (mixed-language replies).
  final bool allowNativeHelp;

  /// The instruction line injected into the system prompt.
  String get promptInstruction {
    switch (this) {
      case ProficiencyLevel.beginner:
        return 'The learner is a beginner ($cefr). Use short, simple sentences '
            'with high-frequency vocabulary. Speak slowly. If they make a '
            'mistake, correct it kindly and give the corrected sentence in '
            'full.';
      case ProficiencyLevel.intermediate:
        return 'The learner is intermediate ($cefr). Speak at a natural pace '
            'with everyday vocabulary and idioms. Correct the mistakes that '
            'affect meaning, and mention the rule behind the fix in one short '
            'line.';
      case ProficiencyLevel.advanced:
        return 'The learner is advanced ($cefr). Speak naturally and '
            'idiomatically, as you would to a native speaker. Push them with '
            'richer vocabulary and subtle register. Corrections should be about '
            'nuance, collocation and style.';
    }
  }

  static ProficiencyLevel fromName(String? name) {
    if (name == null) return ProficiencyLevel.beginner;
    final String needle = name.toLowerCase();
    for (final ProficiencyLevel level in ProficiencyLevel.values) {
      if (level.name == needle || level.label.toLowerCase() == needle) {
        return level;
      }
    }
    return ProficiencyLevel.beginner;
  }
}

/// The learner's persistent configuration.
///
/// Immutable: the `ProfileNotifier` swaps whole instances so Riverpod's
/// `select`-based rebuilds stay cheap and predictable. Persisted through
/// `shared_preferences` — see `ProfileRepository`.
@immutable
class LearnerProfile {
  const LearnerProfile({
    required this.nativeLanguage,
    required this.targetLanguage,
    required this.proficiency,
    this.onboarded = false,
    this.autoListen = true,
    this.showTranslations = true,
    this.haptics = true,
    this.ttsRateOverride,
    this.ttsVoiceName,
    this.dailyGoalMinutes = 15,
    this.selectedModelId = '',
    this.customModelUrl,
    this.customModelName,
    this.sttOnDeviceOnly = true,
    this.soundEffects = true,
    this.streakCount = 0,
    this.lastPracticeDay,
  });

  /// The language explanations are (optionally) written in.
  final AppLanguage nativeLanguage;

  /// The language being taught. Also the language the tutor *speaks*.
  final AppLanguage targetLanguage;

  final ProficiencyLevel proficiency;

  /// False until the onboarding wizard is completed — gates the whole app.
  final bool onboarded;

  /// Re-open the microphone automatically after the tutor finishes speaking.
  /// This is the most user-visible part of the anti-loop contract, so it is
  /// opt-in at the settings level and strictly gated in the controller.
  final bool autoListen;

  /// Show the native-language translation under each tutor bubble.
  final bool showTranslations;

  final bool haptics;
  final bool soundEffects;

  /// Null means "follow the proficiency level" ([effectiveTtsRate]).
  final double? ttsRateOverride;

  /// Preferred voice name from `flutter_tts.getVoices()`; null = engine default.
  final String? ttsVoiceName;

  final int dailyGoalMinutes;

  /// Id of the selected catalogue entry (`qwen2.5-1.5b-instruct-q4_k_m`),
  /// or `custom` when the learner pasted their own GGUF URL.
  final String selectedModelId;

  final String? customModelUrl;
  final String? customModelName;

  /// Prefer `SpeechRecognizer` in on-device mode. Falls back to the network
  /// recogniser automatically when the device has no offline language pack —
  /// the pipeline reports which mode actually ran.
  final bool sttOnDeviceOnly;

  final int streakCount;

  /// `yyyy-MM-dd` of the last practice day, used for streak bookkeeping.
  final String? lastPracticeDay;

  // ── Derived ───────────────────────────────────────────────────────────────

  double get effectiveTtsRate => ttsRateOverride ?? proficiency.speechRate;

  /// Grammar focus points that are worth injecting into the prompt: the target
  /// language's known pitfalls, trimmed to the three that matter most.
  List<String> get grammarFocusPoints =>
      targetLanguage.grammarFocusPoints.take(3).toList();

  bool get isSameLanguagePair => nativeLanguage.code == targetLanguage.code;

  bool get hasModel => selectedModelId.isNotEmpty;

  bool get isCustomModel => selectedModelId == 'custom';

  String get modelDisplayName {
    if (isCustomModel) return customModelName ?? 'Custom GGUF model';
    return selectedModelId;
  }

  /// Whether the learner practices in a mode where the tutor may answer in the
  /// native language. Advanced learners get an immersive session.
  bool get allowsNativeFallback => proficiency.allowNativeHelp;

  // ── Copying ───────────────────────────────────────────────────────────────

  LearnerProfile copyWith({
    AppLanguage? nativeLanguage,
    AppLanguage? targetLanguage,
    ProficiencyLevel? proficiency,
    bool? onboarded,
    bool? autoListen,
    bool? showTranslations,
    bool? haptics,
    bool? soundEffects,
    double? ttsRateOverride,
    bool clearTtsRateOverride = false,
    String? ttsVoiceName,
    bool clearTtsVoiceName = false,
    int? dailyGoalMinutes,
    String? selectedModelId,
    String? customModelUrl,
    String? customModelName,
    bool? sttOnDeviceOnly,
    int? streakCount,
    String? lastPracticeDay,
    bool clearLastPracticeDay = false,
  }) {
    return LearnerProfile(
      nativeLanguage: nativeLanguage ?? this.nativeLanguage,
      targetLanguage: targetLanguage ?? this.targetLanguage,
      proficiency: proficiency ?? this.proficiency,
      onboarded: onboarded ?? this.onboarded,
      autoListen: autoListen ?? this.autoListen,
      showTranslations: showTranslations ?? this.showTranslations,
      haptics: haptics ?? this.haptics,
      soundEffects: soundEffects ?? this.soundEffects,
      ttsRateOverride:
          clearTtsRateOverride ? null : (ttsRateOverride ?? this.ttsRateOverride),
      ttsVoiceName: clearTtsVoiceName ? null : (ttsVoiceName ?? this.ttsVoiceName),
      dailyGoalMinutes: dailyGoalMinutes ?? this.dailyGoalMinutes,
      selectedModelId: selectedModelId ?? this.selectedModelId,
      customModelUrl: customModelUrl ?? this.customModelUrl,
      customModelName: customModelName ?? this.customModelName,
      sttOnDeviceOnly: sttOnDeviceOnly ?? this.sttOnDeviceOnly,
      streakCount: streakCount ?? this.streakCount,
      lastPracticeDay:
          clearLastPracticeDay ? null : (lastPracticeDay ?? this.lastPracticeDay),
    );
  }

  /// The level-appropriate sample rate for the recogniser, in Hz. Not all
  /// engines accept a value; `speech_to_text` ignores unsupported rates.
  int get sttSampleRate => 16000;

  // ── Persistence ───────────────────────────────────────────────────────────

  Map<String, Object?> toPreferences() => <String, Object?>{
        PrefKeys.onboarded: onboarded,
        PrefKeys.nativeLanguage: nativeLanguage.code,
        PrefKeys.targetLanguage: targetLanguage.code,
        PrefKeys.proficiency: proficiency.name,
        PrefKeys.autoListen: autoListen,
        PrefKeys.showTranslations: showTranslations,
        PrefKeys.haptics: haptics,
        PrefKeys.ttsRate: ttsRateOverride,
        PrefKeys.ttsVoiceName: ttsVoiceName,
        PrefKeys.dailyGoalMinutes: dailyGoalMinutes,
        PrefKeys.selectedModelId: selectedModelId,
        PrefKeys.customModelUrl: customModelUrl,
        PrefKeys.customModelName: customModelName,
        'k100_sound_effects': soundEffects,
        'k100_stt_on_device': sttOnDeviceOnly,
        'k100_streak': streakCount,
        'k100_last_practice_day': lastPracticeDay,
      };

  /// Rebuilds a profile from `shared_preferences`. Every value is optional, so a
  /// partially-written (or upgraded) prefs store still yields a usable profile.
  static LearnerProfile fromPreferences({
    required AppLanguage Function() fallbackNative,
    required AppLanguage Function() fallbackTarget,
    required Map<String, Object?> values,
  }) {
    AppLanguage native = fallbackNative();
    AppLanguage target = fallbackTarget();

    final Object? nativeCode = values[PrefKeys.nativeLanguage];
    if (nativeCode is String && nativeCode.isNotEmpty) {
      native = Languages.byCode(nativeCode);
    }
    final Object? targetCode = values[PrefKeys.targetLanguage];
    if (targetCode is String && targetCode.isNotEmpty) {
      target = Languages.byCode(targetCode);
    }

    final Object? rawRate = values[PrefKeys.ttsRate];
    final Object? rawVoice = values[PrefKeys.ttsVoiceName];
    final Object? rawGoal = values[PrefKeys.dailyGoalMinutes];
    final Object? rawStreak = values['k100_streak'];

    return LearnerProfile(
      nativeLanguage: native,
      targetLanguage: target,
      proficiency: ProficiencyLevel.fromName(values[PrefKeys.proficiency] as String?),
      onboarded: values[PrefKeys.onboarded] as bool? ?? false,
      autoListen: values[PrefKeys.autoListen] as bool? ?? true,
      showTranslations: values[PrefKeys.showTranslations] as bool? ?? true,
      haptics: values[PrefKeys.haptics] as bool? ?? true,
      soundEffects: values['k100_sound_effects'] as bool? ?? true,
      ttsRateOverride: rawRate is num ? rawRate.toDouble() : null,
      ttsVoiceName: rawVoice is String && rawVoice.isNotEmpty ? rawVoice : null,
      dailyGoalMinutes: rawGoal is int ? rawGoal.clamp(5, 60) : 15,
      selectedModelId: values[PrefKeys.selectedModelId] as String? ?? '',
      customModelUrl: values[PrefKeys.customModelUrl] as String?,
      customModelName: values[PrefKeys.customModelName] as String?,
      sttOnDeviceOnly: values['k100_stt_on_device'] as bool? ?? true,
      streakCount: rawStreak is int ? rawStreak : 0,
      lastPracticeDay: values['k100_last_practice_day'] as String?,
    );
  }

  /// First-run defaults: English speaker learning Spanish, beginner track.
  /// Chosen because Spanish has the best on-device STT/TTS coverage, so a brand
  /// new user hears a working tutor within a minute of finishing onboarding.
  static LearnerProfile defaults() => LearnerProfile(
        nativeLanguage: Languages.english,
        targetLanguage: Languages.spanish,
        proficiency: ProficiencyLevel.beginner,
        selectedModelId: '',
      );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is LearnerProfile &&
        other.nativeLanguage == nativeLanguage &&
        other.targetLanguage == targetLanguage &&
        other.proficiency == proficiency &&
        other.onboarded == onboarded &&
        other.autoListen == autoListen &&
        other.showTranslations == showTranslations &&
        other.haptics == haptics &&
        other.soundEffects == soundEffects &&
        other.ttsRateOverride == ttsRateOverride &&
        other.ttsVoiceName == ttsVoiceName &&
        other.dailyGoalMinutes == dailyGoalMinutes &&
        other.selectedModelId == selectedModelId &&
        other.customModelUrl == customModelUrl &&
        other.customModelName == customModelName &&
        other.sttOnDeviceOnly == sttOnDeviceOnly &&
        other.streakCount == streakCount &&
        other.lastPracticeDay == lastPracticeDay;
  }

  @override
  int get hashCode => Object.hashAll(<Object?>[
        nativeLanguage,
        targetLanguage,
        proficiency,
        onboarded,
        autoListen,
        showTranslations,
        haptics,
        soundEffects,
        ttsRateOverride,
        ttsVoiceName,
        dailyGoalMinutes,
        selectedModelId,
        customModelUrl,
        customModelName,
        sttOnDeviceOnly,
        streakCount,
        lastPracticeDay,
      ]);
}
