// Render fill#351 (stairwell wall, 24 loops) with even-odd vs nonzero winding.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dwgfast/data/models/dwg_scene.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('winding compare', () async {
    final scene =
        DwgScene.fromBytes(File('tool/last_scene.bin').readAsBytesSync());
    for (final fi in [351, 1013]) {
      final f = scene.fills[fi];
      double x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
      for (final l in f.loops) {
        for (var i = 0; i + 1 < l.length; i += 2) {
          if (l[i] < x0) x0 = l[i];
          if (l[i] > x1) x1 = l[i];
          if (l[i + 1] < y0) y0 = l[i + 1];
          if (l[i + 1] > y1) y1 = l[i + 1];
        }
      }
      const w = 700, h = 500;
      final s = ((w / (x1 - x0)) < (h / (y1 - y0))
              ? (w / (x1 - x0))
              : (h / (y1 - y0))) *
          0.9;
      for (final rule in [PathFillType.evenOdd, PathFillType.nonZero]) {
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        c.drawRect(const Rect.fromLTWH(0, 0, w * 1.0, h * 1.0),
            Paint()..color = const Color(0xFF000000));
        final path = Path()..fillType = rule;
        for (final l in f.loops) {
          if (l.length < 6) continue;
          path.moveTo((l[0] - x0) * s, h - (l[1] - y0) * s);
          for (var i = 2; i + 1 < l.length; i += 2) {
            path.lineTo((l[i] - x0) * s, h - (l[i + 1] - y0) * s);
          }
          path.close();
        }
        c.drawPath(path, Paint()..color = const Color(0xFFFF0000));
        final img = await rec.endRecording().toImage(w, h);
        final d = await img.toByteData(format: ui.ImageByteFormat.png);
        final tag = rule == PathFillType.evenOdd ? 'eo' : 'nz';
        File('tool/wall_${fi}_$tag.png').writeAsBytesSync(d!.buffer.asUint8List());
      }
    }
    // ignore: avoid_print
    print('done');
  });
}
