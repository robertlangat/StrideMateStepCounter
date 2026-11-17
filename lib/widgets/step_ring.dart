import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'common.dart';

/// Large progress ring with the step count in the middle. Scales with text size.
class StepRing extends StatelessWidget {
  const StepRing({super.key, required this.steps, required this.goal});
  final int steps;
  final int goal;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final progress = goal <= 0 ? 0.0 : steps / goal;
    final pct = (progress * 100).clamp(0, 999).round();
    return Semantics(
      label: '${fmtInt(steps)} steps today. Goal ${fmtInt(goal)}. $pct percent of goal.',
      excludeSemantics: true,
      child: LayoutBuilder(builder: (context, c) {
        final size = min(c.maxWidth, 300.0);
        return SizedBox(
          width: size,
          height: size,
          child: CustomPaint(
            painter: _RingPainter(
              progress: progress,
              track: cs.brightness == Brightness.dark ? SmColors.navyLight : SmColors.navy.withValues(alpha: 0.08),
              color: cs.brightness == Brightness.dark ? SmColors.mint : SmColors.mintDark,
              overflow: SmColors.amber,
            ),
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(size * 0.14),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(fmtInt(steps),
                        style: Theme.of(context).textTheme.displayMedium?.copyWith(fontWeight: FontWeight.w800)),
                    Text('of ${fmtInt(goal)} steps', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(progress >= 1 ? 'Goal reached! 🎉' : '$pct%',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.secondary)),
                  ]),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({required this.progress, required this.track, required this.color, required this.overflow});
  final double progress;
  final Color track;
  final Color color;
  final Color overflow;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, 2 * pi, false, base..color = track);
    final p = progress.clamp(0.0, 1.0);
    if (p > 0) canvas.drawArc(rect, -pi / 2, 2 * pi * p, false, base..color = color);
    if (progress > 1) {
      final extra = (progress - 1).clamp(0.0, 1.0);
      canvas.drawArc(rect, -pi / 2, 2 * pi * extra, false, base..color = overflow);
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.progress != progress || old.color != color || old.track != track;
}
