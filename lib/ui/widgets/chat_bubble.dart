import 'package:flutter/material.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/ui/widgets/grammar_feedback_card.dart';
import 'package:k100/ui/widgets/speaker_button.dart';

/// One line of the conversation.
///
/// Learner turns are right-aligned and carry their grammar feedback directly
/// underneath — the correction belongs next to the sentence it corrects, not in a
/// separate screen the learner has to go looking for. Tutor turns are
/// left-aligned, with the translation and the mined key phrase below the bubble.
class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.message,
    this.showTranslation = true,
    this.showFeedback = true,
    this.onReplay,
    this.isLatest = false,
  });

  final ChatMessage message;

  /// The learner can hide the native-language line entirely (immersion mode).
  final bool showTranslation;

  final bool showFeedback;

  /// Speaking a tutor line again is a TTS call the controller has to own, because
  /// the microphone lock still applies. Null disables the button.
  final void Function(String text)? onReplay;

  final bool isLatest;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isUser = message.isUser;

    return Padding(
      padding: EdgeInsets.only(bottom: isLatest ? 6 : 14),
      child: Column(
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (!isUser) ...<Widget>[
                const _Avatar(),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment: isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: <Widget>[
                    _bubble(context, theme, isUser),
                    if (!isUser) _tutorMeta(theme, isUser),
                  ],
                ),
              ),
            ],
          ),
          if (isUser && showFeedback) GrammarFeedbackCard(message: message),
        ],
      ),
    );
  }

  Widget _bubble(BuildContext context, ThemeData theme, bool isUser) {
    final Color fill = isUser ? AppColors.primary.withValues(alpha: 0.9) : AppColors.surfaceHigh;
    final Color text = isUser ? Colors.white : AppColors.textPrimary;
    final Radius near = const Radius.circular(16);
    final Radius far = isUser ? const Radius.circular(4) : const Radius.circular(16);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.sizeOf(context).width * 0.78,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.only(
            topLeft: isUser ? near : far,
            topRight: isUser ? far : near,
            bottomLeft: near,
            bottomRight: near,
          ),
          border: Border.all(
            color: isUser
                ? AppColors.primary.withValues(alpha: 0.5)
                : AppColors.outline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SelectableText(
              message.text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: text,
                height: 1.42,
                fontSize: 15,
              ),
            ),
            if ((message.romanization ?? '').isNotEmpty) ...<Widget>[
              const SizedBox(height: 5),
              Text(
                message.romanization!,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontStyle: FontStyle.italic,
                  color: isUser
                      ? Colors.white.withValues(alpha: 0.8)
                      : AppColors.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Everything under a tutor bubble: the replay button, the native translation,
  /// the phrase worth stealing, and an honest badge when the JSON needed repair.
  Widget _tutorMeta(ThemeData theme, bool isUser) {
    final bool hasTranslation = showTranslation && (message.translation ?? '').isNotEmpty;
    final bool hasPhrase = (message.keyPhrase ?? '').isNotEmpty;
    final bool degraded = message.recoveredFromMalformedJson;
    if (!hasTranslation && !hasPhrase && !degraded && onReplay == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (hasTranslation) ...<Widget>[
            Text(
              message.translation!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textTertiary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (hasPhrase) ...<Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(Icons.bookmark_added_outlined,
                      size: 12, color: AppColors.accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      (message.keyPhraseTranslation ?? '').isEmpty
                          ? message.keyPhrase!
                          : '${message.keyPhrase} — ${message.keyPhraseTranslation}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: <Widget>[
              if (onReplay != null)
                SpeakerButton(
                  onPressed: () async => onReplay!(message.text),
                  tooltip: 'Say that again',
                ),
              if (degraded) ...<Widget>[
                const SizedBox(width: 6),
                const _DegradedBadge(),
              ],
              if (message.latencyMs != null) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  '${(message.latencyMs! / 1000).toStringAsFixed(1)} s',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontSize: 9.5,
                    color: AppColors.textTertiary,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        gradient: AppColors.auraGradient,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.graphic_eq, size: 14, color: Colors.white),
    );
  }
}

/// Shows when the model's JSON needed repair. Deliberately understated — the
/// learner did nothing wrong, and the reply itself is still fine.
class _DegradedBadge extends StatelessWidget {
  const _DegradedBadge();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'The model drifted from its response format this turn — the '
          'next one is generated more strictly.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.auto_fix_high, size: 10, color: AppColors.warning),
            SizedBox(width: 4),
            Text(
              'repaired',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: AppColors.warning,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
