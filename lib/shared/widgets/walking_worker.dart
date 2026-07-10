import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A little cartoon construction worker — big head, yellow hard hat — walking
/// in place. Drawn entirely with [CustomPaint] (no image assets) and looped by
/// an [AnimationController]. Used as a friendly "loading" indicator.
class WalkingWorker extends StatefulWidget {
  const WalkingWorker({super.key, this.size = 96});

  final double size;

  @override
  State<WalkingWorker> createState() => _WalkingWorkerState();
}

class _WalkingWorkerState extends State<WalkingWorker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => CustomPaint(
          painter: _WorkerPainter(_c.value * 2 * math.pi),
        ),
      ),
    );
  }
}

class _WorkerPainter extends CustomPainter {
  _WorkerPainter(this.phase);

  /// Walk-cycle phase in radians [0, 2π).
  final double phase;

  static const _hat = Color(0xFFFFC400); // construction yellow
  static const _hatShade = Color(0xFFE0A800);
  static const _skin = Color(0xFFF6C9A0);
  static const _vest = Color(0xFFFF8A3D); // hi-vis orange
  static const _limb = Color(0xFF24506A); // dark blueprint blue
  static const _ink = Color(0xFF0B2030);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 100.0; // proportional scale
    final cx = size.width / 2;

    // Whole-body vertical bob: rises in the middle of each step (2 per cycle).
    final bob = -(math.sin(phase).abs()) * 3.0 * s;
    canvas.save();
    canvas.translate(0, bob);

    final hipY = size.height * 0.60;
    final shoulderY = size.height * 0.42;
    final headCy = size.height * 0.25;
    final headR = 22.0 * s; // big cartoon head
    final legLen = size.height * 0.30;
    final armLen = size.height * 0.22;

    final limbPaint = Paint()
      ..color = _limb
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.5 * s
      ..strokeCap = StrokeCap.round;

    // ── Legs (swing opposite each other) ──
    final legA = math.sin(phase) * 0.5;
    Offset foot(double a) =>
        Offset(cx + math.sin(a) * legLen, hipY + math.cos(a) * legLen);
    final footL = foot(legA);
    final footR = foot(-legA);
    canvas.drawLine(Offset(cx, hipY), footL, limbPaint);
    canvas.drawLine(Offset(cx, hipY), footR, limbPaint);
    // Boots
    final boot = Paint()..color = _ink;
    for (final f in [footL, footR]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(f.dx - 3 * s, f.dy - 2 * s, 11 * s, 5 * s),
          Radius.circular(2.5 * s),
        ),
        boot,
      );
    }

    // ── Arms (opposite phase to the legs) ──
    final armA = math.sin(phase + math.pi) * 0.55;
    Offset hand(double dir, double a) => Offset(
          cx + dir * 7 * s + math.sin(a) * armLen * dir.sign,
          shoulderY + math.cos(a) * armLen,
        );
    canvas.drawLine(
        Offset(cx - 7 * s, shoulderY), hand(-1, armA), limbPaint);
    canvas.drawLine(
        Offset(cx + 7 * s, shoulderY), hand(1, -armA), limbPaint);

    // ── Torso (hi-vis vest) ──
    final torso = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - 13 * s, shoulderY - 2 * s, 26 * s, hipY - shoulderY + 6 * s),
      Radius.circular(8 * s),
    );
    canvas.drawRRect(torso, Paint()..color = _vest);
    // Vest reflective stripe
    canvas.drawRect(
      Rect.fromLTWH(cx - 13 * s, shoulderY + 9 * s, 26 * s, 3.5 * s),
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );

    // ── Head ──
    canvas.drawCircle(Offset(cx, headCy), headR, Paint()..color = _skin);
    // Eyes
    final eye = Paint()..color = _ink;
    canvas.drawCircle(Offset(cx - 7 * s, headCy + 1.5 * s), 2.2 * s, eye);
    canvas.drawCircle(Offset(cx + 7 * s, headCy + 1.5 * s), 2.2 * s, eye);
    // Smile
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, headCy + 4 * s), radius: 6.5 * s),
      0.15 * math.pi,
      0.7 * math.pi,
      false,
      Paint()
        ..color = _ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * s
        ..strokeCap = StrokeCap.round,
    );

    // ── Hard hat (dome + brim + ridge) ──
    final hatTop = headCy - headR * 0.55;
    final domeRect = Rect.fromLTWH(
      cx - headR * 1.05,
      hatTop - headR * 0.75,
      headR * 2.1,
      headR * 1.7,
    );
    canvas.drawArc(domeRect, math.pi, math.pi, false, Paint()..color = _hat);
    // Brim
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - headR * 1.25, hatTop - 1.5 * s, headR * 2.5, 4.5 * s),
        Radius.circular(2.5 * s),
      ),
      Paint()..color = _hatShade,
    );
    // Top ridge
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - 2 * s, hatTop - headR * 0.7, 4 * s, headR * 0.6),
        Radius.circular(2 * s),
      ),
      Paint()..color = _hatShade,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WorkerPainter old) => old.phase != phase;
}
