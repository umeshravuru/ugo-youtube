import 'dart:async';

import 'package:flutter/services.dart';

/// Receives text shared to the app from Android's share sheet.
///
/// `MainActivity.kt` pushes warm shares via `onShared` and holds the
/// cold-start share until [init] pulls it with `getInitialShared`.
class ShareHandler {
  static const MethodChannel _channel = MethodChannel('ugoyt/share');

  final StreamController<String> _controller = StreamController.broadcast();

  Stream<String> get shared => _controller.stream;

  Future<void> init() async {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onShared' && call.arguments is String) {
        _controller.add(call.arguments as String);
      }
    });
    try {
      final initial = await _channel.invokeMethod<String>('getInitialShared');
      if (initial != null) _controller.add(initial);
    } on PlatformException {
      // No native side (e.g. tests) — ignore.
    } on MissingPluginException {
      // ignore.
    }
  }
}
