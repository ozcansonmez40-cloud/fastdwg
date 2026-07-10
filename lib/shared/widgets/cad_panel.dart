import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_radii.dart';

class CadPanel extends StatelessWidget {
  const CadPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = AppRadii.panel,
    this.accented = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool accented;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: padding,
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: accented ? AppColors.accentSecondary : AppColors.border,
        ),
        boxShadow: accented
            ? [
                BoxShadow(
                  color: AppColors.accentPrimary.withValues(alpha: 0.10),
                  blurRadius: 24,
                ),
              ]
            : null,
      ),
      child: child,
    );
  }
}
