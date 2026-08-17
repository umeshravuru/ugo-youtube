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

  /// Lock-screen / headset media actions arriving from the native
  /// MediaSession: 'play' | 'pause' | 'playPause'.
  static void Function(String action)? onMediaAction;

  /// Lock-screen seek-bar drags.
  static void Function(Duration position)? onMediaSeek;

  static bool _mediaHandlerInstalled = false;

  static void ensureMediaHandler() {
    if (_mediaHandlerInstalled) return;
    _mediaHandlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'mediaAction':
          if (call.arguments is String) {
            onMediaAction?.call(call.arguments as String);
          }
        case 'mediaSeek':
          if (call.arguments is num) {
            onMediaSeek?.call(
                Duration(milliseconds: (call.arguments as num).toInt()));
          }
      }
    });
  }

  /// Media-playback foreground service: keeps audio alive when the app is
  /// minimized and drives the lock-screen media card. Starts the service if
  /// needed, then applies the given state.
  static Future<void> updatePlayback({
    required String title,
    required bool isPlaying,
    int positionMs = 0,
    int durationMs = 0,
    String? thumbPath,
  }) async {
    try {
      await _channel.invokeMethod('updatePlayback', {
        'title': title,
        'isPlaying': isPlaying,
        'positionMs': positionMs,
        'durationMs': durationMs,
        'thumbPath': thumbPath,
      }).timeout(_callTimeout);
    } catch (_) {}
  }

  static Future<void> stopPlayback() async {
    try {
      await _channel.invokeMethod('stopPlayback').timeout(_callTimeout);
    } catch (_) {}
  }
}
