import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:dwgfast/app.dart';
import 'package:dwgfast/data/repositories/recent_files_repository.dart';
import 'package:dwgfast/data/repositories/settings_repository.dart';
import 'package:dwgfast/features/app/app_controller.dart';
import 'package:dwgfast/services/dwg_renderer_service.dart';
import 'package:dwgfast/services/file_picker_service.dart';
import 'package:dwgfast/services/incoming_drawing_service.dart';
import 'package:dwgfast/services/sample_drawing_service.dart';
import 'package:dwgfast/services/thumbnail_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('FastDWG dashboard renders', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => AppController(
          recentFilesRepository: RecentFilesRepository(preferences),
          settingsRepository: SettingsRepository(preferences),
          filePickerService: FilePickerService(),
          dwgRendererService: DwgRendererService(),
          incomingDrawingService: IncomingDrawingService(),
          thumbnailService: ThumbnailService(),
          sampleDrawingService: SampleDrawingService(preferences),
        )..load(),
        child: const FastDwgApp(),
      ),
    );
    // Ride out the splash screen (1800 ms timer + 350 ms transition) and let
    // the async AppController.load() finish so the dashboard is showing.
    await tester.pump(const Duration(milliseconds: 1900));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('FastDWG'), findsOneWidget);
    expect(find.text('Recent Drawings'), findsOneWidget);
    expect(find.text('Search drawings'), findsOneWidget);
  });
}
