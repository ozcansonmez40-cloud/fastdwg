import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/constants/app_constants.dart';
import 'features/app/app_controller.dart';
import 'features/splash/splash_screen.dart';
import 'theme/app_theme.dart';

class FastDwgApp extends StatelessWidget {
  const FastDwgApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeMode = context.select<AppController, ThemeMode>(
      (controller) => controller.settings.themeMode,
    );

    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      themeMode: themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const SplashScreen(),
    );
  }
}
