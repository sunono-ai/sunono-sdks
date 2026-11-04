// Older analyzers flag the deprecated class's own uses (its State) here.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// The assistant's presence: a brand-gradient orb whose blobs drift slowly at
/// rest and swirl while thinking. Static when the OS asks for reduced motion.
///
/// No longer used by the chat (0.3 is flat); kept for hosts that show it.
@Deprecated('The 0.3 design is flat and no longer shows the orb. Removed in 1.0.')
class PresenceOrb extends StatefulWidget {
  const PresenceOrb({super.key, required this.theme, this.size = 36, this.thinking = false});

  final SunonoTheme theme;
  final double size;
  final bool thinking;

  @override
  State<PresenceOrb> createState() => _PresenceOrbState();
}

class _PresenceOrbState extends State<PresenceOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(seconds: 8));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PresenceOrb old) {
    super.didUpdateWidget(old);
    if (old.thinking != widget.thinking) _sync();
  }

  void _sync() {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.stop();
      return;
    }
    _c.duration = widget.thinking ? const Duration(milliseconds: 1600) : const Duration(seconds: 8);
    _c.repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) => CustomPaint(
            size: Size.square(widget.size),
            painter: _OrbPainter(widget.theme, _c.value, widget.thinking),
          ),
        ),
      );
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.theme, this.t, this.thinking);
  final SunonoTheme theme;
  final double t;
  final bool thinking;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    final a = t * 2 * math.pi;
    final pulse = thinking ? 1 + 0.06 * math.sin(a * 2) : 1.0;

    // Halo.
    canvas.drawCircle(
      c,
      r * pulse,
      Paint()
        ..shader = RadialGradient(colors: [
          theme.primary.withValues(alpha: 0.35),
          theme.primary.withValues(alpha: 0),
        ]).createShader(Rect.fromCircle(center: c, radius: r)),
    );

    // Body, clipped to a circle, with three drifting color blobs.
    final body = r * 0.72 * pulse;
    canvas.save();
    canvas.clipPath(Path()..addOval(Rect.fromCircle(center: c, radius: body)));
    canvas.drawCircle(c, body, Paint()..color = theme.primary);
    final blobs = [
      (theme.accent, 0.0, 0.55),
      (Color.lerp(theme.primary, Colors.white, 0.35)!, 2.1, 0.5),
      (Color.lerp(theme.accent, theme.primary, 0.5)!, 4.2, 0.6),
    ];
    for (final (color, phase, scale) in blobs) {
      final o = c + Offset(math.cos(a + phase), math.sin(a * 1.3 + phase)) * body * 0.45;
      canvas.drawCircle(
        o,
        body * scale,
        Paint()
          ..shader = RadialGradient(colors: [color.withValues(alpha: 0.9), color.withValues(alpha: 0)])
              .createShader(Rect.fromCircle(center: o, radius: body * scale)),
      );
    }
    // Glassy highlight.
    final h = c + Offset(-body * 0.3, -body * 0.35);
    canvas.drawCircle(
      h,
      body * 0.45,
      Paint()
        ..shader = RadialGradient(colors: [Colors.white.withValues(alpha: 0.55), Colors.white.withValues(alpha: 0)])
            .createShader(Rect.fromCircle(center: h, radius: body * 0.45)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.t != t || old.thinking != thinking || old.theme != theme;
}
