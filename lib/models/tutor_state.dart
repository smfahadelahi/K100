import 'package:flutter/material.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/ai_response.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/scenario.dart';

/// The half-duplex pipeline state.
///
/// There are exactly four states and **no** "speaking while listening" state —
/// that is the whole point. A voice tutor whose microphone stays open while its
/// own text-to-speech plays will hear itself, answer itself, and burn the
/// learner's battery in an infinite loop. The state machine plus
/// [kAllowedTransitions] plus the controller's mutex make that impossible.
enum TutorState {
  /// Nothing is happening. This is the only state from which the microphone may
  /// be armed, and the only state the pipeline may settle into at the end of a
  /// turn.
  idle('Ready', 'Tap the orb and start speaking', Icons.mic_none_outlined),

  /// The recogniser is running. Microphone open, speakers idle.
  userListening('Listening', 'Speak now — I am listening', Icons.mic),

  /// The recogniser has stopped, llama.cpp is generating. Microphone **locked**.
  aiThinking('Thinking', 'Working out a reply and checking your grammar',
      Icons.psychology_outlined),

  /// TTS is speaking. Microphone **locked** until 300 ms after completion.
  aiSpeaking('Speaking', 'Tap the red stop button to interrupt me',
      Icons.volume_up);

  const TutorState(this.label, this.hint, this.icon);

  /// Short human label ("Listening").
  final String label;

  /// One-line hint shown under the status bar.
  final String hint;

  final IconData icon;

  /// True while the microphone must stay closed.
  bool get locksMicrophone => this == TutorState.aiSpeaking || this == TutorState.aiThinking;

  /// True while the orb should animate.
  bool get isBusy => this != TutorState.idle;

  /// The gradient the orb and the status bar use for this state.
  LinearGradient get gradient {
    switch (this) {
      case TutorState.idle:
        return AppColors.auraGradient;
      case TutorState.userListening:
        return AppColors.listeningGradient;
      case TutorState.aiThinking:
        return AppColors.thinkingGradient;
      case TutorState.aiSpeaking:
        return AppColors.speakingGradient;
    }
  }

  /// The single accent colour for this state.
  Color get color {
    switch (this) {
      case TutorState.idle:
        return AppColors.primary;
      case TutorState.userListening:
        return AppColors.secondary;
      case TutorState.aiThinking:
        return AppColors.accent;
      case TutorState.aiSpeaking:
        return AppColors.highlight;
    }
  }
}

/// The auditable transition table.
///
/// Anything not listed here is a bug, and `VoicePipelineController._transition` asserts
/// against it in debug builds:
///
/// * `userListening → aiSpeaking` is forbidden: text-to-speech may only start
///   from `aiThinking`, i.e. after the recogniser has been stopped *and* the
///   model has produced a reply.
/// * `aiSpeaking → userListening` is forbidden: the microphone can only be
///   re-armed through `idle`, which is the state the controller enters 300 ms
///   after the TTS completion callback fires.
/// * `idle → aiSpeaking` is allowed for exactly one operation: replaying an old
///   line through TTS. It is not a "reply" — no recogniser session exists at that
///   moment, and the controller locks the microphone *before* it starts speaking,
///   then releases it 300 ms after completion, exactly like a normal turn.
const Map<TutorState, Set<TutorState>> kAllowedTransitions =
    <TutorState, Set<TutorState>>{
  TutorState.idle: <TutorState>{
    TutorState.userListening, // tap the orb
    TutorState.aiThinking, // typed input: no microphone involvement at all
    TutorState.aiSpeaking, // "replay this line" — TTS only, mic locked first
  },
  TutorState.userListening: <TutorState>{
    TutorState.aiThinking, // speech ended (or the learner tapped "send")
    TutorState.idle, // cancelled — the learner tapped X
  },
  TutorState.aiThinking: <TutorState>{
    TutorState.aiSpeaking, // reply parsed, TTS started
    TutorState.idle, // interrupted, engine error, or the reply was empty
  },
  TutorState.aiSpeaking: <TutorState>{
    TutorState.idle, // TTS completed (+300 ms) or the learner interrupted
  },
};

/// Returns true when [from] may legally move to [to].
bool canTransition(TutorState from, TutorState to) =>
    from == to || (kAllowedTransitions[from]?.contains(to) ?? false);

/// Everything the UI needs to render a session, in one immutable snapshot.
///
/// Riverpod rebuilds on every change, so this class is written to be cheap to
/// copy and to compare.
@immutable
class TutorRuntimeState {
  const TutorRuntimeState({
    this.state = TutorState.idle,
    this.turns = const <ChatMessage>[],
    this.partialTranscript = '',
    this.thinkingText = '',
    this.streamingReply = '',
    this.latestResponse,
    this.errorMessage,
    this.micLocked = false,
    this.micPermissionGranted = false,
    this.modelLoaded = false,
    this.modelDisplayName = '',
    this.engineLoading = false,
    this.engineLoadProgress = 0,
    this.sessionId,
    this.scenarioId = 'free_talk',
    this.turnCount = 0,
    this.autoListenEnabled = true,
    this.soundLevel = 0,
    this.lastLatency,
    this.lastScore,
    this.lastFeedback,
    this.wordsMinedToday = 0,
    this.sttOnDevice = true,
    this.sttLocaleAvailable = true,
    this.statusMessage = '',
  });

  final TutorState state;

  /// The conversation. Appended to, never mutated in place.
  final List<ChatMessage> turns;

  /// Live recogniser output for the current turn.
  final String partialTranscript;

  /// A short "what am I doing" line during generation ("Writing the reply…",
  /// "Checking your grammar…").
  final String thinkingText;

  /// Incrementally decoded reply text, shown in the tutor bubble while the model
  /// is still streaming. The final [ChatMessage] replaces it.
  final String streamingReply;

  /// The last fully parsed reply.
  final AiResponse? latestResponse;

  /// Set when something went wrong this turn. Cleared on the next transition.
  final String? errorMessage;

  /// **The** flag the microphone button reads. It is true from the moment TTS
  /// starts until 300 ms after the completion callback fires.
  final bool micLocked;

  final bool micPermissionGranted;

  final bool modelLoaded;
  final String modelDisplayName;

  final bool engineLoading;

  /// 0..1 during `llama_model_load`.
  final double engineLoadProgress;

  final int? sessionId;
  final String scenarioId;
  final int turnCount;

  /// Re-open the microphone automatically after the tutor finishes speaking.
  final bool autoListenEnabled;

  /// 0..1 from the recogniser's sound-level callback, for the orb animation.
  final double soundLevel;

  final Duration? lastLatency;
  final int? lastScore;

  /// Feedback of the most recent learner turn, for the pinned grammar card.
  final AiResponse? lastFeedback;

  final int wordsMinedToday;

  /// Whether the current recogniser session is running on-device only.
  final bool sttOnDevice;

  /// False when the target language has no installed recogniser — the pipeline
  /// falls back to the closest available locale and says so.
  final bool sttLocaleAvailable;

  /// Transient informational line (e.g. "Microphone permission denied").
  final String statusMessage;

  // ── Derived ───────────────────────────────────────────────────────────────

  /// The microphone may be armed *only* from `idle`, with the permission
  /// granted, a model loaded, and the lock released.
  bool get canStartListening =>
      state == TutorState.idle && !micLocked && modelLoaded && !engineLoading;

  /// The learner can type a message whenever the engine is idle.
  bool get canSubmitText => state == TutorState.idle && modelLoaded;

  /// True while the tutor's voice is playing (drives the Interrupt button).
  bool get isSpeaking => state == TutorState.aiSpeaking;

  /// True while the recogniser is open.
  bool get isListening => state == TutorState.userListening;

  bool get isThinking => state == TutorState.aiThinking;

  /// Anything in flight. Used to disable navigation and destructive actions.
  bool get isBusy => state != TutorState.idle;

  /// The scenario being practised.
  LessonScenario get scenario => Scenarios.byId(scenarioId);

  bool get hasConversation => turns.isNotEmpty;

  /// The current line shown in the "live" strip: transcript while listening,
  /// thinking text while generating.
  String get liveLine {
    switch (state) {
      case TutorState.userListening:
        return partialTranscript.trim();
      case TutorState.aiThinking:
        return streamingReply.trim().isNotEmpty ? streamingReply : thinkingText;
      case TutorState.aiSpeaking:
        return latestResponse?.ttsText ?? '';
      case TutorState.idle:
        return errorMessage ?? statusMessage;
    }
  }

  ChatMessage? get lastTutorMessage {
    for (int i = turns.length - 1; i >= 0; i--) {
      if (turns[i].isTutor) return turns[i];
    }
    return null;
  }

  ChatMessage? get lastUserMessage {
    for (int i = turns.length - 1; i >= 0; i--) {
      if (turns[i].isUser) return turns[i];
    }
    return null;
  }

  /// Learner turns that carry grammar feedback — drives the "corrections" badge
  /// on the chat header.
  int get correctionsCount => turns.where((ChatMessage m) => m.isUser && m.hasFeedback).length;

  /// Average score of the session so far, or null when nothing was scored.
  double? get sessionAverageScore {
    final List<int> scores = turns
        .where((ChatMessage m) => m.isUser && m.score != null)
        .map((ChatMessage m) => m.score!)
        .toList();
    if (scores.isEmpty) return null;
    return scores.reduce((int a, int b) => a + b) / scores.length;
  }

  String get scoreLabel {
    final double? average = sessionAverageScore;
    if (average == null) return '—';
    return average.round().toString();
  }

  /// Human-readable latency, e.g. "3.4 s".
  String get latencyLabel {
    final Duration? latency = lastLatency;
    if (latency == null) return '—';
    if (latency.inMilliseconds < 1000) return '${latency.inMilliseconds} ms';
    return '${(latency.inMilliseconds / 1000).toStringAsFixed(1)} s';
  }

  /// A short engine description for the status bar: "Qwen2.5 1.5B · ChatML".
  String get engineLabel {
    if (modelDisplayName.isEmpty) return 'no model';
    return modelDisplayName;
  }

  // ── Copying ───────────────────────────────────────────────────────────────

  TutorRuntimeState copyWith({
    TutorState? state,
    List<ChatMessage>? turns,
    String? partialTranscript,
    String? thinkingText,
    String? streamingReply,
    AiResponse? latestResponse,
    bool clearLatestResponse = false,
    String? errorMessage,
    bool clearError = false,
    bool? micLocked,
    bool? micPermissionGranted,
    bool? modelLoaded,
    String? modelDisplayName,
    bool? engineLoading,
    double? engineLoadProgress,
    int? sessionId,
    String? scenarioId,
    int? turnCount,
    bool? autoListenEnabled,
    double? soundLevel,
    Duration? lastLatency,
    int? lastScore,
    AiResponse? lastFeedback,
    bool clearLastFeedback = false,
    int? wordsMinedToday,
    bool? sttOnDevice,
    bool? sttLocaleAvailable,
    String? statusMessage,
  }) {
    return TutorRuntimeState(
      state: state ?? this.state,
      turns: turns ?? this.turns,
      partialTranscript: partialTranscript ?? this.partialTranscript,
      thinkingText: thinkingText ?? this.thinkingText,
      streamingReply: streamingReply ?? this.streamingReply,
      latestResponse:
          clearLatestResponse ? null : (latestResponse ?? this.latestResponse),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      micLocked: micLocked ?? this.micLocked,
      micPermissionGranted: micPermissionGranted ?? this.micPermissionGranted,
      modelLoaded: modelLoaded ?? this.modelLoaded,
      modelDisplayName: modelDisplayName ?? this.modelDisplayName,
      engineLoading: engineLoading ?? this.engineLoading,
      engineLoadProgress: engineLoadProgress ?? this.engineLoadProgress,
      sessionId: sessionId ?? this.sessionId,
      scenarioId: scenarioId ?? this.scenarioId,
      turnCount: turnCount ?? this.turnCount,
      autoListenEnabled: autoListenEnabled ?? this.autoListenEnabled,
      soundLevel: soundLevel ?? this.soundLevel,
      lastLatency: lastLatency ?? this.lastLatency,
      lastScore: lastScore ?? this.lastScore,
      lastFeedback: clearLastFeedback ? null : (lastFeedback ?? this.lastFeedback),
      wordsMinedToday: wordsMinedToday ?? this.wordsMinedToday,
      sttOnDevice: sttOnDevice ?? this.sttOnDevice,
      sttLocaleAvailable: sttLocaleAvailable ?? this.sttLocaleAvailable,
      statusMessage: statusMessage ?? this.statusMessage,
    );
  }

  /// One-line diagnostic summary used by the debug overlay and the logger.
  String get debugSummary =>
      'state=${state.name} micLocked=$micLocked turns=${turns.length} '
      'model=${modelLoaded ? 'loaded' : 'none'} latency=$latencyLabel';

  @override
  String toString() => 'TutorRuntimeState($debugSummary)';
}
