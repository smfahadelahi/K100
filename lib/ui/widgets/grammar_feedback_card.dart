import 'package:flutter/material.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/ai_response.dart';
import 'package:k100/models/chat_message.dart';

/// The expandable "Grammar & Feedback" card that sits under a learner bubble.
///
/// It is deliberately compact when collapsed — the learner is mid-conversation
/// and should not have to scroll past an essay to see the tutor's reply. The
/// score, the badge and the header line are visible at a glance; the correction
/// and the explanation open on tap.
///
/// Nothing is shown when the turn produced no feedback at all: an empty card is
/// worse than no card, and a 1.5B model does occasionally produce a clean turn
/// with `grammar_correction: null`.
class GrammarFeedbackCard extends StatefulWidget {
  const GrammarFeedbackCard({super.key, required this.message});

  final ChatMessage message;

  @override
  State<GrammarFeedbackCard> createState() => _GrammarFeedbackCardState();
}

class _GrammarFeedbackCardState extends State<GrammarFeedbackCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ChatMessage message = widget.message;

    if (!message.isUser) return const SizedBox.shrink();
    if (!message.hasFeedback && !message.recoveredFromMalformedJson) {
      return const SizedBox.shrink();
    }

    final bool hasCorrection = message.hasCorrection;
    final bool hasExplanation = message.hasExplanation;
    final int? score = message.score;
    final Color scoreColor = AppTheme.scoreColor(score ?? 0);
    final bool expandable = hasCorrection || hasExplanation;

    return Padding(
      padding: const EdgeInsets.only(top: 7, left: 8, right: 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(13),
          border: Border.all(
            color: hasCorrection
                ? AppColors.secondary.withValues(alpha: 0.28)
                : AppColors.outline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _header(theme, scoreColor, score, hasCorrection, expandable),
            if (_expanded && expandable) ...<Widget>[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (hasCorrection) ...<Widget>[
                      _label(theme, 'BETTER WAY TO SAY IT'),
                      const SizedBox(height: 4),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Icon(Icons.check_circle_outline,
                              size: 14, color: AppColors.secondary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: SelectableText(
                              message.correction!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: AppColors.textPrimary,
                                height: 1.35,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _label(theme, 'WHAT YOU SAID'),
                      const SizedBox(height: 4),
                      Text(
                        message.text,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.textTertiary,
                          height: 1.35,
                          decoration: TextDecoration.lineThrough,
                          decorationColor: AppColors.textTertiary,
                        ),
                      ),
                    ],
                    if (hasExplanation) ...<Widget>[
                      if (hasCorrection) const SizedBox(height: 12),
                      _label(theme, 'WHY'),
                      const SizedBox(height: 4),
                      Text(
                        message.explanation!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.textSecondary,
                          height: 1.45,
                        ),
                      ),
                    ],
                    if ((message.romanization ?? '').isNotEmpty) ...<Widget>[
                      const SizedBox(height: 10),
                      _label(theme, 'PRONUNCIATION'),
                      const SizedBox(height: 4),
                      Text(
                        message.romanization!,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontStyle: FontStyle.italic,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if ((message.parseMode ?? AiParseMode.strictJson).isDegraded) ...<Widget>[
                      const SizedBox(height: 12),
                      _degradedNote(theme, message.parseMode ?? AiParseMode.strictJson),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(
    ThemeData theme,
    Color scoreColor,
    int? score,
    bool hasCorrection,
    bool expandable,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(13),
      onTap: expandable ? () => setState(() => _expanded = !_expanded) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Row(
          children: <Widget>[
            Icon(
              hasCorrection ? Icons.auto_awesome : Icons.thumb_up_alt_outlined,
              size: 15,
              color: hasCorrection ? AppColors.secondary : AppColors.textTertiary,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                hasCorrection
                    ? 'Grammar & Feedback'
                    : 'Nice — nothing to correct here',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: AppColors.textSecondary,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
            ),
            if (score != null) _scorePill(theme, scoreColor, score),
            if (expandable)
              AnimatedRotation(
                turns: _expanded ? 0.5 : 0,
                duration: const Duration(milliseconds: 180),
                child: const Icon(Icons.expand_more,
                    size: 18, color: AppColors.textTertiary),
              ),
          ],
        ),
      ),
    );
  }

  Widget _scorePill(ThemeData theme, Color color, int score) {
    final String word = score >= 85
        ? 'excellent'
        : score >= 70
            ? 'good'
            : score >= 50
                ? 'fair'
                : 'keep going';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '$score',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            word,
            style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _label(ThemeData theme, String text) => Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 9,
          letterSpacing: 0.9,
          color: AppColors.textTertiary,
          fontWeight: FontWeight.w700,
        ),
      );

  Widget _degradedNote(ThemeData theme, AiParseMode mode) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Icon(Icons.info_outline, size: 13, color: AppColors.warning),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                mode.explanation,
                style: theme.textTheme.labelSmall?.copyWith(
                  fontSize: 10,
                  height: 1.4,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
}
