import 'package:flutter/material.dart';
import 'package:k100/core/theme.dart';

/// A small circular "say that again" button.
///
/// It owns one piece of state — whether speech is playing — purely so the learner
/// gets an immediate visual acknowledgement that the tap registered. Replaying a
/// long sentence on a phone takes a moment to start, and a button that appears to
/// do nothing gets tapped five times.
class SpeakerButton extends StatefulWidget {
  const SpeakerButton({
    super.key,
    required this.onPressed,
    this.enabled = true,
    this.label,
    this.iconSize = 16,
    this.tooltip = 'Play again',
  });

  /// Returns when playback has finished (or was stopped).
  final Future<void> Function() onPressed;

  final bool enabled;
  final String? label;
  final double iconSize;
  final String tooltip;

  @override
  State<SpeakerButton> createState() => _SpeakerButtonState();
}

class _SpeakerButtonState extends State<SpeakerButton> {
  bool _busy = false;

  Future<void> _run() async {
    if (_busy || !widget.enabled) return;
    setState(() => _busy = true);
    try {
      await widget.onPressed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool active = widget.enabled && !_busy;
    final Color color = active ? AppColors.secondary : AppColors.textTertiary;

    return Tooltip(
      message: widget.tooltip,
      child: InkWell(
        onTap: active ? _run : null,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.28)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: widget.iconSize,
                height: widget.iconSize,
                child: _busy
                    ? CircularProgressIndicator(
                        strokeWidth: 1.6,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      )
                    : Icon(Icons.volume_up_rounded, size: widget.iconSize, color: color),
              ),
              if ((widget.label ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(width: 6),
                Text(
                  widget.label!,
                  style: TextStyle(
                    color: color,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
