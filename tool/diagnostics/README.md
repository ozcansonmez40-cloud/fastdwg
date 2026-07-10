# Render diagnostics (not tests)

These files dump a region of a parsed scene to a PNG for visual comparison
against AutoCAD — they assert nothing. They were used to debug the tatilköyü
drawing (meeting-table fill blob, mirrored armchairs, corridor phantoms).

They read `tool/last_scene.bin` (pull it from the device with
`adb pull /data/data/com.example.dwgfast/files/scene_<key>.bin tool/last_scene.bin`)
and write `tool/*.png`.

Run one explicitly when needed:

```sh
flutter test tool/diagnostics/corridor_test.dart
```

They live outside `test/` so a plain `flutter test` stays side-effect-free.
