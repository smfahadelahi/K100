import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:k100/core/theme.dart';
import 'package:k100/models/tutor_state.dart';

/// The breathing orb that *is* this app's interface.
///
/// It reads the pipeline state at a glance, without a label:
///
///  * **idle** — a slow, calm breath. Nothing is happening; tap me.
///  * **listening** — the rings expand with the learner's actual voice level, so
///    there is immediate visual proof that the microphone is live.
///  * **thinking** — tight, fast ripples while llama.cpp decodes.
///  * **speaking** — a slow, wide pulse that reads as "someone is talking".
///
/// The animation is a single `AnimationController`: on a phone already spending
/// its CPU on token generation, a second ticker per ring would be a real cost.
class VoiceOrb extends StatefulWidget {
  const VoiceOrb({
    super.key,
    required this.state,
    required this.onTap,
    this.soundLevel = 0,
    this.size = 168,
    this.label,
    this.enabled = true,
    this.showHint = true,
  });

  final TutorState state;
  final VoidCallback onTap;

  /// 0..1 from the recogniser's sound-level callback.
  final double soundLevel;

  final double size;

  /// Overrides the built-in hint (the chat screen passes a contextual line).
  final String? label;

  /// False when there is no model loaded — the orb dims and stops reacting.
  final bool enabled;

  final bool showHint;

  @override
  State<VoiceOrb> createState() => _VoiceOrbState();
}

class _VoiceOrbState extends State<VoiceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _ticker = AnimationController(
    vsync: this,
    duration: _durationFor(widget.state),
  )..repeat();

  /// Smoothed level, so the rings glide instead of twitching on every callback.
  double _level = 0;

  static Duration _durationFor(TutorState state) {
    switch (state) {
      case TutorState.idle:
        return const Duration(milliseconds: 3200);
      case TutorState.userListening:
        return const Duration(milliseconds: 1500);
      case TutorState.aiThinking:
        return const Duration(milliseconds: 900);
      case TutorState.aiSpeaking:
        return const Duration(milliseconds: 1900);
    }
  }

  @override
  void didUpdateWidget(covariant VoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      _ticker
        ..stop()
        ..duration = _durationFor(widget.state)
        ..reset()
        ..repeat();
    }
    // Exponential smoothing: rise fast (the learner wants feedback *now*), fall
    // slowly (rings that snap shut look broken).
    final double target = widget.enabled ? widget.soundLevel.clamp(0.0, 1.0) : 0;
    _level = target > _level ? (_level * 0.35) + (target * 0.65) : (_level * 0.82);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TutorState state = widget.state;
    final Color accent = widget.enabled ? state.color : AppColors.textTertiary;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: AnimatedBuilder(
              animation: _ticker,
              builder: (BuildContext context, Widget? child) => CustomPaint(
                painter: _OrbPainter(
                  t: _ticker.value,
                  state: state,
                  level: _level,
                  enabled: widget.enabled,
                  accent: accent,
                  gradient: widget.enabled
                      ? state.gradient
                      : const LinearGradient(
                          colors: <Color>[AppColors.outline, AppColors.surfaceHigh],
                        ),
                ),
                child: child,
              ),
              child: Center(
                child: Icon(
                  state.icon,
                  size: widget.size * 0.22,
                  color: widget.enabled
                      ? Colors.white.withValues(alpha: 0.92)
                      : AppColors.textTertiary,
                ),
              ),
            ),
          ),
        ),
        if (widget.showHint) ...<Widget>[
          const SizedBox(height: 14),
          Text(
            widget.label ?? state.hint,
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall?.copyWith(
              color: widget.enabled ? AppColors.textSecondary : AppColors.textTertiary,
              height: 1.4,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ],
    );
  }
}

class _OrbPainter extends CustomPainter {
  const _OrbPainter({
    required this.t,
    required this.state,
    required this.level,
    required this.enabled,
    required this.accent,
    required this.gradient,
  });

  /// Animation phase, 0..1.
  final double t;

  final TutorState state;
  final double level;
  final bool enabled;
  final Color accent;
  final LinearGradient gradient;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset center = Offset(size.width / 2, size.height / 2);
    final double maxRadius = size.width / 2;
    final double coreRadius = maxRadius * 0.52;

    // ── Outer rings ────────────────────────────────────────────────────────
    // Each ring is offset in phase so the orb looks like it breathes outward
    // rather than blinking.
    final int ringCount = state == TutorState.aiThinking ? 3 : 2;
    for (int i = 0; i < ringCount; i++) {
      final double phase = (t + (i / ringCount)) % 1.0;
      final double radius = coreRadius + (maxRadius - coreRadius) * phase;
      final double opacity = (1 - phase) * (enabled ? 0.30 : 0.10);

      final double levelBoost = state == TutorState.userListening ? level * 0.55 : 0.0;
      canvas.drawCircle(
        center,
        radius + (maxRadius * levelBoost * 0.12),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = accent.withValues(alpha: opacity.clamp(0.0, 1.0)),
      );
    }

    // ── Aura ───────────────────────────────────────────────────────────────
    final double breath = state == TutorState.idle
        ? 0.5 + (math.sin(t * math.pi * 2) * 0.5)
        : state == TutorState.userListening
            ? 0.35 + (level * 0.65)
            : 0.5 + (math.sin(t * math.pi * 2).abs() * 0.5);

    canvas.drawCircle(
      center,
      coreRadius * (1.22 + (breath * 0.16)),
      Paint()
        ..shader = gradient.createShader(
          Rect.fromCircle(center: center, radius: coreRadius * 1.4),
        )
        ..color = accent.withValues(alpha: enabled ? 0.22 + (breath * 0.16) : 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // ── Core ───────────────────────────────────────────────────────────────
    canvas.drawCircle(
      center,
      coreRadius,
      Paint()
        ..shader = gradient.createShader(
          Rect.fromCircle(center: center, radius: coreRadius),
        ),
    );

    // Specular highlight: one soft light from the top-left makes a flat circle
    // read as a sphere.
    canvas.drawCircle(
      center.translate(-coreRadius * 0.3, -coreRadius * 0.34),
      coreRadius * 0.34,
      Paint()
        ..color = Colors.white.withValues(alpha: enabled ? 0.16 : 0.06)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // ── Level meter ────────────────────────────────────────────────────────
    // While listening, a ring whose radius *is* the input level. This is the
    // honest signal that the microphone is open — it moves only when the
    // learner speaks.
    if (state == TutorState.userListening && level > 0.02) {
      canvas.drawCircle(
        center,
        coreRadius * (1.06 + (level * 0.42)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..color = AppColors.secondary.withValues(alpha: 0.55 + (level * 0.4)),
      );
    }

    // ── Thinking arc ───────────────────────────────────────────────────────
    // A single sweep that spins while the model decodes: the only motion in the
    // app that means "work is happening".
    if (state == TutorState.aiThinking) {
      final double start = t * math.pi * 2;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: coreRadius * 1.3),
        start,
        math.pi * 0.5,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3
          ..color = accent.withValues(alpha: 0.85),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _OrbPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.state != state ||
      oldDelegate.level != level ||
      oldDelegate.enabled != enabled;
}
