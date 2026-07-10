import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class BlueprintBackground extends StatelessWidget {
  const BlueprintBackground({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BlueprintGridPainter(),
      child: child,
    );
  }
}

class _BlueprintGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final fine = Paint()
      ..color = AppColors.border.withValues(alpha: 0.20)
      ..strokeWidth = 0.6;
    final strong = Paint()
      ..color = AppColors.accentSecondary.withValues(alpha: 0.12)
      ..strokeWidth = 0.8;

    for (double x = 0; x < size.width; x += 18) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), fine);
    }
    for (double y = 0; y < size.height; y += 18) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), fine);
    }
    for (double x = 0; x < size.width; x += 90) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), strong);
    }
    for (double y = 0; y < size.height; y += 90) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), strong);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
