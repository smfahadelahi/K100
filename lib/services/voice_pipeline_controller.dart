import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:k100/models/ai_response.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/models/model_catalog.dart';
import 'package:k100/models/scenario.dart';
import 'package:k100/models/tutor_state.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/services/database_service.dart';
import 'package:k100/services/llm_service.dart';
import 'package:k100/services/prompt_builder.dart';
import 'package:k100/services/stt_service.dart';
import 'package:k100/services/tts_service.dart';

/// The STT → LLM → TTS state machine.
///
/// ## The one rule
///
/// **The microphone is never open while the tutor is speaking, and the tutor
/// never speaks while the microphone is open.** Everything else in this file is
/// bookkeeping in service of that sentence. A voice tutor that breaks this rule
/// hears its own TTS, treats it as learner speech, answers itself, and runs
/// forever — burning battery, producing nonsense, and looking broken. The three
/// mechanisms that make it impossible are:
///
/// 1. **[kAllowedTransitions]** — an auditable table. There is no
///    `userListening → aiSpeaking` edge, so text-to-speech can only begin from
///    `aiThinking`, which is only reachable after the recogniser has been
///    stopped. [TutorState.aiSpeaking] is only reachable from `aiThinking` (or
///    from `idle` for pure replay, which locks the mic first).
/// 2. **[TutorRuntimeState.micLocked]** — a single flag that the UI reads. It is
///    raised *before* inference starts (not merely before TTS) and lowered only
///    by [VoicePipelineController._unlockMicrophone], which waits
///    [AppConfig.postTtsMicUnlockDelay] (300 ms) after the TTS completion
///    callback fired. 300 ms covers the audio still sitting in Android's output
///    buffer plus the recogniser's own reset; lowering it re-introduces the loop.
/// 3. **[_turnToken]** — a monotonically increasing integer. Every asynchronous
///    continuation captures the token it started with and returns early if the
///    token has moved on. Interrupting a turn, leaving a screen, or a stale
///    recogniser callback cannot resurrect a dead turn.
///
/// ## Turn lifecycle
///
/// ```
/// idle
///   └─ startListening() ──► userListening ──(silence / orb tap)──►
///        aiThinking ──(JSON parsed)──► aiSpeaking ──(TTS completion + 300 ms)──► idle
/// ```
///
/// Interruption is available in every state: [interrupt] kills generation and
/// speech, returns to `idle`, and releases the microphone through the same
/// delayed path — a stuck microphone is the worst outcome this app can produce.
class VoicePipelineController extends Notifier<TutorRuntimeState> {
  // ── Dependencies (resolved per call — providers never change identity) ─────

  LlmService get _llm => ref.read(llmServiceProvider);
  SttService get _stt => ref.read(sttServiceProvider);
  TtsService get _tts => ref.read(ttsServiceProvider);
  DatabaseService get _db => ref.read(databaseServiceProvider);
  LearnerProfile get _profile => ref.read(profileProvider);

  // ── Turn bookkeeping ──────────────────────────────────────────────────────

  /// The mutex. Bumped whenever a turn starts or is aborted; every async
  /// continuation checks it before touching state.
  int _turnToken = 0;

  /// True while a turn is being finalised, so a recogniser callback arriving at
  /// the same moment cannot start a second turn from the same utterance.
  bool _closingTurn = false;

  /// The best transcript seen this turn (the recogniser reports cumulative text).
  String _transcript = '';

  /// When the recogniser was armed, for the "was that even speech?" check.
  DateTime? _listenStartedAt;

  /// When the session row was opened, for `recordPractice(seconds:)`.
  DateTime? _sessionStartedAt;

  /// Phrases mined into the vocabulary bank this session.
  int _minedThisSession = 0;

  /// Set by `ref.onDispose`; every timer and continuation checks it.
  bool _disposed = false;

  bool _bootstrapped = false;
  bool _bootstrapping = false;

  Timer? _micUnlockTimer;
  Timer? _autoListenTimer;

  // ══════════════════════════════════════════════════════════════════════════
  //  LIFECYCLE
  // ══════════════════════════════════════════════════════════════════════════

  @override
  TutorRuntimeState build() {
    _disposed = false;
    _turnToken = 0;
    _closingTurn = false;
    _transcript = '';
    _sessionStartedAt = null;
    _minedThisSession = 0;
    _bootstrapped = false;
    _bootstrapping = false;
    _micUnlockTimer?.cancel();
    _autoListenTimer?.cancel();

    // Detach callbacks but never dispose the services: they are owned by
    // app-scoped providers whose lifetime is longer than this notifier's.
    ref.onDispose(() {
      _disposed = true;
      _micUnlockTimer?.cancel();
      _autoListenTimer?.cancel();
      _stt.onUnexpectedStop = null;
      _tts.onStart = null;
      _tts.onComplete = null;
      Log.debug('VoicePipelineController disposed');
    });

    return const TutorRuntimeState();
  }

  /// Prepares everything a conversation needs: microphone permission, the
  /// recogniser locale, the TTS voice, and the model weights. Safe to call from
  /// every screen's `initState` — repeat calls are cheap no-ops.
  ///
  /// Nothing here is fatal: a missing model, a denied microphone or a missing
  /// voice all become a [TutorRuntimeState.statusMessage] or
  /// [TutorRuntimeState.errorMessage] that the UI can act on, because an app
  /// that refuses to open its main screen is worse than one that explains what
  /// is missing.
  Future<void> bootstrap() async {
    if (_bootstrapping) return;
    if (_bootstrapped && state.modelLoaded) return;
    _bootstrapping = true;

    try {
      final LearnerProfile profile = _profile;
      Log.info('Bootstrap · ${profile.nativeLanguage.code} → '
          '${profile.targetLanguage.code} · ${profile.proficiency.name} · '
          'model=${profile.selectedModelId.isEmpty ? 'none' : profile.selectedModelId}');

      if (!AppConfig.isSupportedPlatform) {
        state = state.copyWith(
          errorMessage: AppConfig.unsupportedPlatformMessage,
          statusMessage: '',
        );
        return;
      }

      state = state.copyWith(
        autoListenEnabled: profile.autoListen,
        engineLoading: false,
        engineLoadProgress: 0,
      );

      await _prepareSpeech(profile);
      await _loadSelectedModel(profile);
      _bootstrapped = true;
    } finally {
      _bootstrapping = false;
    }
  }

  /// Initialises the recogniser and the speech engine, and reports honestly when
  /// the target language has no recogniser installed on this device.
  Future<void> _prepareSpeech(LearnerProfile profile) async {
    // ── Recognition ────────────────────────────────────────────────────────
    final bool ready = await _stt.initialize(
      onError: (SttFailure failure) => _note(
        failure == SttFailure.permissionDenied
            ? 'Microphone permission denied. Allow it in Android settings → Apps → K100 → Permissions.'
            : 'Speech recognition problem: ${failure.message}',
      ),
    );

    _stt.onUnexpectedStop = () {
      // The recogniser stopped on its own (silence timeout, Android reclaiming
      // the mic, an incoming call). A silence timeout is *the* normal way a turn
      // ends, so treat it as "the learner finished talking".
      if (state.state == TutorState.userListening) {
        unawaited(_finishListening(_turnToken));
      }
    };

    final String? localeId = await _stt.resolveLocale(profile.targetLanguage.code);

    state = state.copyWith(
      micPermissionGranted: ready && localeId != null,
      sttLocaleAvailable: localeId != null,
      sttOnDevice: _stt.isOnDevice,
      statusMessage: localeId == null
          ? 'No ${profile.targetLanguage.englishName} recogniser on this device — '
              'install it in Android settings → System → Languages & input → '
              'Voice input, or switch the target language.'
          : state.statusMessage,
    );

    // ── Speech synthesis ───────────────────────────────────────────────────
    try {
      await _tts.initialize();
      await _tts.setLanguage(profile.targetLanguage.ttsLocale);
      await _tts.setRate(profile.effectiveTtsRate);
      await _applyStoredVoice(profile);
    } on TtsException catch (error) {
      Log.warn(error.message);
      _note('Text-to-speech is unavailable: ${error.message}');
    }
  }

  Future<void> _applyStoredVoice(LearnerProfile profile) async {
    final String? wanted = profile.ttsVoiceName;
    if (wanted == null || wanted.isEmpty) return;
    final List<TtsVoice> voices = await _tts.voices();
    for (final TtsVoice voice in voices) {
      if (voice.name == wanted) {
        await _tts.setVoice(voice);
        return;
      }
    }
    Log.warn('Stored voice "$wanted" is no longer installed — using the default.');
  }

  /// Resolves the learner's model choice into a catalogue entry. Custom URLs get
  /// a synthetic entry so the rest of the pipeline does not care where the file
  /// came from.
  ModelEntry? _resolveEntry([LearnerProfile? profile]) {
    final LearnerProfile p = profile ?? _profile;
    if (p.selectedModelId.isEmpty) return null;
    if (p.isCustomModel) {
      final String? url = p.customModelUrl;
      if (url == null || url.isEmpty) return null;
      return ModelCatalog.custom(url: url, name: p.customModelName);
    }
    return ModelCatalog.byId(p.selectedModelId);
  }

  /// Brings the weights into memory if the selected model is on disk. Loading a
  /// 1.5B model takes 3–12 s and ~1 GB, so this is the only place that does it.
  Future<void> _loadSelectedModel([LearnerProfile? profile, bool force = false]) async {
    final ModelEntry? entry = _resolveEntry(profile);
    if (entry == null) {
      state = state.copyWith(
        modelLoaded: false,
        modelDisplayName: '',
        statusMessage: 'Choose a model to start practising.',
      );
      return;
    }

    final ModelDownloader downloader = _llm.downloader;
    final String path = await downloader.targetPath(entry);

    if (!force && _llm.isLoaded && _llm.loadedPath == path) {
      state = state.copyWith(
        modelLoaded: true,
        modelDisplayName: _llm.modelDisplayName,
        engineLoading: false,
        engineLoadProgress: 1,
      );
      return;
    }

    if (!await downloader.isInstalled(entry)) {
      state = state.copyWith(
        modelLoaded: false,
        modelDisplayName: entry.displayName,
        engineLoading: false,
        statusMessage: '${entry.displayName} is not downloaded yet (${entry.sizeLabel}). '
            'Open Setup to get it — it is a one-off ${entry.sizeLabel} download.',
      );
      return;
    }

    state = state.copyWith(
      engineLoading: true,
      engineLoadProgress: 0,
      modelDisplayName: entry.displayName,
      errorMessage: null,
      statusMessage: 'Loading ${entry.displayName}…',
    );

    try {
      await _llm.loadModel(
        path,
        family: entry.family,
        displayName: entry.displayName,
        onProgress: (double progress) {
          if (_disposed) return;
          state = state.copyWith(
            engineLoadProgress: progress.clamp(0.0, 1.0),
            engineLoading: progress < 1,
          );
        },
      );
      state = state.copyWith(
        modelLoaded: true,
        engineLoading: false,
        engineLoadProgress: 1,
        modelDisplayName: _llm.modelDisplayName,
        statusMessage: '',
      );
      Log.info('Ready · ${_llm.modelDisplayName} · ${_llm.threads} threads');
    } on LlmException catch (error) {
      Log.error('Model load failed', error);
      state = state.copyWith(
        modelLoaded: false,
        engineLoading: false,
        engineLoadProgress: 0,
        errorMessage: error.message,
        statusMessage: '',
      );
    }
  }

  /// Called after a download finishes (or after the learner picks a different
  /// model). Reloads the weights without the app being restarted.
  Future<void> onModelInstalled() async {
    ref.invalidate(installedModelsProvider);
    ref.invalidate(modelStorageProvider);
    await _loadSelectedModel(_profile, true);
  }

  /// Frees ~1 GB. The pipeline is stopped first so nothing can be mid-inference.
  Future<void> unloadModel() async {
    await _abort(invalidateToken: true);
    await _llm.unload();
    state = state.copyWith(
      modelLoaded: false,
      modelDisplayName: '',
      engineLoading: false,
      engineLoadProgress: 0,
      statusMessage: 'Model unloaded.',
    );
  }

  /// Applies a settings change that the running pipeline has to know about
  /// (target language, romanisation, on-device recognition, speaking speed).
  Future<void> applyProfileChanges() async {
    final LearnerProfile profile = _profile;
    await _abort(invalidateToken: true);
    await _prepareSpeech(profile);
    final String? localeId = await _stt.resolveLocale(profile.targetLanguage.code);
    state = state.copyWith(
      autoListenEnabled: profile.autoListen,
      sttLocaleAvailable: localeId != null,
    );
  }

  Future<void> setAutoListen(bool enabled) async {
    state = state.copyWith(
      autoListenEnabled: enabled,
      statusMessage: enabled ? 'Hands-free mode on.' : 'Hands-free mode off.',
    );
    if (enabled && state.canStartListening) {
      _scheduleAutoListen(state.autoListenEnabled, _turnToken);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  SESSIONS
  // ══════════════════════════════════════════════════════════════════════════

  /// Starts (or restarts) the conversation for a scenario: a fresh transcript
  /// and a fresh SQLite session row.
  Future<void> beginScenario(LessonScenario scenario) async {
    if (state.sessionId != null && state.scenarioId == scenario.id) {
      // Same scenario, still live — nothing to do, do not wipe the transcript.
      state = state.copyWith(statusMessage: scenario.goal);
      return;
    }

    await _abort(invalidateToken: true);

    final LearnerProfile profile = _profile;
    final int? sessionId = await _db.startSession(
      scenarioId: scenario.id,
      scenarioTitle: scenario.title,
      profile: profile,
    );

    _sessionStartedAt = DateTime.now();
    _minedThisSession = 0;
    _transcript = '';

    state = state.copyWith(
      scenarioId: scenario.id,
      sessionId: sessionId,
      turns: const <ChatMessage>[],
      turnCount: 0,
      partialTranscript: '',
      streamingReply: '',
      thinkingText: '',
      wordsMinedToday: 0,
      soundLevel: 0,
      errorMessage: null,
      clearError: true,
      clearLatestResponse: true,
      clearLastFeedback: true,
      statusMessage: scenario.goal,
    );

    Log.info('Scenario "${scenario.title}" (${scenario.id}) · session $sessionId');
  }

  /// Ends the conversation: closes the session row, records the practice minutes
  /// and refreshes the statistics the home screen shows.
  Future<void> endSession() async {
    final int? sessionId = state.sessionId;
    final int turns = state.turnCount;
    final double? average = state.sessionAverageScore;
    final DateTime? startedAt = _sessionStartedAt;

    await _abort(invalidateToken: true);

    if (sessionId != null) {
      await _db.endSession(sessionId);
      if (startedAt != null && turns > 0) {
        final int seconds = DateTime.now().difference(startedAt).inSeconds;
        await _db.recordPractice(
          seconds: seconds < 5 ? 5 : seconds,
          messages: turns,
          newWords: _minedThisSession,
          score: average,
        );
        final int streak = await _db.currentStreak();
        await ref.read(profileProvider.notifier).setStreak(streak);
        await ref.read(profileProvider.notifier)
            .setLastPracticeDay(DatabaseService.dayKey());
      }
      ref.invalidateHistoryProviders();
      Log.info('Session $sessionId closed · $turns turns · ${average?.round() ?? '—'} avg');
    }

    state = state.copyWith(
      sessionId: null,
      turns: const <ChatMessage>[],
      turnCount: 0,
      partialTranscript: '',
      streamingReply: '',
      thinkingText: '',
      soundLevel: 0,
      statusMessage: 'Session saved on this device.',
      clearError: true,
      clearLatestResponse: true,
      clearLastFeedback: true,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TURN: LISTENING
  // ══════════════════════════════════════════════════════════════════════════

  /// Opens the microphone. The only legal entry into [TutorState.userListening].
  Future<void> startListening() async {
    if (!state.canStartListening) {
      // Say why instead of silently doing nothing — every one of these has a
      // real cause the learner can fix.
      if (!state.modelLoaded) {
        _note('No model loaded yet.');
      } else if (state.micLocked) {
        _note('One moment — the microphone is still closing from the last reply.');
      } else if (state.state != TutorState.idle) {
        _note('Finish the current turn first.');
      }
      return;
    }

    final LearnerProfile profile = _profile;
    final String? localeId = await _stt.resolveLocale(profile.targetLanguage.code);
    if (localeId == null) {
      _note('No ${profile.targetLanguage.englishName} recogniser is installed on '
          'this device.');
      return;
    }

    final bool ready = await _stt.initialize();
    if (!ready) {
      state = state.copyWith(
        micPermissionGranted: false,
        errorMessage: 'The microphone is not available. Check the RECORD_AUDIO '
            'permission for K100 in Android settings.',
      );
      return;
    }

    final int token = ++_turnToken;
    _closingTurn = false;
    _transcript = '';
    _listenStartedAt = DateTime.now();

    _transition(TutorState.userListening, reason: 'learner tapped the orb');
    state = state.copyWith(
      partialTranscript: '',
      streamingReply: '',
      thinkingText: '',
      errorMessage: null,
      clearError: true,
      statusMessage: '',
      micPermissionGranted: true,
    );

    try {
      await _stt.start(
        localeId: localeId,
        preferOnDevice: profile.sttOnDeviceOnly,
        onResult: (SttResult result) {
          if (token != _turnToken) return;
          if (state.state != TutorState.userListening) return;
          _transcript = result.text;
          state = state.copyWith(partialTranscript: result.text);
          if (result.isFinal) {
            unawaited(_finishListening(token));
          }
        },
        onSoundLevel: (double level) {
          if (token != _turnToken) return;
          if (state.state != TutorState.userListening) return;
          state = state.copyWith(soundLevel: level.clamp(0.0, 1.0));
        },
        onSessionEnd: () {
          if (token != _turnToken) return;
          unawaited(_finishListening(token));
        },
      );
      state = state.copyWith(sttOnDevice: _stt.isOnDevice);
    } on SttException catch (error) {
      Log.warn('Could not start listening: ${error.message}');
      _transition(TutorState.idle, reason: 'recogniser refused to start');
      state = state.copyWith(
        soundLevel: 0,
        errorMessage: error.message,
        micPermissionGranted: error.failure != SttFailure.permissionDenied,
        statusMessage: '',
      );
      _unlockMicrophone(token: token);
    }
  }

  /// "I am done talking." The learner taps the orb (or the keyboard button) while
  /// the recogniser is open.
  Future<void> finishSpeakingNow() async {
    if (state.state != TutorState.userListening) return;
    await _finishListening(_turnToken);
  }

  /// Closes the listening half of the turn and hands the transcript to the model.
  ///
  /// Guarded three ways: the token must still be current, a finalisation must not
  /// already be running ([_closingTurn]) and the state must still be
  /// `userListening`. A recogniser that fires `onResult` twice, or a silence
  /// timeout racing the learner's tap, therefore cannot start two inferences.
  Future<void> _finishListening(int token) async {
    if (token != _turnToken) return;
    if (_closingTurn) return;
    if (state.state != TutorState.userListening) return;
    _closingTurn = true;

    try {
      await _stt.stop();

      final String text = _transcript.trim();
      final Duration spoke = _listenStartedAt == null
          ? Duration.zero
          : DateTime.now().difference(_listenStartedAt!);

      if (text.isEmpty) {
        Log.debug('Turn ended with an empty transcript after ${spoke.inMilliseconds} ms');
        _transition(TutorState.idle, reason: 'nothing was said');
        state = state.copyWith(
          partialTranscript: '',
          soundLevel: 0,
          statusMessage: 'I did not catch that — tap the orb and speak again.',
        );
        _unlockMicrophone(token: token);
        return;
      }

      if (spoke < AppConfig.minUtteranceDuration && text.runes.length <= 2) {
        // A cough, a door slam, or the recogniser's own tail audio.
        Log.debug('Ignoring a ${spoke.inMilliseconds} ms / '
            '${text.runes.length}-character blip');
        _transition(TutorState.idle, reason: 'too short to be speech');
        state = state.copyWith(
          partialTranscript: '',
          soundLevel: 0,
          statusMessage: 'Too short — hold the turn a moment longer.',
        );
        _unlockMicrophone(token: token);
        return;
      }

      state = state.copyWith(partialTranscript: text, soundLevel: 0);
      await _runTurn(userText: text, token: token, spoke: spoke);
    } finally {
      _closingTurn = false;
    }
  }

  /// Cancels the listening half without producing a reply (the learner tapped the
  /// X). Nothing is sent to the model.
  Future<void> cancelListening() async {
    if (state.state != TutorState.userListening) return;
    final int token = ++_turnToken;
    await _stt.cancel();
    _transcript = '';
    _transition(TutorState.idle, reason: 'turn cancelled by the learner');
    state = state.copyWith(
      partialTranscript: '',
      soundLevel: 0,
      statusMessage: 'Turn cancelled.',
    );
    _unlockMicrophone(token: token);
  }

  /// Typed input: identical to a spoken turn after the transcript exists, so the
  /// same lock, the same JSON contract and the same feedback card apply.
  Future<void> submitText(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!state.canSubmitText) {
      _note(!state.modelLoaded
          ? 'No model loaded yet.'
          : 'The tutor is still working on the previous turn.');
      return;
    }
    final int token = ++_turnToken;
    await _runTurn(userText: trimmed, token: token, spoke: Duration.zero);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  TURN: INFERENCE + SPEECH
  // ══════════════════════════════════════════════════════════════════════════

  /// The whole second half of a turn: prompt → one inference → parse → speak.
  ///
  /// The microphone is locked here, **before** the model is asked anything. That
  /// is stricter than "lock before TTS" on purpose: a burst of noise arriving
  /// during generation would otherwise be captured and turned into a second turn
  /// after the first one finishes.
  Future<void> _runTurn({
    required String userText,
    required int token,
    required Duration spoke,
  }) async {
    _transition(TutorState.aiThinking, reason: 'learner said "$userText"');
    await _lockMicrophone('generating a reply');

    final DateTime turnStarted = DateTime.now();
    final ChatMessage userMessage = ChatMessage(
      sessionId: state.sessionId,
      role: MessageRole.user,
      text: userText,
      createdAt: DateTime.now(),
    );

    state = state.copyWith(
      turns: <ChatMessage>[...state.turns, userMessage],
      partialTranscript: '',
      thinkingText: 'Thinking…',
      streamingReply: '',
      turnCount: state.turnCount + 1,
      errorMessage: null,
      clearError: true,
    );

    final int? storedId = await _db.insertMessage(userMessage);
    if (storedId != null) {
      final List<ChatMessage> turns = List<ChatMessage>.from(state.turns);
      turns[turns.length - 1] = turns.last.copyWith(id: storedId);
      state = state.copyWith(turns: turns);
    }

    AiResponse response;
    LlmGenerationResult? generation;
    try {
      generation = await _generate(userText: userText, token: token);
      if (token != _turnToken) return;

      response = AiResponse.parse(
        generation.text,
        latency: generation.duration,
        tokensPredicted: generation.tokensPredicted,
        learnerText: userText,
      );

      // One stricter re-ask. A 1.5B model usually obeys the schema after seeing
      // the reminder plus the pre-filled object, and one extra inference is far
      // cheaper than a broken feedback card.
      if (!response.isUsable) {
        Log.warn('Reply did not parse (${response.mode.label}) — re-asking strictly');
        final LlmGenerationResult repair =
            await _generate(userText: userText, token: token, strictRepair: true);
        if (token != _turnToken) return;

        final AiResponse retry = AiResponse.parse(
          repair.text,
          latency: turnStarted.elapsed(),
          tokensPredicted: repair.tokensPredicted,
          learnerText: userText,
        );
        if (retry.isUsable) {
          response = retry;
          generation = repair;
        }
      }
    } on LlmException catch (error) {
      Log.error('Inference failed', error);
      if (token != _turnToken) return;
      _transition(TutorState.idle, reason: 'engine error');
      state = state.copyWith(
        thinkingText: '',
        streamingReply: '',
        errorMessage: error.message,
        statusMessage: '',
      );
      _unlockMicrophone(token: token);
      return;
    }

    if (token != _turnToken) return;

    response = response.cleanup(learnerText: userText);

    if (!response.isUsable) {
      // The model produced something unusable twice. Keep the turn in the
      // transcript (so the learner sees what happened) but do not speak it.
      Log.warn('Giving up on this turn after two attempts');
      _transition(TutorState.idle, reason: 'unparseable reply');
      final ChatMessage apology = ChatMessage(
        sessionId: state.sessionId,
        role: MessageRole.tutor,
        text: 'Sorry — my reply came out garbled. Say that again and I will '
            'answer properly.',
        parseMode: AiParseMode.rawText,
        recoveredFromMalformedJson: true,
        createdAt: DateTime.now(),
      );
      final int? id = await _db.insertMessage(apology);
      state = state.copyWith(
        turns: <ChatMessage>[
          ...state.turns,
          id == null ? apology : apology.copyWith(id: id),
        ],
        thinkingText: '',
        streamingReply: '',
        latestResponse: response,
        errorMessage: 'The model returned an unusable reply this turn.',
      );
      _unlockMicrophone(token: token);
      return;
    }

    await _deliver(
      response: response,
      userText: userText,
      userMessageId: state.turns.isEmpty ? null : state.turns.last.id,
      generation: generation,
      token: token,
    );
  }

  /// Runs one completion and streams the tokens into
  /// [TutorRuntimeState.streamingReply] so the learner sees the reply forming.
  Future<LlmGenerationResult> _generate({
    required String userText,
    required int token,
    bool strictRepair = false,
  }) async {
    final LearnerProfile profile = _profile;
    final LessonScenario scenario = Scenarios.byId(state.scenarioId);
    final ModelFamily family = _llm.isLoaded ? _llm.family : ModelFamily.qwen2;

    PromptBuilder builder = PromptBuilder(
      profile: profile,
      scenario: scenario,
      family: family,
    );

    List<PromptTurn> history = _promptHistory();
    String prompt = builder.render(
      history: history,
      userText: userText,
      strictRepair: strictRepair,
      prefill: strictRepair,
    );

    // Pre-flight budget check. The builder already trims, but a pathological
    // utterance (a pasted paragraph) can still overflow 2048 tokens, and an
    // overflowing prompt on a phone means a silent, expensive failure.
    if (builder.isPromptTooLong(prompt)) {
      Log.warn('Prompt is over budget — dropping to the last two turns');
      builder = PromptBuilder(
        profile: profile,
        scenario: scenario,
        family: family,
        historyTurns: 2,
      );
      history = _promptHistory(limit: 2);
      prompt = builder.render(
        history: history,
        userText: userText,
        strictRepair: strictRepair,
        prefill: strictRepair,
      );
    }

    state = state.copyWith(
      thinkingText: strictRepair ? 'Tightening the reply format…' : 'Thinking…',
      streamingReply: '',
    );

    final LlmGenerationResult result = await _llm.generate(
      prompt: prompt,
      stop: builder.stopSequences,
      maxTokens: strictRepair
          ? (AppConfig.maxTokensPerTurn ~/ 2)
          : AppConfig.maxTokensPerTurn,
      temperature: strictRepair ? AppConfig.repairTemperature : AppConfig.temperature,
      topP: strictRepair ? AppConfig.repairTopP : AppConfig.topP,
      topK: AppConfig.topK,
      minP: AppConfig.minP,
      repeatPenalty: AppConfig.repeatPenalty,
      onToken: (String delta) {
        if (token != _turnToken) return;
        if (_disposed) return;
        state = state.copyWith(streamingReply: state.streamingReply + delta);
      },
    );

    Log.info('Generated ${result.tokensPredicted} tokens in '
        '${result.duration.inMilliseconds} ms '
        '(${result.tokensPerSecond.toStringAsFixed(1)} tok/s, '
        '${result.stoppedEos ? 'EOS' : 'stop/limit'})');

    // A pre-filled generation is missing the object header that the model was
    // told to continue from, so put it back before parsing.
    if (strictRepair) {
      return LlmGenerationResult(
        text: '${PromptBuilder.repairPrefill}${result.text}',
        tokensPredicted: result.tokensPredicted,
        tokensEvaluated: result.tokensEvaluated,
        duration: result.duration,
        stoppedEos: result.stoppedEos,
        truncated: result.truncated,
        stoppedWord: result.stoppedWord,
        peakTokensPerSecond: result.peakTokensPerSecond,
      );
    }
    return result;
  }

  /// Turns the transcript into prompt turns. Assistant turns are re-encoded as
  /// the JSON contract the model was asked for — replaying the *object* rather
  /// than prose is what keeps a small model on-schema across a long session.
  List<PromptTurn> _promptHistory({int? limit}) {
    final List<ChatMessage> turns = state.turns;
    final int take = limit == null || limit >= turns.length ? turns.length : limit;
    final List<PromptTurn> out = <PromptTurn>[];

    for (final ChatMessage message in turns.skip(turns.length - take)) {
      if (message.isUser) {
        out.add(PromptTurn(role: 'user', content: message.text));
        continue;
      }
      if (!message.isTutor) continue;
      out.add(PromptTurn(role: 'assistant', content: _asContractJson(message)));
    }
    return out;
  }

  /// Rebuilds the model's own JSON shape from a stored tutor message, so the few
  /// shot context in the prompt looks exactly like the requested output.
  String _asContractJson(ChatMessage message) {
    final Map<String, Object?> payload = <String, Object?>{
      'reply_target_language': message.text,
      'reply_translation': message.translation ?? '',
      if ((message.romanization ?? '').isNotEmpty)
        'reply_romanization': message.romanization,
      'grammar_correction': message.correction,
      'explanation': message.explanation,
      'fluency_score': message.score ?? 70,
      if ((message.keyPhrase ?? '').isNotEmpty) 'key_phrase': message.keyPhrase,
      if ((message.keyPhraseTranslation ?? '').isNotEmpty)
        'key_phrase_translation': message.keyPhraseTranslation,
    };
    try {
      return jsonEncode(payload);
    } catch (_) {
      return message.text;
    }
  }

  /// Attaches the feedback, persists everything, and speaks **only** the target
  /// language field.
  Future<void> _deliver({
    required AiResponse response,
    required String userText,
    required int? userMessageId,
    required LlmGenerationResult? generation,
    required int token,
  }) async {
    final DateTime now = DateTime.now();

    // 1. The user's bubble gains its correction card.
    final List<ChatMessage> turns = List<ChatMessage>.from(state.turns);
    for (int i = turns.length - 1; i >= 0; i--) {
      if (turns[i].isUser) {
        turns[i] = turns[i].withFeedback(response);
        break;
      }
    }

    // 2. The tutor's bubble.
    final ChatMessage tutorMessage = ChatMessage(
      sessionId: state.sessionId,
      role: MessageRole.tutor,
      text: response.replyTargetLanguage,
      translation: response.hasTranslation ? response.replyTranslation : null,
      romanization: response.replyRomanization,
      keyPhrase: response.keyPhrase,
      keyPhraseTranslation: response.keyPhraseTranslation,
      parseMode: response.mode,
      latencyMs: generation?.duration.inMilliseconds,
      tokensPredicted: generation?.tokensPredicted,
      recoveredFromMalformedJson: response.isDegraded,
      createdAt: now,
    );
    turns.add(tutorMessage);

    state = state.copyWith(
      turns: turns,
      latestResponse: response,
      lastFeedback: response,
      lastScore: response.fluencyScore,
      lastLatency: generation?.duration,
      thinkingText: '',
      streamingReply: '',
    );

    // 3. Persist: the correction fields go onto the user's row, the reply gets
    //    its own row.
    if (userMessageId != null) {
      await _db.updateMessageFeedback(
        userMessageId,
        correction: response.grammarCorrection,
        explanation: response.explanation,
        score: response.fluencyScore,
        parseMode: response.mode.name,
      );
    }
    final int? tutorId = await _db.insertMessage(tutorMessage);
    if (tutorId != null && state.turns.isNotEmpty) {
      final List<ChatMessage> updated = List<ChatMessage>.from(state.turns);
      updated[updated.length - 1] = updated.last.copyWith(id: tutorId);
      state = state.copyWith(turns: updated);
    }

    await _mineVocabulary(response, userText);

    if (token != _turnToken) return;

    // 4. Speak. The microphone is already locked, and it stays locked for
    //    [AppConfig.postTtsMicUnlockDelay] after the engine reports completion.
    _transition(TutorState.aiSpeaking, reason: 'speaking the reply');

    TtsStopReason reason = TtsStopReason.skipped;
    try {
      reason = await _tts.speak(
        response.ttsText,
        rate: _profile.effectiveTtsRate,
        localeTag: _profile.targetLanguage.ttsLocale,
      );
    } on TtsException catch (error) {
      Log.warn('Speech failed: ${error.message}');
      reason = TtsStopReason.error;
    }

    if (token != _turnToken) return;
    await _afterSpeech(reason: reason, token: token);
  }

  /// The single exit from [TutorState.aiSpeaking].
  ///
  /// [TtsService.speak] completes inside `flutterTts.setCompletionHandler`, so
  /// reaching this method *is* "the completion callback fired". The microphone is
  /// released 300 ms later, then hands-free mode may re-arm it.
  Future<void> _afterSpeech({required TtsStopReason reason, required int token}) async {
    if (reason == TtsStopReason.error) {
      _note('The speech engine failed — showing the reply as text instead.');
    } else if (reason == TtsStopReason.watchdog) {
      _note('The speech engine stalled; the microphone was released anyway.');
    }

    _transition(TutorState.idle, reason: 'speech finished (${reason.name})');
    state = state.copyWith(soundLevel: 0, thinkingText: '');
    _unlockMicrophone(token: token);

    // Record the turn's practice time immediately: a learner who closes the app
    // mid-session still gets credit for what they practised.
    await _recordTurnProgress();
  }

  Future<void> _recordTurnProgress() async {
    final DateTime? started = _sessionStartedAt;
    if (started == null || state.turnCount == 0) return;
    // Cheap incremental write; `endSession` closes the aggregates.
    await _db.recordPractice(
      seconds: 20,
      messages: 1,
      newWords: 0,
      score: state.lastScore?.toDouble(),
    );
  }

  /// Stores the reply's key phrase in the vocabulary bank.
  Future<void> _mineVocabulary(AiResponse response, String learnerText) async {
    final String? phrase = response.keyPhrase;
    if (phrase == null || phrase.trim().length < 2) return;
    if (phrase.trim().toLowerCase() == learnerText.trim().toLowerCase()) return;

    final LearnerProfile profile = _profile;
    final int? id = await _db.upsertVocabulary(
      VocabularyItem(
        term: phrase.trim(),
        targetLanguageCode: profile.targetLanguage.code,
        translation: response.keyPhraseTranslation,
        example: response.replyTargetLanguage,
        sourceScenarioId: state.scenarioId,
        createdAt: DateTime.now(),
      ),
    );

    if (id != null) {
      _minedThisSession++;
      state = state.copyWith(wordsMinedToday: state.wordsMinedToday + 1);
      ref.invalidate(vocabularyProvider);
      ref.invalidate(dueVocabularyProvider);
      ref.invalidate(dataCountsProvider);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  INTERRUPTION
  // ══════════════════════════════════════════════════════════════════════════

  /// Replays a previous tutor line through the TTS engine.
  ///
  /// This is still *output*, so it obeys the same rules as a reply: the
  /// microphone is locked before the first syllable and released 300 ms after the
  /// engine reports completion. No inference is involved, which is why the
  /// pipeline goes `idle → aiSpeaking` directly (see [kAllowedTransitions]).
  Future<void> replayLine(String text) async {
    final String spoken = AiResponse.sanitizeForSpeech(text);
    if (spoken.isEmpty) return;
    if (state.state != TutorState.idle) {
      Log.warn('Replay ignored while the pipeline is ${state.state.name}');
      return;
    }

    final int token = ++_turnToken;
    _transition(TutorState.aiSpeaking, reason: 'replaying a line');
    await _lockMicrophone('replaying a line');

    final TtsStopReason reason = await _tts.speak(
      spoken,
      rate: _profile.effectiveTtsRate,
      localeTag: _profile.targetLanguage.ttsLocale,
    );
    if (token != _turnToken) return;

    Log.info('Replay finished: ${reason.name}');
    _transition(TutorState.idle, reason: 'replay finished');
    state = state.copyWith(soundLevel: 0);
    _unlockMicrophone(token: token);
  }

  /// The stop button. Kills generation *and* speech, then returns to `idle`.
  ///
  /// This is the escape hatch that makes the half-duplex design safe: whatever
  /// goes wrong with the engine, the recogniser or the audio focus, one tap puts
  /// the pipeline back in a known state with the microphone released.
  Future<void> interrupt() async {
    if (state.state == TutorState.idle && !state.micLocked) {
      state = state.copyWith(errorMessage: null, clearError: true, statusMessage: '');
      return;
    }
    Log.info('Interrupt requested from ${state.state.name}');
    final int token = ++_turnToken;
    _autoListenTimer?.cancel();

    if (_stt.isListening) await _stt.cancel();
    if (_llm.isBusy) await _llm.stopGeneration();
    if (_tts.isSpeaking) await _tts.stop();

    _closingTurn = false;
    _transition(TutorState.idle, reason: 'interrupted by the learner');
    state = state.copyWith(
      partialTranscript: '',
      streamingReply: '',
      thinkingText: '',
      soundLevel: 0,
      statusMessage: 'Stopped.',
    );
    _unlockMicrophone(token: token);
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  THE LOCK
  // ══════════════════════════════════════════════════════════════════════════

  /// Raises the microphone lock and makes sure no recogniser session survives it.
  Future<void> _lockMicrophone(String reason) async {
    _micUnlockTimer?.cancel();
    _micUnlockTimer = null;
    _autoListenTimer?.cancel();

    if (!state.micLocked) {
      state = state.copyWith(micLocked: true);
      Log.debug('Microphone LOCKED ($reason)');
    }

    // Belt and braces: the state machine should already have stopped the
    // recogniser, but an unexpected callback path must not leave it open while
    // text-to-speech is about to play.
    if (_stt.isListening) {
      Log.warn('A recogniser session was still open ($reason) — cancelling it');
      await _stt.cancel();
    }
  }

  /// Releases the microphone exactly [AppConfig.postTtsMicUnlockDelay] after the
  /// TTS completion callback — never sooner, and only for the current turn.
  ///
  /// The delay exists because Android keeps the tail of an utterance in the
  /// speaker path: re-arming the recogniser immediately picks up the tutor's own
  /// last syllable and starts the loop this whole file is built to prevent.
  void _unlockMicrophone({required int token}) {
    _micUnlockTimer?.cancel();
    _micUnlockTimer = Timer(AppConfig.postTtsMicUnlockDelay, () {
      if (_disposed) return;
      if (token != _turnToken) {
        Log.debug('Unlock skipped: the turn was superseded');
        return;
      }
      if (state.state.locksMicrophone) {
        // Should be unreachable — the state machine only unlocks from `idle`.
        Log.warn('Unlock deferred: state is ${state.state.name}');
        return;
      }
      state = state.copyWith(micLocked: false);
      Log.debug('Microphone OPEN (${AppConfig.postTtsMicUnlockDelay.inMilliseconds} ms '
          'after TTS completion)');
      if (state.autoListenEnabled) _scheduleAutoListen(state.autoListenEnabled, token);
    });
  }

  /// Hands-free mode: re-arm the microphone after the learner has had a moment to
  /// read the reply.
  void _scheduleAutoListen(bool enabled, int token) {
    if (!enabled) return;
    _autoListenTimer?.cancel();
    _autoListenTimer = Timer(AppConfig.autoListenGracePeriod, () {
      if (_disposed) return;
      if (token != _turnToken) return;
      if (!state.autoListenEnabled) return;
      if (!state.canStartListening) return;
      unawaited(startListening());
    });
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  PLUMBING
  // ══════════════════════════════════════════════════════════════════════════

  /// Moves the state machine, honouring (and policing) [kAllowedTransitions].
  ///
  /// In debug builds an illegal edge throws — that is the point of the table, and
  /// a test that exercises the pipeline will catch a regression immediately. In
  /// release builds it is logged and applied anyway: a stuck pipeline on a
  /// learner's phone is worse than a transition that should not have happened.
  void _transition(TutorState next, {required String reason}) {
    final TutorState current = state.state;
    if (current == next) return;

    if (!canTransition(current, next)) {
      final String message = 'Illegal pipeline transition $current → $next ($reason)';
      Log.error(message);
      assert(false, message);
    } else {
      Log.debug('$current → $next · $reason');
    }
    state = state.copyWith(state: next);
  }

  /// Stops everything in flight. Used by `beginScenario`, `endSession`,
  /// `unloadModel` and any settings change that invalidates the current turn.
  Future<void> _abort({required bool invalidateToken}) async {
    if (invalidateToken) _turnToken++;
    _micUnlockTimer?.cancel();
    _autoListenTimer?.cancel();
    _closingTurn = false;
    _transcript = '';

    if (_stt.isListening) await _stt.cancel();
    if (_tts.isSpeaking) await _tts.stop();
    if (_llm.isBusy) await _llm.stopGeneration();

    if (state.micLocked) state = state.copyWith(micLocked: false);
    if (state.state != TutorState.idle) {
      state = state.copyWith(state: TutorState.idle);
    }
  }

  /// Sets a transient informational line without disturbing anything else.
  void _note(String message) {
    Log.info(message);
    state = state.copyWith(statusMessage: message);
  }
}

/// `DateTime.elapsed()` reads better than a subtraction at every call site and
/// keeps the duration maths in one place.
extension on DateTime {
  Duration elapsed() => DateTime.now().difference(this);
}
