# FastDWG

FastDWG is a fast, fully offline DWG/DXF viewer for Android, built with
Flutter and a native C++ parsing bridge.

- Opens modern DWG (AutoCAD 2013–2025) and DXF drawings
- Layer panel, real-unit measuring, drawing/markup tools
- Photo & note pins anchored to model-space points
- PDF export at real paper sizes (A4–A0) with true plot scales
- No account, no ads, no analytics, no internet permission

Google Play: **FastDWG: DWG Viewer & Reader** (`app.fastdwg.viewer`)

## License

The application bundles [GNU LibreDWG](https://www.gnu.org/software/libredwg/)
(GPL-3.0) for DWG/DXF parsing, so the distributed app is licensed as a whole
under the **GNU General Public License v3** — see [LICENSE](LICENSE). This
repository is the corresponding source for the released app.

Notes:

- `third_party/libredwg/` is GNU LibreDWG, © its respective authors, GPL-3.0.
- All other code is © Ozcan Sonmez. It is released here under GPL-3.0 because
  of the LibreDWG combination; the copyright holder reserves the right to
  license *future* versions of the application code differently (for example
  if a future release uses a commercially licensed DWG engine instead of
  LibreDWG). Versions already published under the GPL remain GPL.
- **Trademark:** "FastDWG", the app name, icon and store listing assets are
  not covered by the GPL and may not be used to publish derivative apps.

## Contributions

External contributions are **not accepted** — pull requests will be closed
without review. See [CONTRIBUTING.md](CONTRIBUTING.md). Forking under the GPL
is fine.

## Building

```powershell
flutter pub get
flutter build apk --release --split-per-abi   # or: flutter build appbundle
```

Release signing expects `android/key.properties` pointing at an upload
keystore; both live outside the repository and are never committed. Without
them, release builds fail loudly rather than shipping debug-signed.
