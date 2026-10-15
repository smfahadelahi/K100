import 'dart:io';

import 'package:flutter/foundation.dart';

/// Every tunable constant in one auditable place.
///
/// Two groups matter most:
///
///  * **The anti-loop timing block** — how the microphone is locked while the
///    tutor speaks and how the engine watchdog behaves. These values implement
///    the half-duplex contract (`idle → userListening → aiThinking → aiSpeaking
///    → idle`) and must not be loosened without re-reading `voice_pipeline_controller.dart`.
///  * **The inference block** — llama.cpp sampling parameters that keep a 1.5B
///    model fast (~5-15 tok/s on a mid-range phone) and *deterministic enough*
///    to emit parseable JSON on the first attempt.
class AppConfig {
  AppConfig._();

  // ─── Identity ─────────────────────────────────────────────────────────────
  static const String appName = 'K100';
  static const String tagline = 'Offline AI Speaking Tutor';
  static const String version = '1.0.0';
  static const String packageName = 'dev.k100.tutor';

  // ══════════════════════════════════════════════════════════════════════════
  //  ANTI-LOOP / AUDIO PIPELINE TIMING
  // ══════════════════════════════════════════════════════════════════════════

  /// Grace period between "TTS reported completion" and "microphone re-armed".
  ///
  /// Android's audio path keeps the last ~200 ms of audio in the speakers and
  /// the recogniser needs a beat to reset. 300 ms is the smallest value that
  /// survives real devices — never lower this to make turns feel snappier.
  static const Duration postTtsMicUnlockDelay = Duration(milliseconds: 300);

  /// Hard cap on a single listening turn, so a stuck recogniser cannot hold the
  /// session hostage.
  static const Duration maxListenWindow = Duration(seconds: 30);

  /// Silence that ends a turn automatically (`pauseFor` on the recogniser).
  static const Duration silenceTimeout = Duration(seconds: 2);

  /// Never auto-send a turn shorter than this — it is almost always a cough, a
  /// door slam, or the recogniser's own tail audio.
  static const Duration minUtteranceDuration = Duration(milliseconds: 900);

  /// Watchdog on `flutter_tts`. Some Android TTS engines never fire the
  /// completion handler (especially when the utterance is killed by audio focus
  /// loss). If it does not arrive, we unlock anyway — a locked mic is worse than
  /// a truncated sentence.
  static const Duration ttsWatchdogPerChar = Duration(milliseconds: 85);
  static const Duration ttsWatchdogMin = Duration(seconds: 4);
  static const Duration ttsWatchdogMax = Duration(seconds: 60);

  /// Delay before re-arming the microphone in hands-free (auto-listen) mode.
  static const Duration autoListenGracePeriod = Duration(milliseconds: 700);

  // ══════════════════════════════════════════════════════════════════════════
  //  INFERENCE (llama.cpp)
  // ══════════════════════════════════════════════════════════════════════════

  /// Context window in tokens. 2048 is the sweet spot: the system prompt,
  /// scenario injector, 6 turns of history and a 320-token reply all fit, and
  /// KV-cache memory stays around 150 MB for a 1.5B model.
  static const int contextSize = 2048;

  /// Prompt batch size. 256 keeps prefill snappy without spiking memory.
  static const int promptBatch = 256;

  /// Thread count floor/ceiling for on-device decode. `cores - 2` clamped into
  /// this range keeps the UI thread and the audio thread enough headroom.
  static const int minThreads = 2;
  static const int maxThreads = 6;

  /// Sampled reply budget. The JSON contract needs ~120-180 tokens for a rich
  /// answer; 320 is a hard ceiling that still finishes in ~20-30 s worst case.
  static const int maxTokensPerTurn = 320;
  static const int minTokensPerTurn = 160;

  /// Main sampling profile — creative enough for natural conversation.
  static const double temperature = 0.65;
  static const double topP = 0.92;
  static const int topK = 40;
  static const double minP = 0.05;
  static const double repeatPenalty = 1.12;
  static const int repeatLastN = 128;

  /// Repair profile: used for the single re-ask after a malformed reply. Lower
  /// temperature makes a 1.5B model measurably more likely to obey a JSON schema.
  static const double repairTemperature = 0.15;
  static const double repairTopP = 0.80;

  /// A reply shorter than this (after JSON parsing) is treated as a failure.
  static const int minReplyChars = 2;

  // ══════════════════════════════════════════════════════════════════════════
  //  PROMPT BUDGET
  // ══════════════════════════════════════════════════════════════════════════

  /// Turns of conversation kept in the prompt (user+assistant pairs count as 2).
  static const int historyTurns = 6;

  /// Above this length the oldest turns are dropped until the prompt fits.
  static const int maxPromptChars = 7000;

  /// Rough characters-per-token for mixed Latin/CJK text. Only used for the
  /// pre-flight budget check — the model tokenises exactly.
  static const double charsPerToken = 3.2;

  // ══════════════════════════════════════════════════════════════════════════
  //  MODEL DOWNLOAD (Hugging Face)
  // ══════════════════════════════════════════════════════════════════════════

  static const String hfBase = 'https://huggingface.co';
  static const String hfApiBase = 'https://huggingface.co/api/models';

  /// Public, unauthenticated direct download URL for a file in a public repo.
  static String resolveUrl(String repoId, String fileName) =>
      '$hfBase/$repoId/resolve/main/$fileName?download=true';

  /// Model metadata (file list, sizes, LFS sha256) for a public repo.
  static String repoApiUrl(String repoId) => '$hfApiBase/$repoId?blobs=true';

  /// Folder under `getApplicationDocumentsDirectory()` that holds the weights.
  static const String modelDirectoryName = 'models';

  /// File name inside that folder. One active model at a time keeps storage and
  /// the "which file do I load?" question trivial; the `.part` sibling holds a
  /// partial download and is resumed with an HTTP Range request.
  static const String modelFileName = 'k100_tutor_model.gguf';

  /// GGUF magic bytes ("GGUF", little-endian) — first four bytes of every valid
  /// file. Cheap sanity check before the expensive full SHA-256 pass.
  static const List<int> ggufMagic = <int>[0x47, 0x47, 0x55, 0x46];

  /// The four bits of the GGUF header we surface in the UI ("GGUF v3").
  static const int ggufHeaderBytes = 4;

  /// Download tuning: 8 MB chunks, 3 retries with exponential backoff, and a
  /// progress emission at most every 250 ms (progress bars do not need 60 fps).
  static const int downloadChunkBytes = 8 * 1024 * 1024;
  static const int downloadMaxRetries = 3;
  static const Duration downloadRetryBackoff = Duration(seconds: 2);
  static const Duration progressEmitInterval = Duration(milliseconds: 250);
  static const Duration connectTimeout = Duration(seconds: 30);
  static const Duration receiveTimeout = Duration(minutes: 15);

  /// Free-space guard: the APK needs the full file size plus this headroom.
  static const int downloadFreeSpaceHeadroomBytes = 200 * 1024 * 1024;

  // ══════════════════════════════════════════════════════════════════════════
  //  STORAGE
  // ══════════════════════════════════════════════════════════════════════════

  static const String databaseName = 'k100_tutor.db';
  static const int databaseVersion = 1;

  /// Sessions older than this are pruned on app start (keeps SQLite small).
  static const Duration historyRetention = Duration(days: 365);
  static const int maxStoredSessions = 500;

  // ══════════════════════════════════════════════════════════════════════════
  //  ENVIRONMENT
  // ══════════════════════════════════════════════════════════════════════════

  /// True on the only platform this app ships to. Kept as a getter so the
  /// desktop/web builds of the same sources degrade with a clear message.
  static bool get isSupportedPlatform => !kIsWeb && Platform.isAndroid;

  static String get unsupportedPlatformMessage =>
      '$appName runs on Android 8.0 (API 26) or newer. '
      'Speech recognition, text-to-speech and llama.cpp are all backed by '
      'platform channels that have no implementation on this platform.';
}

/// Keys for `shared_preferences`. Namespaced with `k100_` so a debug build can
/// never collide with another app's prefs during development.
class PrefKeys {
  PrefKeys._();

  static const String onboarded = 'k100_onboarded';
  static const String nativeLanguage = 'k100_native_language';
  static const String targetLanguage = 'k100_target_language';
  static const String proficiency = 'k100_proficiency';
  static const String autoListen = 'k100_auto_listen';
  static const String showTranslations = 'k100_show_translations';
  static const String haptics = 'k100_haptics';
  static const String ttsRate = 'k100_tts_rate';
  static const String ttsVoiceName = 'k100_tts_voice';
  static const String dailyGoalMinutes = 'k100_daily_goal';
  static const String selectedModelId = 'k100_selected_model';
  static const String customModelUrl = 'k100_custom_model_url';
  static const String customModelName = 'k100_custom_model_name';
  static const String ttsUnlockedWarningShown = 'k100_tts_warning_shown';
  static const String firstLaunchEpoch = 'k100_first_launch';

  /// Every key this app owns — used by "erase everything local".
  static const List<String> all = <String>[
    onboarded,
    nativeLanguage,
    targetLanguage,
    proficiency,
    autoListen,
    showTranslations,
    haptics,
    ttsRate,
    ttsVoiceName,
    dailyGoalMinutes,
    selectedModelId,
    customModelUrl,
    customModelName,
    ttsUnlockedWarningShown,
    firstLaunchEpoch,
  ];
}

/// SQLite identifiers, so a typo can never silently create a second table.
class DbTables {
  DbTables._();

  static const String sessions = 'sessions';
  static const String messages = 'messages';
  static const String vocabulary = 'vocabulary';
  static const String dailyStats = 'daily_stats';
}
