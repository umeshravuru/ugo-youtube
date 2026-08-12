import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugo_yt/services/segmented_downloader.dart';

/// Local HTTP server that mimics googlevideo's `range=a-b` query-param
/// behavior, with scriptable stalls and URL expiry.
class FakeVideoServer {
  FakeVideoServer(this.data);

  final Uint8List data;
  late HttpServer _server;

  /// Byte offsets at which the server will stall (send half the requested
  /// window, then hang) — once each.
  final Set<int> stallAtOffsets = {};

  /// Stall on every request (half the window, then silence).
  bool stallAlways = false;

  /// If set, requests without `key=fresh` get 403 (simulates expired URL).
  bool requireFreshKey = false;

  int requestCount = 0;
  final List<String> rangesSeen = [];

  Future<Uri> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_handle);
    return Uri.parse('http://127.0.0.1:${_server.port}/videoplayback?id=test');
  }

  Future<void> _handle(HttpRequest req) async {
    requestCount++;
    final range = req.uri.queryParameters['range'];
    if (requireFreshKey && req.uri.queryParameters['key'] != 'fresh') {
      req.response.statusCode = 403;
      await req.response.close();
      return;
    }
    var from = 0;
    var to = data.length - 1;
    if (range != null) {
      rangesSeen.add(range);
      final parts = range.split('-');
      from = int.parse(parts[0]);
      to = int.parse(parts[1]);
    }
    final window = data.sublist(from, to + 1);
    req.response.statusCode = 200;
    req.response.headers.contentLength = window.length;

    if (stallAlways || stallAtOffsets.remove(from)) {
      // Send half the window, then go silent (simulates googlevideo stall).
      req.response.add(window.sublist(0, window.length ~/ 2));
      await req.response.flush();
      return; // never close — client's watchdog must fire
    }
    req.response.add(window);
    await req.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

Uint8List patternBytes(int n) =>
    Uint8List.fromList(List.generate(n, (i) => i % 251));

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ugo_seg');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  SegmentedDownloader fastDownloader() => SegmentedDownloader(
        segmentSize: 64 * 1024,
        connectTimeout: const Duration(seconds: 5),
        inactivityTimeout: const Duration(milliseconds: 400),
        maxAttemptsPerSegment: 3,
        retryDelay: const Duration(milliseconds: 50),
      );

  test('downloads in segments and reassembles bytes exactly', () async {
    final data = patternBytes(200 * 1024 + 17);
    final server = FakeVideoServer(data);
    final url = await server.start();
    final target = File('${tempDir.path}/out.bin');

    var reported = 0;
    await fastDownloader().download(
      url: url,
      totalBytes: data.length,
      target: target,
      onChunk: (n) => reported += n,
    );

    expect(await target.length(), data.length);
    expect(await target.readAsBytes(), data);
    expect(reported, data.length);
    expect(server.rangesSeen.first, '0-${64 * 1024 - 1}');
    expect(server.rangesSeen.length, 4); // ceil(200K+17 / 64K)
    await server.stop();
  });

  test('recovers from a mid-segment stall and resumes from last byte',
      () async {
    final data = patternBytes(160 * 1024);
    final server = FakeVideoServer(data)
      ..stallAtOffsets.add(64 * 1024); // second segment stalls once
    final url = await server.start();
    final target = File('${tempDir.path}/out.bin');

    await fastDownloader().download(
      url: url,
      totalBytes: data.length,
      target: target,
      onChunk: (_) {},
    );

    expect(await target.readAsBytes(), data);
    // Retry resumed mid-window (from 64K + 32K), not from scratch.
    expect(server.rangesSeen, contains('${96 * 1024}-${128 * 1024 - 1}'));
    await server.stop();
  });

  test('refreshes expired URL via callback', () async {
    final data = patternBytes(96 * 1024);
    final server = FakeVideoServer(data)..requireFreshKey = true;
    final url = await server.start();
    final target = File('${tempDir.path}/out.bin');

    var refreshed = 0;
    await fastDownloader().download(
      url: url, // stale: no key=fresh → 403
      totalBytes: data.length,
      target: target,
      onChunk: (_) {},
      refreshUrl: () async {
        refreshed++;
        return url.replace(
            queryParameters: {...url.queryParameters, 'key': 'fresh'});
      },
    );

    expect(refreshed, 1);
    expect(await target.readAsBytes(), data);
    await server.stop();
  });

  test('cancellation aborts promptly', () async {
    final data = patternBytes(256 * 1024);
    final server = FakeVideoServer(data);
    final url = await server.start();
    final target = File('${tempDir.path}/out.bin');

    var cancelled = false;
    var got = 0;
    await expectLater(
      fastDownloader().download(
        url: url,
        totalBytes: data.length,
        target: target,
        onChunk: (n) {
          got += n;
          if (got >= 64 * 1024) cancelled = true; // cancel after 1st segment
        },
        isCancelled: () => cancelled,
      ),
      throwsA(isA<DownloadCancelled>()),
    );
    await server.stop();
  });

  test('escapes a per-URL stall by refreshing the URL', () async {
    final data = patternBytes(128 * 1024);
    final server = FakeVideoServer(data);
    final url = await server.start();
    final target = File('${tempDir.path}/out.bin');

    // Every request WITHOUT key=fresh stalls; fresh URLs behave.
    server.stallAlways = true;
    var refreshes = 0;

    final downloader = SegmentedDownloader(
      segmentSize: 64 * 1024,
      connectTimeout: const Duration(seconds: 5),
      inactivityTimeout: const Duration(milliseconds: 300),
      maxAttemptsPerSegment: 4,
      retryDelay: const Duration(milliseconds: 20),
    );

    await downloader.download(
      url: url,
      totalBytes: data.length,
      target: target,
      onChunk: (_) {},
      refreshUrl: () async {
        refreshes++;
        server.stallAlways = false; // fresh URL → healthy server
        return url.replace(
            queryParameters: {...url.queryParameters, 'key': 'fresh$refreshes'});
      },
    );

    expect(refreshes, greaterThanOrEqualTo(1));
    expect(await target.readAsBytes(), data);
    await server.stop();
  });

  test('gives up after exhausting attempts on a perpetually stalling server',
      () async {
    final data = patternBytes(32 * 1024);
    final server = FakeVideoServer(data)..stallAlways = true;
    final url = await server.start();
    final target = File('${tempDir.path}/out.bin');

    final downloader = SegmentedDownloader(
      segmentSize: 64 * 1024,
      connectTimeout: const Duration(seconds: 5),
      inactivityTimeout: const Duration(milliseconds: 200),
      maxAttemptsPerSegment: 2,
      retryDelay: const Duration(milliseconds: 20),
    );

    await expectLater(
      downloader.download(
        url: url,
        totalBytes: data.length,
        target: target,
        onChunk: (_) {},
      ),
      throwsA(anyOf(isA<TimeoutException>(), isA<HttpException>())),
    );
    await server.stop();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
