// Are the long "1m"-layer chords CLOSING segments (both endpoints coincide
// with other segments' endpoints in the same batch) or stray vertices?
//   dart run tool/chord_check.dart
import 'dart:io';
import 'package:dwgfast/data/models/dwg_scene.dart';

String q(double x, double y) => '${(x * 10).round()},${(y * 10).round()}';

void main() {
  final bytes = File('tool/last_scene.bin').readAsBytesSync();
  final scene = DwgScene.fromBytes(bytes);
  var layer1m = -1;
  for (var i = 0; i < scene.layers.length; i++) {
    if (scene.layers[i].name == '1m') layer1m = i;
  }
  print('layer 1m index=$layer1m');

  var chords = 0, bothShared = 0, oneShared = 0, noneShared = 0;
  var adjacentPrev = 0; // chord start == previous segment's end (in stream order)
  scene.lineBatches.forEach((key, v) {
    if (DwgScene.batchLayer(key) != layer1m) return;
    // endpoint multiset for this batch
    final count = <String, int>{};
    for (var i = 0; i + 3 < v.length; i += 4) {
      count[q(v[i], v[i + 1])] = (count[q(v[i], v[i + 1])] ?? 0) + 1;
      count[q(v[i + 2], v[i + 3])] = (count[q(v[i + 2], v[i + 3])] ?? 0) + 1;
    }
    for (var i = 0; i + 3 < v.length; i += 4) {
      final dx = v[i + 2] - v[i], dy = v[i + 3] - v[i + 1];
      final len2 = dx * dx + dy * dy;
      if (len2 < 10000 * 10000 || len2 > 400000.0 * 400000.0) continue;
      chords++;
      final aShared = (count[q(v[i], v[i + 1])] ?? 0) > 1;
      final bShared = (count[q(v[i + 2], v[i + 3])] ?? 0) > 1;
      if (aShared && bShared) {
        bothShared++;
      } else if (aShared || bShared) {
        oneShared++;
      } else {
        noneShared++;
      }
      if (i >= 4 &&
          q(v[i], v[i + 1]) == q(v[i - 2], v[i - 1])) {
        adjacentPrev++;
      }
    }
  });
  print('chords=$chords bothEndpointsShared=$bothShared oneShared=$oneShared '
      'noneShared=$noneShared chordContinuesPrevSegment=$adjacentPrev');
}
