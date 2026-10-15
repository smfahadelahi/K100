import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:k100/core/constants.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:k100/models/scenario.dart';
import 'package:k100/models/tutor_state.dart';
import 'package:k100/providers/app_providers.dart';
import 'package:k100/services/voice_pipeline_controller.dart';
import 'package:k100/ui/widgets/chat_bubble.dart';
import 'package:k100/ui/widgets/pipeline_status_bar.dart';
import 'package:k100/ui/widgets/voice_orb.dart';

/// The conversation screen.
///
/// The layout is built around one rule: **the orb is always in the same place**,
/// so the learner never has to look for the microphone. Everything else (the
/// status strip, the interrupt button, the keyboard fallback) appears and
/// disappears around it.
class ChatTutorScreen extends ConsumerStatefulWidget {
  const ChatTutorScreen({super.key, required this.scenario});

  final LessonScenario scenario;

  @override
  ConsumerState<ChatTutorScreen> createState() => _ChatTutorScreenState();
}

class _ChatTutorScreenState extends ConsumerState<ChatTutorScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _text = TextEditingController();
  final FocusNode _textFocus = FocusNode();
  bool _showKeyboard = false;
  int _lastTurnCount = 0;

  VoicePipelineController get _controller =>
      ref.read(tutorControllerProvider.notifier);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _controller.bootstrap();
      await _controller.beginScenario(widget.scenario);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _text.dispose();
    _textFocus.dispose();
    super.dispose();
  }

  void _maybeScroll(int turnCount) {
    if (turnCount == _lastTurnCount) return;
    _lastTurnCount = turnCount;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    });
  }

  /// Fire-and-forget on purpose: a haptic tap must never delay the turn, so the
  /// returned Future is explicitly discarded with `unawaited`.
  void _haptic({bool heavy = false}) {
    if (!ref.read(profileProvider).haptics) return;
    if (heavy) {
      unawaited(HapticFeedback.mediumImpact());
    } else {
      unawaited(HapticFeedback.selectionClick());
    }
  }

  Future<void> _close() async {
    await _controller.endSession();
    // `maybePop` returns a Future: awaiting it keeps the analysis clean and means
    // the route is fully gone before the caller continues.
    if (mounted) await Navigator.of(context).maybePop();
  }

  Future<void> _onOrbTap(TutorRuntimeState state) async {
    _haptic(heavy: true);
    switch (state.state) {
      case TutorState.idle:
        if (!state.modelLoaded) {
          _snack('Download a model first — the engine has nothing to think with.');
          return;
        }
        if (state.micLocked) {
          _snack('The microphone is still closed for a moment — try again.');
          return;
        }
        await _controller.startListening();
      case TutorState.userListening:
        await _controller.finishSpeakingNow();
      case TutorState.aiThinking:
      case TutorState.aiSpeaking:
        await _controller.interrupt();
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TutorRuntimeState state = ref.watch(tutorControllerProvider);
    final LearnerProfile profile = ref.watch(profileProvider);
    final LessonScenario scenario = Scenarios.byId(state.scenarioId);
    _maybeScroll(state.turns.length);

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) unawaited(_controller.endSession());
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: Container(
          decoration: const BoxDecoration(gradient: AppColors.screenGradient),
          child: SafeArea(
            child: Column(
              children: <Widget>[
                _header(theme, state, scenario, profile),
                PipelineStatusBar(
                  state: state.state,
                  micLocked: state.micLocked,
                  latency: state.lastLatency,
                  detail: state.modelLoaded
                      ? (state.sttOnDevice ? 'on-device STT' : 'STT fallback')
                      : 'no model',
                ),
                MicLockExplainer(state: state.state),
                Expanded(child: _conversation(theme, state, scenario, profile)),
                if (state.state == TutorState.aiSpeaking) _interruptBanner(theme),
                _liveLine(theme, state),
                _controls(theme, state),
                if (_showKeyboard) _keyboardRow(theme, state),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _header(
    ThemeData theme,
    TutorRuntimeState state,
    LessonScenario scenario,
    LearnerProfile profile,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 14, 4),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => unawaited(_close()),
            icon: const Icon(Icons.arrow_back),
          ),
          GestureDetector(
            onTap: () => _showScenarioSheet(scenario),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(scenario.emoji, style: const TextStyle(fontSize: 18)),
                    const SizedBox(width: 7),
                    Text(scenario.title, style: theme.textTheme.titleMedium),
                    const SizedBox(width: 6),
                    const Icon(Icons.info_outline, size: 13, color: AppColors.textTertiary),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${profile.targetLanguage.flag} ${profile.targetLanguage.englishName} · '
                  '${profile.proficiency.cefr} · ${state.correctionsCount} corrections',
                  style: theme.textTheme.labelSmall,
                ),
              ],
            ),
          ),
          const Spacer(),
          _AutoListenToggle(
            enabled: state.autoListenEnabled,
            onChanged: (bool value) {
              _haptic();
              _controller.setAutoListen(value);
              ref.read(profileProvider.notifier).setAutoListen(value);
            },
          ),
        ],
      ),
    );
  }

  // ── Conversation ──────────────────────────────────────────────────────────

  Widget _conversation(
    ThemeData theme,
    TutorRuntimeState state,
    LessonScenario scenario,
    LearnerProfile profile,
  ) {
    if (state.turns.isEmpty) {
      return _emptyState(theme, state, scenario, profile);
    }
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 12),
      itemCount: state.turns.length,
      itemBuilder: (BuildContext context, int index) {
        final ChatMessage message = state.turns[index];
        return ChatBubble(
          message: message,
          showTranslation: profile.showTranslations,
          isLatest: index == state.turns.length - 1,
          onReplay: message.isTutor ? (String _) => _replay(message.text) : null,
        );
      },
    );
  }

  /// Replays a line. Kept on the controller so the microphone lock still applies.
  Future<void> _replay(String text) async {
    await _controller.replayLine(text);
  }

  Widget _emptyState(
    ThemeData theme,
    TutorRuntimeState state,
    LessonScenario scenario,
    LearnerProfile profile,
  ) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(26, 20, 26, 20),
      child: Column(
        children: <Widget>[
          const SizedBox(height: 12),
          Text(scenario.emoji, style: const TextStyle(fontSize: 40)),
          const SizedBox(height: 12),
          Text(
            scenario.goal,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(height: 1.4),
          ),
          const SizedBox(height: 10),
          Text(
            scenario.roleBrief,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
          ),
          const SizedBox(height: 22),
          Text(
            'TRY SAYING',
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: 10),
          ...scenario.starterPrompts.map(
            (String prompt) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: GestureDetector(
                onTap: () {
                  setState(() => _showKeyboard = true);
                  _text.text = prompt;
                  _textFocus.requestFocus();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: AppColors.outline),
                  ),
                  child: Row(
                    children: <Widget>[
                      const Icon(Icons.edit_note, size: 16, color: AppColors.textTertiary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(prompt, style: theme.textTheme.bodySmall),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (scenario.vocabulary.isNotEmpty) ...<Widget>[
            const SizedBox(height: 18),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              alignment: WrapAlignment.center,
              children: scenario.vocabulary
                  .map((String word) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          word,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                      ))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  // ── Live strip ────────────────────────────────────────────────────────────

  Widget _liveLine(ThemeData theme, TutorRuntimeState state) {
    final String? live = switch (state.state) {
      TutorState.userListening => state.partialTranscript.isEmpty
          ? 'Listening… speak naturally, I will stop when you pause.'
          : state.partialTranscript,
      TutorState.aiThinking => state.streamingReply.isEmpty
          ? (state.thinkingText.isEmpty ? 'Thinking…' : state.thinkingText)
          : state.streamingReply,
      TutorState.aiSpeaking => null,
      TutorState.idle => state.errorMessage ?? state.statusMessage,
    };

    if (live == null || live.isEmpty) return const SizedBox(height: 4);

    final bool isError = state.state == TutorState.idle && state.errorMessage != null;
    final Color accent = isError
        ? AppColors.danger
        : state.state == TutorState.userListening
            ? AppColors.secondary
            : AppColors.accent;

    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Container(
        key: ValueKey<String>(live.length > 24 ? live.substring(0, 24) : live),
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 2, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: <Widget>[
            if (!isError && state.state != TutorState.idle)
              Padding(
                padding: const EdgeInsets.only(right: 9),
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    valueColor: AlwaysStoppedAnimation<Color>(accent),
                  ),
                ),
              ),
            Expanded(
              child: Text(
                live,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isError ? AppColors.danger : AppColors.textSecondary,
                  fontStyle: state.state == TutorState.aiThinking
                      ? FontStyle.italic
                      : FontStyle.normal,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _interruptBanner(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.danger,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
        ),
        onPressed: () {
          _haptic(heavy: true);
          unawaited(_controller.interrupt());
        },
        icon: const Icon(Icons.stop_circle_outlined, size: 20),
        label: const Text('Stop speaking'),
      ),
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _controls(ThemeData theme, TutorRuntimeState state) {
    final bool listening = state.state == TutorState.userListening;
    final bool busy = state.state != TutorState.idle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Column(
        children: <Widget>[
          VoiceOrb(
            state: state.state,
            soundLevel: state.soundLevel,
            size: 168,
            enabled: state.modelLoaded,
            label: _orbLabel(state),
            onTap: () => _onOrbTap(state),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              _circleButton(
                icon: _showKeyboard ? Icons.keyboard_hide : Icons.keyboard,
                tooltip: 'Type instead of speaking',
                enabled: !busy,
                onTap: () {
                  _haptic();
                  setState(() => _showKeyboard = !_showKeyboard);
                  if (_showKeyboard) _textFocus.requestFocus();
                },
              ),
              _circleButton(
                icon: listening ? Icons.close : Icons.refresh,
                tooltip: listening ? 'Cancel this turn' : 'Reset the turn',
                enabled: busy || state.errorMessage != null,
                onTap: () {
                  _haptic();
                  if (listening) {
                    unawaited(_controller.cancelListening());
                  } else {
                    unawaited(_controller.interrupt());
                  }
                },
              ),
              _circleButton(
                icon: Icons.help_outline,
                tooltip: 'Scenario briefing',
                enabled: true,
                onTap: () => _showScenarioSheet(Scenarios.byId(state.scenarioId)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _orbLabel(TutorRuntimeState state) {
    switch (state.state) {
      case TutorState.idle:
        if (!state.modelLoaded) return 'Model required';
        if (state.micLocked) return 'Unlocking…';
        return 'Tap to speak';
      case TutorState.userListening:
        return 'Tap to send';
      case TutorState.aiThinking:
        return 'Thinking — tap to stop';
      case TutorState.aiSpeaking:
        return 'Tap to stop the voice';
    }
  }

  Widget _circleButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool enabled = true,
  }) =>
      Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: enabled ? onTap : null,
          borderRadius: BorderRadius.circular(26),
          child: Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: AppColors.surface,
              shape: BoxShape.circle,
              border: Border.all(color: AppColors.outline),
            ),
            child: Icon(
              icon,
              size: 20,
              color: enabled ? AppColors.textSecondary : AppColors.textTertiary,
            ),
          ),
        ),
      );

  Widget _keyboardRow(ThemeData theme, TutorRuntimeState state) {
    final bool busy = state.state != TutorState.idle;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _text,
              focusNode: _textFocus,
              enabled: !busy,
              maxLines: 3,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (String value) => _send(value),
              decoration: InputDecoration(
                hintText: busy
                    ? 'Wait for the tutor…'
                    : 'Type in ${ref.read(profileProvider).targetLanguage.englishName}…',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: busy ? null : () => _send(_text.text),
            icon: const Icon(Icons.send, size: 18),
          ),
        ],
      ),
    );
  }

  Future<void> _send(String value) async {
    final String text = value.trim();
    if (text.isEmpty) return;
    _text.clear();
    _haptic();
    if (_showKeyboard) setState(() => _showKeyboard = false);
    await _controller.submitText(text);
  }

  // ── Scenario sheet ────────────────────────────────────────────────────────

  void _showScenarioSheet(LessonScenario scenario) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text(scenario.emoji, style: const TextStyle(fontSize: 22)),
                const SizedBox(width: 10),
                Text(scenario.title, style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Text(scenario.levelBadge,
                    style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
            const SizedBox(height: 12),
            Text('YOUR MISSION', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(scenario.goal, style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 14),
            Text('THE TUTOR PLAYS', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(scenario.roleBrief, style: Theme.of(context).textTheme.bodySmall),
            if (scenario.vocabulary.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text('WORDS TO USE', style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: scenario.vocabulary
                    .map((String word) => Chip(
                          label: Text(word, style: const TextStyle(fontSize: 11)),
                          backgroundColor: AppColors.surfaceHigh,
                          side: const BorderSide(color: AppColors.outline),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: <Widget>[
                const Icon(Icons.lock_outline, size: 13, color: AppColors.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'The tutor will not hear you while it is speaking: the '
                    'microphone re-opens '
                    '${AppConfig.postTtsMicUnlockDelay.inMilliseconds} ms after its '
                    'voice stops.',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(height: 1.4),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Hands-free toggle with an explicit label — this switch changes the app's
/// behaviour more than any other setting.
class _AutoListenToggle extends StatelessWidget {
  const _AutoListenToggle({required this.enabled, required this.onChanged});

  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: enabled
          ? 'Hands-free: the microphone re-opens automatically after each reply'
          : 'Tap to talk: you start every turn yourself',
      child: InkWell(
        onTap: () => onChanged(!enabled),
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: enabled
                ? AppColors.secondary.withValues(alpha: 0.15)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: enabled
                  ? AppColors.secondary.withValues(alpha: 0.5)
                  : AppColors.outline,
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                enabled ? Icons.hearing : Icons.hearing_disabled,
                size: 14,
                color: enabled ? AppColors.secondary : AppColors.textTertiary,
              ),
              const SizedBox(width: 5),
              Text(
                enabled ? 'Hands-free' : 'Tap to talk',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  color: enabled ? AppColors.secondary : AppColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
