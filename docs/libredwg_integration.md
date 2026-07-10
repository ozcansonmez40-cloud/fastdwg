# LibreDWG Integration Plan

FastDWG is moving toward an open-source compatible DWG engine path using LibreDWG.

## Goal

Open a `.dwg` file directly inside FastDWG without asking the user to convert it first.

## Architecture

```text
Flutter viewer
  -> DwgRendererService
  -> MethodChannel: fastdwg/dwg_renderer
  -> Android Kotlin bridge
  -> JNI / NDK module
  -> LibreDWG C library
  -> normalized geometry DTOs
  -> Flutter CustomPainter viewport
```

## First Native Milestone

Parse a selected DWG file and return:

- drawing bounds
- layer names
- line entities
- polyline entities
- circle entities
- arc entities

Text, hatches, dimensions, blocks, external references, and advanced AutoCAD objects can come later.

## License Direction

LibreDWG is GPL licensed. FastDWG should be prepared as an open-source app if LibreDWG is distributed inside the APK/AAB.

Do not publish private signing files or store credentials in the repository.

Keep private:

- release keystore files
- key.properties
- Play Console credentials
- ad network secrets
- payment provider secrets
- user data

Publish:

- Flutter source
- Android source
- native bridge source
- LibreDWG source/build instructions
- license notices
- build instructions

## Current Project Status

The Flutter side already calls a native MethodChannel in:

- `lib/services/dwg_renderer_service.dart`

The Android stub is registered in:

- `android/app/src/main/kotlin/com/example/dwgfast/MainActivity.kt`
- `android/app/src/main/kotlin/com/example/dwgfast/NativeDwgBridge.kt`
- `android/app/src/main/cpp/CMakeLists.txt`
- `android/app/src/main/cpp/fastdwg_native.cpp`

The next step is adding the native C/JNI module and LibreDWG build artifacts.

## Next Implementation Step

Add LibreDWG as a native dependency. Preferred development flow:

1. Build LibreDWG for Android ABIs with the Android NDK.
2. Place or reference the built native library in `third_party/libredwg/android/libs`.
3. Include LibreDWG headers from `fastdwg_native.cpp`.
4. Replace the placeholder `nativePrepareDrawing` implementation with real parsing.
5. Convert parsed entities into stable DTOs before sending them to Flutter.

Keep this first pass small: return only layers and simple 2D primitives before supporting text, dimensions, blocks, hatches, and xrefs.

## Expected Local Native Layout

The CMake file auto-detects LibreDWG only when this layout exists:

```text
third_party/libredwg/android/
  include/
    dwg.h
    dwg_api.h
    ...
  libs/
    arm64-v8a/
      libredwg.so
    armeabi-v7a/
      libredwg.so
    x86_64/
      libredwg.so
```

If `dwg.h` and the matching ABI `.so` are present, the Android native build defines `FASTDWG_WITH_LIBREDWG` and links `libredwg.so`.

## Scene JSON Contract

The native bridge should return `sceneJson` in this shape:

```json
{
  "bounds": { "minX": 0, "minY": 0, "maxX": 100, "maxY": 100 },
  "layers": [
    { "name": "0", "visible": true },
    { "name": "Walls", "visible": true }
  ],
  "lines": [
    { "x1": 0, "y1": 0, "x2": 100, "y2": 0, "layer": "Walls" }
  ],
  "circles": [
    { "cx": 50, "cy": 50, "radius": 12, "layer": "0" }
  ]
}
```

Flutter consumes this in:

- `lib/data/models/dwg_scene.dart`
- `lib/shared/widgets/dwg_viewport.dart`

## Android File Access

The Android system picker can return `content://` URIs. C/C++ cannot read those directly. FastDWG now copies the selected URI into the app cache in Kotlin, then passes the local file path to JNI.

Relevant file:

- `android/app/src/main/kotlin/com/example/dwgfast/NativeDwgBridge.kt`

## Sources Checked

- GNU LibreDWG describes the project as a C library for DWG files and GPLv3+ licensed: https://www.gnu.org/software/libredwg/
- GNU LibreDWG manual documents the current API/manual version and decoding functions: https://www.gnu.org/software/libredwg/manual/
- Android NDK supports CMake-based native builds: https://developer.android.com/ndk/guides/build
