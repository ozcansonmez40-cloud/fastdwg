import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'data/repositories/recent_files_repository.dart';
import 'data/repositories/settings_repository.dart';
import 'features/app/app_controller.dart';
import 'services/dwg_renderer_service.dart';
import 'services/file_picker_service.dart';
import 'services/incoming_drawing_service.dart';
import 'services/sample_drawing_service.dart';
import 'services/thumbnail_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final incomingDrawingService = IncomingDrawingService();

  runApp(
    ChangeNotifierProvider(
      create: (_) => AppController(
        recentFilesRepository: RecentFilesRepository(preferences),
        settingsRepository: SettingsRepository(preferences),
        filePickerService: FilePickerService(),
        dwgRendererService: DwgRendererService(),
        incomingDrawingService: incomingDrawingService,
        thumbnailService: ThumbnailService(),
        sampleDrawingService: SampleDrawingService(preferences),
      )..load(),
      child: const FastDwgApp(),
    ),
  );
}
