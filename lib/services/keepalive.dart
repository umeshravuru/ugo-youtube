import 'package:flutter/services.dart';

/// Controls the native foreground service (`DownloadService.kt`) that keeps
/// the process alive and unfrozen while downloads run, with a progress
/// notification. All calls are best-effort — failures never break downloads.
class KeepAlive {
  static const MethodChannel _channel = MethodChannel('ugoyt/keepalive');

  static const _callTimeout = Duration(seconds: 5);

  static Future<void> start(String text) async {
    try {
      await _channel
          .invokeMethod('start', {'text': text}).timeout(_callTimeout);
    } catch (_) {}
  }

  /// [progress] is 0–100, or -1 for indeterminate.
  static Future<void> update(String text, {int progress = -1}) async {
    try {
      await _channel.invokeMethod('update', {
        'text': text,
        'progress': progress,
      }).timeout(_callTimeout);
    } catch (_) {}
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod('stop').timeout(_callTimeout);
    } catch (_) {}
  }
}
