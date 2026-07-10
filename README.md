# FastDWG

FastDWG is an Android-first Flutter DWG viewer project with a premium CAD-style mobile interface.

The app is designed to be local-first, lightweight, and privacy-oriented. The current codebase includes:

- dark blueprint-style dashboard
- Android system file picker flow
- local recent drawings storage
- viewer screen shell
- settings screen
- native MethodChannel hook for a future DWG engine
- LibreDWG integration plan

## DWG Engine Direction

FastDWG is prepared to use a native Android DWG parsing bridge. The planned low-cost/open-source path is LibreDWG.

Current bridge files:

- `lib/services/dwg_renderer_service.dart`
- `android/app/src/main/kotlin/com/example/dwgfast/MainActivity.kt`
- `docs/libredwg_integration.md`

## License Direction

If LibreDWG is bundled in the distributed Android app, FastDWG should be released with compatible open-source terms and corresponding source availability.

Never publish private release signing files or store credentials in the repository.

Keep private:

- release keystore
- `key.properties`
- Play Console credentials
- ad network secrets
- payment provider secrets

## Manual Development Commands

```powershell
cd C:\Users\Acer\dwgfast
flutter pub get
flutter analyze
flutter run
```
