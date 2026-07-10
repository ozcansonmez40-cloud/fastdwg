import 'package:flutter/services.dart';

import '../data/models/recent_file.dart';

typedef IncomingDrawingCallback = Future<void> Function(RecentFile file);

class IncomingDrawingService {
  IncomingDrawingService() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static const MethodChannel _channel = MethodChannel('fastdwg/dwg_renderer');

  IncomingDrawingCallback? onDrawingReceived;

  Future<RecentFile?> getInitialDrawing() async {
    try {
      final payload = await _channel.invokeMapMethod<String, dynamic>(
        'getInitialDrawing',
      );
      return _fileFromPayload(payload);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (call.method != 'drawingIntentReceived') return;
    final payload = Map<String, dynamic>.from(call.arguments as Map);
    final file = _fileFromPayload(payload);
    final callback = onDrawingReceived;
    if (file != null && callback != null) await callback(file);
  }

  RecentFile? _fileFromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final uri = payload['uri'] as String?;
    if (uri == null || uri.isEmpty) return null;

    return RecentFile(
      id: uri,
      name: payload['name'] as String? ?? 'drawing.dwg',
      uri: uri,
      fileExtension: payload['fileExtension'] as String? ?? 'dwg',
      lastOpenedAt: DateTime.now(),
      fileSizeBytes: (payload['fileSizeBytes'] as num?)?.toInt(),
    );
  }
}
