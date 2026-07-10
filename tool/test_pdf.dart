// Offline reproduction of the export PDF, for diagnosing quality. Run with:
//   dart run tool/test_pdf.dart
// Parses tool/last_scene.bin with the real DwgScene parser and renders the same
// vector PDF the app produces, to tool/out.pdf. Inline white-paper colour map
// (no dart:ui needed).
import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:vector_math/vector_math_64.dart' show Matrix4;

import 'package:dwgfast/data/models/dwg_scene.dart';

const double pdfMaxSide = 8000.0;
const double pdfMargin = 24.0;

PdfColor mapColor(int? raw) {
  final rgb = (raw ?? 0x9AD0E0) & 0xFFFFFF;
  if (rgb == 0xFFFFFF) return PdfColor.fromInt(0xFF000000); // white→black on paper
  return PdfColor.fromInt(0xFF000000 | rgb);
}

Future<void> main() async {
  final bytes = File('tool/last_scene.bin').readAsBytesSync();
  final scene = DwgScene.fromBytes(bytes);
  final region = scene.drawableBounds;
  print('lines=${scene.lineSegmentCount} circles=${scene.circleCount} '
      'texts=${scene.texts.length} fills=${scene.fills.length}');
  print('bounds: ${region.minX},${region.minY} .. ${region.maxX},${region.maxY} '
      '(${region.width} x ${region.height})');

  final fontBytes = File('assets/fonts/Roboto-Regular.ttf').readAsBytesSync();

  final rw = region.width, rh = region.height;
  final double pageW, pageH;
  if (rw >= rh) {
    pageW = pdfMaxSide;
    pageH = (pdfMaxSide * rh / rw).clamp(1.0, pdfMaxSide);
  } else {
    pageH = pdfMaxSide;
    pageW = (pdfMaxSide * rw / rh).clamp(1.0, pdfMaxSide);
  }
  print('page: $pageW x $pageH pt');

  final pdf = PdfDocument();
  final page = PdfPage(pdf, pageFormat: PdfPageFormat(pageW, pageH));
  final g = page.getGraphics();
  final font = PdfTtfFont(pdf, ByteData.sublistView(fontBytes));

  final availW = pageW - 2 * pdfMargin, availH = pageH - 2 * pdfMargin;
  final scale = (availW / rw < availH / rh) ? availW / rw : availH / rh;
  final ox = pdfMargin + (availW - rw * scale) / 2 - region.minX * scale;
  final oy = pdfMargin + (availH - rh * scale) / 2 - region.minY * scale;
  double tx(double x) => x * scale + ox;
  double ty(double y) => y * scale + oy;
  print('scale=$scale lineWidth=${(pdfMaxSide / 2400).clamp(0.3, 1.2)}');

  g.setLineWidth((pdfMaxSide / 2400).clamp(0.3, 1.2));

  for (final fill in scene.fills) {
    var any = false;
    for (final loop in fill.loops) {
      if (loop.length < 6) continue;
      g.moveTo(tx(loop[0]), ty(loop[1]));
      for (var i = 2; i + 1 < loop.length; i += 2) {
        g.lineTo(tx(loop[i]), ty(loop[i + 1]));
      }
      any = true;
    }
    if (!any) continue;
    g.setFillColor(mapColor(fill.color));
    g.fillPath(evenOdd: true);
  }

  scene.lineBatches.forEach((key, model) {
    var any = false;
    for (var i = 0; i + 3 < model.length; i += 4) {
      if (model[i] == model[i + 2] && model[i + 1] == model[i + 3]) continue;
      g.moveTo(tx(model[i]), ty(model[i + 1]));
      g.lineTo(tx(model[i + 2]), ty(model[i + 3]));
      any = true;
    }
    if (!any) return;
    g.setStrokeColor(mapColor(DwgScene.batchColor(key)));
    g.strokePath();
  });

  final cc = scene.circleCoords;
  for (var i = 0; i < scene.circleCount; i++) {
    final r = cc[i * 3 + 2] * scale;
    if (r < 0.2) continue;
    g.setStrokeColor(mapColor(scene.circleColors[i]));
    g.drawEllipse(tx(cc[i * 3]), ty(cc[i * 3 + 1]), r, r);
    g.strokePath();
  }

  var textDrawn = 0;
  for (final t in scene.texts) {
    final s = t.value.trim();
    if (s.isEmpty) continue;
    final size = t.height * scale;
    if (size < 1.5) continue;
    final m = font.stringMetrics(s);
    final w = m.width * size, asc = m.ascent * size, desc = m.descent * size;
    final halign = t.anchor & 0x0F, valign = (t.anchor >> 4) & 0x0F;
    final adx = halign == 1 ? -w / 2 : (halign == 2 ? -w : 0.0);
    final ady = switch (valign) { 1 => -desc, 2 => -(asc + desc) / 2, 3 => -asc, _ => 0.0 };
    g.setFillColor(mapColor(t.color));
    if (t.rotation != 0) {
      g.saveContext();
      g.setTransform(Matrix4.translationValues(tx(t.x), ty(t.y), 0)..rotateZ(t.rotation));
      g.drawString(font, size, s, adx, ady);
      g.restoreContext();
    } else {
      g.drawString(font, size, s, tx(t.x) + adx, ty(t.y) + ady);
    }
    textDrawn++;
  }
  print('text drawn (size>=1.5pt): $textDrawn');

  final out = await pdf.save();
  File('tool/out.pdf').writeAsBytesSync(out);
  print('wrote tool/out.pdf  ${out.length} bytes');
}
