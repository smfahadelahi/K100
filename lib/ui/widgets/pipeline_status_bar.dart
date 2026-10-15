import 'package:flutter/material.dart';
import 'package:k100/core/theme.dart';
import 'package:k100/models/tutor_state.dart';

/// The pipeline strip above the conversation: which stage is running, whether
/// the microphone is open, and how fast the last reply was produced.
///
/// This is not decoration. On a phone running a 1.5B model, the difference
/// between "the tutor is thinking" and "the app has frozen" is invisible without
/// it, and the microphone badge is the visible half of the anti-loop contract.
class PipelineStatusBar extends StatelessWidget {
  const PipelineStatusBar({
    super.key,
    required this.state,
    this.micLocked = false,
    this.latency,
    this.tokensPerSecond = 0,
    this.detail,
  });

  final TutorState state;

  /// The lock the pipeline holds. `true` means the recogniser physically cannot
  /// be armed, no matter what the learner taps.
  final bool micLocked;

  final Duration? latency;
  final double tokensPerSecond;

  /// Optional extra line (the model name, an error, a hint).
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.outline.withValues(alpha: 0.5)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _StageDot(state: state),
              const SizedBox(width: 9),
              Text(
                state.label,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: state.color,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 10),
              _MicBadge(locked: micLocked, state: state),
              const Spacer(),
              if (latency != null)
                Text(
                  _latency(latency!),
                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 10.5),
                ),
              if (tokensPerSecond > 0) ...<Widget>[
                const SizedBox(width: 8),
                Text(
                  '${tokensPerSecond.toStringAsFixed(1)} tok/s',
                  style: theme.textTheme.labelSmall?.copyWith(fontSize: 10.5),
                ),
              ],
            ],
          ),
          if ((detail ?? '').isNotEmpty) ...<Widget>[
            const SizedBox(height: 5),
            Text(
              detail!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                height: 1.35,
                color: AppColors.textTertiary,
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _latency(Duration value) {
    if (value.inMilliseconds < 1000) return '${value.inMilliseconds} ms';
    return '${(value.inMilliseconds / 1000).toStringAsFixed(1)} s';
  }
}

/// A dot that pulses while a stage is active. A spinner here would suggest work
/// is happening when the stage may just be waiting for the learner to speak.
class _StageDot extends StatefulWidget {
  const _StageDot({required this.state});

  final TutorState state;

  @override
  State<_StageDot> createState() => _StageDotState();
}

class _StageDotState extends State<_StageDot> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.state.isBusy) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _StageDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.state.isBusy && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.state.isBusy && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color color = widget.state.color;
    return SizedBox(
      width: 12,
      height: 12,
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (BuildContext context, Widget? child) {
          final double scale = widget.state.isBusy ? 0.55 + (_pulse.value * 0.45) : 1;
          return Center(
            child: Container(
              width: 12 * scale,
              height: 12 * scale,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: color.withValues(alpha: 0.35),
                    blurRadius: 8 * scale,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _MicBadge extends StatelessWidget {
  const _MicBadge({required this.locked, required this.state});

  final bool locked;
  final TutorState state;

  @override
  Widget build(BuildContext context) {
    final bool listening = state == TutorState.userListening;
    final Color color = locked
        ? AppColors.danger
        : listening
            ? AppColors.secondary
            : AppColors.textTertiary;
    final String label = locked
        ? 'MIC LOCKED'
        : listening
            ? 'MIC OPEN'
            : 'MIC READY';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(
            locked
                ? Icons.mic_off
                : listening
                    ? Icons.mic
                    : Icons.mic_none,
            size: 10.5,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.6,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Explains, in one sentence, why the microphone icon is greyed out. Shown
/// exactly when a learner is most likely to tap it and be confused.
class MicLockExplainer extends StatelessWidget {
  const MicLockExplainer({super.key, required this.state});

  final TutorState state;

  @override
  Widget build(BuildContext context) {
    if (!state.locksMicrophone) return const SizedBox.shrink();
    final ThemeData theme = Theme.of(context);

    final String text = state == TutorState.aiSpeaking
        ? 'The microphone is closed while the tutor speaks so it cannot hear '
            'itself. It re-opens automatically 0.3 s after the voice stops — or '
            'tap Stop to cut it short.'
        : 'The microphone is closed while the reply is generated. It re-opens '
            'by itself in a moment.';

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Icon(Icons.hearing_disabled, size: 15, color: AppColors.danger),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelSmall?.copyWith(
                fontSize: 10.5,
                height: 1.4,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
