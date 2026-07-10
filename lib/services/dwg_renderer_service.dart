import 'dart:io';

import 'package:flutter/services.dart';

import '../data/models/dwg_scene.dart';
import '../data/models/recent_file.dart';

/// Parses the packed scene buffer. Top-level so it can run on a background
/// isolate (via [compute]) — a dense drawing packs >1M segments and decoding
/// them on the UI isolate freezes the loading spinner for many seconds.
DwgScene _parseSceneBytes(Uint8List bytes) => DwgScene.fromBytes(bytes);

enum DwgRenderStatus { idle, loading, ready, unsupported, error }

class DwgRendererState {
  const DwgRendererState({
    required this.status,
    this.message,
    this.layers = const [],
    this.entityCount = 0,
    this.nativeProbe,
    this.scene,
  });

  final DwgRenderStatus status;
  final String? message;
  final List<String> layers;
  final int entityCount;
  final String? nativeProbe;
  final DwgScene? scene;
}

class DwgRendererService {
  static const MethodChannel _channel = MethodChannel('fastdwg/dwg_renderer');

  Future<DwgRendererState> prepare(RecentFile file) async {
    try {
      // No timeout here on purpose: large drawings (100 MB+) legitimately take
      // a while to decode, and a timeout would abort them. Parse failures are
      // handled by the scene==null guard below instead.
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'prepareDrawing',
        {'uri': file.uri, 'name': file.name},
      );

      final scene = await _readScene(result?['scenePath']);
      final status = result?['status'] as String?;
      // The native side said "ready" but we couldn't load a scene (decode threw
      // or ran out of memory). Surface an error rather than leaving the viewer
      // on an endless loading spinner.
      if (status == 'ready' && scene == null) {
        return DwgRendererState(
          status: DwgRenderStatus.error,
          message: '${file.name} could not be loaded — it may be too large for '
              'this device.',
          nativeProbe: result?['nativeProbe'] as String?,
        );
      }
      if (scene?.hasError == true) {
        final version = scene?.dwgVersion;
        return DwgRendererState(
          status: DwgRenderStatus.unsupported,
          message: version == null || version.isEmpty
              ? '${file.name} could not be decoded by the DWG engine.'
              : '${file.name} could not be decoded by the DWG engine ($version).',
          layers: scene?.layers.map((layer) => layer.name).toList() ??
              _readStringList(result?['layers']),
          entityCount: scene?.entityCount ?? result?['entityCount'] as int? ?? 0,
          nativeProbe: result?['nativeProbe'] as String?,
          scene: scene,
        );
      }
      if (status == 'ready') {
        return DwgRendererState(
          status: DwgRenderStatus.ready,
          message: result?['message'] as String?,
          layers: scene?.layers.map((layer) => layer.name).toList() ??
              _readStringList(result?['layers']),
          entityCount: scene?.entityCount ?? result?['entityCount'] as int? ?? 0,
          nativeProbe: result?['nativeProbe'] as String?,
          scene: scene,
        );
      }
      return DwgRendererState(
        status: DwgRenderStatus.unsupported,
        message: result?['message'] as String? ?? 'DWG format is not supported yet.',
        layers: scene?.layers.map((layer) => layer.name).toList() ??
            _readStringList(result?['layers']),
        entityCount: scene?.entityCount ?? result?['entityCount'] as int? ?? 0,
        nativeProbe: result?['nativeProbe'] as String?,
        scene: scene,
      );
    } on MissingPluginException {
      return const DwgRendererState(
        status: DwgRenderStatus.unsupported,
        message: 'Android DWG renderer plugin is not registered.',
      );
    } on PlatformException catch (error) {
      return DwgRendererState(
        status: DwgRenderStatus.error,
        message: error.message ?? 'Native DWG renderer failed.',
      );
    }
  }

  List<String> _readStringList(Object? value) {
    if (value is! List) return const [];
    return value.whereType<String>().toList(growable: false);
  }

  // The native side writes the packed scene to a file; reading it here keeps
  // the multi-MB payload off the platform channel (which used to OOM).
  Future<DwgScene?> _readScene(Object? path) async {
    if (path is! String || path.isEmpty) return null;
    try {
      final bytes = await File(path).readAsBytes();
      if (bytes.length < 8) return null;
      // Decode on the main isolate. We tried `compute` to keep the UI smooth,
      // but copying a 30 MB+ scene into a second isolate OOMs on low-end devices
      // (the decode just failed silently and the viewer hung). A brief freeze
      // while parsing is the lesser evil; the heavy lifting is the render, which
      // is batched (drawRawPoints) in the painter.
      return _parseSceneBytes(bytes);
    } catch (_) {
      // A malformed/oversized scene buffer (or a decode error) → null, which the
      // caller surfaces as a clean "couldn't open" screen rather than crashing.
      return null;
    }
  }
}
