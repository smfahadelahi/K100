import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/language.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/models/model_catalog.dart';
import 'package:k100/models/tutor_state.dart';
import 'package:k100/services/database_service.dart';
import 'package:k100/services/llm_service.dart';
import 'package:k100/services/profile_repository.dart';
import 'package:k100/services/stt_service.dart';
import 'package:k100/services/tts_service.dart';
import 'package:k100/services/voice_pipeline_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ══════════════════════════════════════════════════════════════════════════════
//  PLATFORM
// ══════════════════════════════════════════════════════════════════════════════

/// Injected in `main()` after `SharedPreferences.getInstance()` resolves.
///
/// Everything that needs a stored setting depends on this provider, which is why
/// the app can read the learner profile **synchronously** on the very first
/// frame instead of flashing a loading spinner.
final Provider<SharedPreferences> sharedPreferencesProvider =
    Provider<SharedPreferences>(
  (Ref ref) => throw StateError(
    'sharedPreferencesProvider must be overridden in ProviderScope. '
    'See main.dart — SharedPreferences is loaded before runApp().',
  ),
);

// ══════════════════════════════════════════════════════════════════════════════
//  SERVICES
// ══════════════════════════════════════════════════════════════════════════════

/// Reads and writes the learner profile.
final Provider<ProfileRepository> profileRepositoryProvider =
    Provider<ProfileRepository>(
  (Ref ref) => ProfileRepository(ref.watch(sharedPreferencesProvider)),
);

/// SQLite: sessions, messages, vocabulary, stats.
final Provider<DatabaseService> databaseServiceProvider =
    Provider<DatabaseService>((Ref ref) {
  final DatabaseService service = DatabaseService();
  ref.onDispose(service.close);
  return service;
});

/// llama.cpp engine + model downloader.
final Provider<LlmService> llmServiceProvider = Provider<LlmService>((Ref ref) {
  final LlmService service = LlmService();
  ref.onDispose(service.dispose);
  return service;
});

/// Speech recognition.
final Provider<SttService> sttServiceProvider = Provider<SttService>((Ref ref) {
  final SttService service = SttService();
  ref.onDispose(service.dispose);
  return service;
});

/// Text-to-speech.
final Provider<TtsService> ttsServiceProvider = Provider<TtsService>((Ref ref) {
  final TtsService service = TtsService();
  ref.onDispose(service.dispose);
  return service;
});

/// Hugging Face metadata lookups (file size + LFS sha256).
final Provider<ModelCatalogService> modelCatalogServiceProvider =
    Provider<ModelCatalogService>((Ref ref) => ModelCatalogService());

/// The single live download progress stream.
///
/// Consumers (`ModelCard`, the setup screen) watch this and filter by model id,
/// so there is exactly one source of truth about what is downloading.
final StreamProvider<DownloadProgress> downloadProgressProvider =
    StreamProvider<DownloadProgress>(
  (Ref ref) => ref.watch(llmServiceProvider).downloader.progressStream,
);

/// Model ids whose weights are present on disk, complete and verified.
final FutureProvider<Set<String>> installedModelsProvider =
    FutureProvider<Set<String>>(
  (Ref ref) => ref.watch(llmServiceProvider).downloader.installedModelIds(),
);

/// Total bytes taken by model files, for the storage line in Settings.
final FutureProvider<int> modelStorageProvider = FutureProvider<int>(
  (Ref ref) => ref.watch(llmServiceProvider).downloader.storageUsed(),
);

/// Installed TTS voices (the picker in Settings filters by language).
final FutureProvider<List<TtsVoice>> ttsVoicesProvider =
    FutureProvider<List<TtsVoice>>(
  (Ref ref) => ref.watch(ttsServiceProvider).voices(),
);

// ══════════════════════════════════════════════════════════════════════════════
//  PROFILE
// ══════════════════════════════════════════════════════════════════════════════

/// The learner's configuration. Every mutation is persisted immediately — there
/// is no "save" button anywhere in this app.
class ProfileNotifier extends Notifier<LearnerProfile> {
  @override
  LearnerProfile build() {
    final ProfileRepository repository = ref.watch(profileRepositoryProvider);
    return repository.load();
  }

  ProfileRepository get _repository => ref.read(profileRepositoryProvider);

  Future<void> _apply(LearnerProfile next) async {
    state = next;
    await _repository.save(next);
  }

  /// Onboarding step 1.
  Future<void> setLanguages({
    required AppLanguage native,
    required AppLanguage target,
  }) =>
      _apply(state.copyWith(nativeLanguage: native, targetLanguage: target));

  /// Onboarding step 2.
  Future<void> setLevel(ProficiencyLevel level) =>
      _apply(state.copyWith(proficiency: level));

  /// Onboarding step 3 / Settings: choose a catalogue entry.
  Future<void> setModelId(String modelId) => _apply(
        state.copyWith(
          selectedModelId: modelId,
          customModelUrl: modelId == 'custom' ? state.customModelUrl : null,
          customModelName: modelId == 'custom' ? state.customModelName : null,
        ),
      );

  /// Registers a custom GGUF URL as the active model.
  Future<void> setCustomModel({
    required String url,
    required String name,
  }) =>
      _apply(
        state.copyWith(
          selectedModelId: 'custom',
          customModelUrl: url,
          customModelName: name,
        ),
      );

  Future<void> markOnboarded() => _apply(state.copyWith(onboarded: true));

  Future<void> setAutoListen(bool value) => _apply(state.copyWith(autoListen: value));

  Future<void> setShowTranslations(bool value) =>
      _apply(state.copyWith(showTranslations: value));

  Future<void> setHaptics(bool value) => _apply(state.copyWith(haptics: value));

  Future<void> setSoundEffects(bool value) =>
      _apply(state.copyWith(soundEffects: value));

  Future<void> setSttOnDeviceOnly(bool value) =>
      _apply(state.copyWith(sttOnDeviceOnly: value));

  Future<void> setDailyGoal(int minutes) =>
      _apply(state.copyWith(dailyGoalMinutes: minutes.clamp(5, 60)));

  /// Sets (or clears) the TTS rate override.
  Future<void> setTtsRate(double? rate) => _apply(
        rate == null
            ? state.copyWith(clearTtsRateOverride: true)
            : state.copyWith(ttsRateOverride: rate.clamp(0.2, 1.2)),
      );

  Future<void> setVoiceName(String? name) => _apply(
        name == null
            ? state.copyWith(clearTtsVoiceName: true)
            : state.copyWith(ttsVoiceName: name),
      );

  /// Called when a session starts: keeps the local streak in sync with the DB.
  Future<void> setStreak(int value) =>
      _apply(state.copyWith(streakCount: value < 0 ? 0 : value));

  Future<void> setLastPracticeDay(String day) =>
      _apply(state.copyWith(lastPracticeDay: day));
}

/// The learner profile.
final NotifierProvider<ProfileNotifier, LearnerProfile> profileProvider =
    NotifierProvider<ProfileNotifier, LearnerProfile>(ProfileNotifier.new);

// ══════════════════════════════════════════════════════════════════════════════
//  PIPELINE
// ══════════════════════════════════════════════════════════════════════════════

/// The STT → LLM → TTS state machine. See `voice_pipeline_controller.dart` for
/// the anti-loop contract.
final NotifierProvider<VoicePipelineController, TutorRuntimeState>
    tutorControllerProvider =
    NotifierProvider<VoicePipelineController, TutorRuntimeState>(
  VoicePipelineController.new,
);

// ══════════════════════════════════════════════════════════════════════════════
//  READ MODELS (SQLite)
// ══════════════════════════════════════════════════════════════════════════════

final FutureProvider<List<PracticeSession>> sessionsProvider =
    FutureProvider<List<PracticeSession>>((Ref ref) async {
  final DatabaseService db = ref.watch(databaseServiceProvider);
  return db.recentSessions();
});

/// Messages of one session, for the history detail view.
final sessionMessagesProvider =
    FutureProvider.family<List<ChatMessage>, int>((Ref ref, int sessionId) {
  final DatabaseService db = ref.watch(databaseServiceProvider);
  return db.messagesFor(sessionId);
});

/// Vocabulary bank for a target language.
final vocabularyProvider =
    FutureProvider.family<List<VocabularyItem>, String>((Ref ref, String languageCode) {
  final DatabaseService db = ref.watch(databaseServiceProvider);
  return db.vocabulary(targetLanguageCode: languageCode);
});

/// Items due for review right now.
final dueVocabularyProvider =
    FutureProvider.family<List<VocabularyItem>, String>((Ref ref, String languageCode) {
  final DatabaseService db = ref.watch(databaseServiceProvider);
  return db.dueVocabulary(targetLanguageCode: languageCode);
});

/// The last 7 days, including quiet days.
final FutureProvider<List<DailyProgress>> weeklyStatsProvider =
    FutureProvider<List<DailyProgress>>(
  (Ref ref) => ref.watch(databaseServiceProvider).recentStats(days: 7),
);

/// Consecutive practice days.
final FutureProvider<int> streakProvider = FutureProvider<int>(
  (Ref ref) => ref.watch(databaseServiceProvider).currentStreak(),
);

/// Mean fluency score over the last month.
final FutureProvider<double> averageScoreProvider = FutureProvider<double>(
  (Ref ref) => ref.watch(databaseServiceProvider).averageScore(days: 30),
);

/// Total minutes practised in the last month.
final FutureProvider<int> monthlyMinutesProvider = FutureProvider<int>(
  (Ref ref) => ref.watch(databaseServiceProvider).totalMinutes(days: 30),
);

/// Row counts for the "what is stored on this device" panel.
final FutureProvider<Map<String, int>> dataCountsProvider =
    FutureProvider<Map<String, int>>(
  (Ref ref) => ref.watch(databaseServiceProvider).counts(),
);

// ══════════════════════════════════════════════════════════════════════════════
//  DERIVED
// ══════════════════════════════════════════════════════════════════════════════

/// The catalogue entry behind the learner's current choice (`null` for a custom
/// URL — callers should then use [profileProvider].customModelName).
final Provider<ModelEntry?> selectedModelProvider = Provider<ModelEntry?>((Ref ref) {
  final LearnerProfile profile = ref.watch(profileProvider);
  return ModelCatalog.byId(profile.selectedModelId);
});

/// Whether a usable model file is on disk for the current selection.
final Provider<bool> hasUsableModelProvider = Provider<bool>((Ref ref) {
  final LearnerProfile profile = ref.watch(profileProvider);
  if (!profile.hasModel) return false;
  final AsyncValue<Set<String>> installed = ref.watch(installedModelsProvider);
  return installed.maybeWhen(
    data: (Set<String> ids) => ids.contains(profile.selectedModelId),
    orElse: () => false,
  );
});

/// Formats a score for the UI without leaking `null` handling everywhere.
String formatScore(int? score) => score == null ? '—' : '$score';

/// Refreshes everything that reads from SQLite. Called after a session ends,
/// after the learner erases their data, or after a download changes what is
/// installed.
///
/// Two extensions rather than one function: `WidgetRef` (inside widgets) and
/// `Ref` (inside notifiers) are unrelated types in Riverpod, so a single
/// function could not serve both call sites. `ref.invalidateHistoryProviders()`
/// reads the same in either place.
extension HistoryInvalidation on WidgetRef {
  void invalidateHistoryProviders() {
    invalidate(sessionsProvider);
    invalidate(weeklyStatsProvider);
    invalidate(streakProvider);
    invalidate(averageScoreProvider);
    invalidate(monthlyMinutesProvider);
    invalidate(dataCountsProvider);
  }
}

extension HistoryInvalidationFromRef on Ref {
  void invalidateHistoryProviders() {
    invalidate(sessionsProvider);
    invalidate(weeklyStatsProvider);
    invalidate(streakProvider);
    invalidate(averageScoreProvider);
    invalidate(monthlyMinutesProvider);
    invalidate(dataCountsProvider);
  }
}
