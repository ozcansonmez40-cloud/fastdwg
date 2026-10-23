import 'dart:io';
import 'dart:typed_data';

/// Reads the preview image EMBEDDED in a DWG's header block — the thumbnail
/// AutoCAD saves with every drawing — without decoding the DWG at all.
///
/// The file header stores the preview block's address at offset 0x0D. The
/// block holds a 16-byte sentinel and a small directory of images: type 2 is
/// a BMP stored without its 14-byte BITMAPFILEHEADER, type 6 is a PNG
/// (R2013+). Extracting it costs a few KB of I/O, so the loading screen can
/// show the real drawing instantly while the native parser works.
class DwgPreviewService {
  /// Returns image bytes Flutter can decode directly (PNG as-is, BMP with a
  /// rebuilt file header), or null when the file carries no usable preview.
  static Future<Uint8List?> extract(String path) async {
    RandomAccessFile? raf;
    try {
      if (path.startsWith('content://')) return null;
      final p =
          path.startsWith('file://') ? Uri.parse(path).toFilePath() : path;
      final f = File(p);
      if (!f.existsSync()) return null;
      raf = await f.open();
      final len = await raf.length();
      if (len < 0x20) return null;
      final head = await raf.read(0x20);
      // "AC..." magic guards against non-DWG streams (DXF is plain text).
      if (head.length < 0x11 || head[0] != 0x41 || head[1] != 0x43) {
        return null;
      }
      final previewAddr = head[0x0D] |
          (head[0x0E] << 8) |
          (head[0x0F] << 16) |
          (head[0x10] << 24);
      if (previewAddr <= 0 || previewAddr + 21 > len) return null;

      // Skip the 16-byte sentinel; then u32 overall size + u8 image count.
      await raf.setPosition(previewAddr + 16);
      final dirHead = await raf.read(5);
      if (dirHead.length < 5) return null;
      final count = dirHead[4];
      if (count == 0 || count > 8) return null;
      final dir = await raf.read(count * 9);
      if (dir.length < count * 9) return null;
      final dbd = ByteData.sublistView(dir);

      for (var i = 0; i < count; i++) {
        final code = dir[i * 9]; // 1=header, 2=BMP, 3=WMF, 6=PNG
        final start = dbd.getUint32(i * 9 + 1, Endian.little);
        final size = dbd.getUint32(i * 9 + 5, Endian.little);
        if (size < 24 || size > (8 << 20) || start + size > len) continue;

        if (code == 6) {
          await raf.setPosition(start);
          return Uint8List.fromList(await raf.read(size));
        }
        if (code == 2) {
          // DIB without BITMAPFILEHEADER — rebuild the 14-byte header so
          // Flutter's BMP codec accepts it.
          await raf.setPosition(start);
          final dib = Uint8List.fromList(await raf.read(size));
          if (dib.length < 40) continue;
          final d = ByteData.sublistView(dib);
          final dibSize = d.getUint32(0, Endian.little);
          final bpp = d.getUint16(14, Endian.little);
          var clrUsed = d.getUint32(32, Endian.little);
          if (clrUsed == 0 && bpp <= 8) clrUsed = 1 << bpp;
          final out = Uint8List(14 + dib.length);
          final ob = ByteData.sublistView(out);
          out[0] = 0x42; // 'B'
          out[1] = 0x4D; // 'M'
          ob.setUint32(2, out.length, Endian.little);
          ob.setUint32(10, 14 + dibSize + clrUsed * 4, Endian.little);
          out.setAll(14, dib);
          return out;
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }
}
