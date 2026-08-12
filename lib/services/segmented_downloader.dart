import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Thrown when the caller's [isCancelled] callback reports a cancel.
class DownloadCancelled implements Exception {}

/// Thrown when the stream URL has expired (HTTP 403/410) and refreshing it
/// didn't help.
class UrlExpired implements Exception {
  @override
  String toString() => 'Stream URL expired';
}

/// Downloads a googlevideo stream in ranged segments with automatic retry
/// and byte-exact resume.
///
/// YouTube's servers routinely stall a long-running transfer (observed:
/// bytes stop flowing at a segment boundary and never resume). Requesting
/// the stream in bounded `range=a-b` windows and retrying just the stalled
/// window — resuming from the last received byte — makes downloads survive
/// that without restarting from zero.
class SegmentedDownloader {
  SegmentedDownloader({
    http.Client? client,
    this.segmentSize = 8 * 1024 * 1024,
    this.connectTimeout = const Duration(seconds: 20),
    this.inactivityTimeout = const Duration(seconds: 25),
    this.maxAttemptsPerSegment = 4,
    this.retryDelay = const Duration(seconds: 2),
    this.maxUrlRefreshes = 16,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int segmentSize;
  final Duration connectTimeout;
  final Duration inactivityTimeout;
  final int maxAttemptsPerSegment;
  final Duration retryDelay;

  /// googlevideo appears to throttle per-URL (a transfer stalls after
  /// ~30MB and never recovers on that URL). A freshly extracted URL resets
  /// that, so stalls trigger URL refreshes too — this caps them.
  final int maxUrlRefreshes;

  /// Fetches [totalBytes] from [url] into [target].
  ///
  /// [refreshUrl] is invoked when the URL is rejected (403/410) to obtain a
  /// fresh one; return null to give up. [isCancelled] is polled per chunk.
  Future<void> download({
    required Uri url,
    required int totalBytes,
    required File target,
    required void Function(int bytes) onChunk,
    Future<Uri?> Function()? refreshUrl,
    bool Function()? isCancelled,
  }) async {
    final sink = target.openWrite();
    var received = 0;
    var currentUrl = url;
    var refreshes = 0;

    Future<bool> tryRefreshUrl() async {
      if (refreshUrl == null || refreshes >= maxUrlRefreshes) return false;
      refreshes++;
      final fresh = await refreshUrl();
      if (fresh == null) return false;
      currentUrl = fresh;
      return true;
    }
    try {
      while (received < totalBytes) {
        if (isCancelled?.call() ?? false) throw DownloadCancelled();
        final segmentEnd = (received + segmentSize <= totalBytes)
            ? received + segmentSize - 1
            : totalBytes - 1;
        var attempt = 0;
        while (true) {
          attempt++;
          final before = received;
          try {
            // Progress advances per chunk (not on return) so a failed
            // attempt still counts its bytes and the retry resumes exactly
            // where the stream stalled — never double-writing.
            await _fetchRange(
              currentUrl,
              received,
              segmentEnd,
              sink,
              (bytes) {
                received += bytes;
                onChunk(bytes);
              },
              isCancelled,
            );
            break; // segment complete
          } on DownloadCancelled {
            rethrow;
          } on UrlExpired {
            if (!await tryRefreshUrl()) rethrow;
            attempt--; // refresh doesn't consume an attempt
          } catch (_) {
            // Progress made this attempt still counts; resume from `received`.
            final progressed = received > before;
            if (attempt >= maxAttemptsPerSegment && !progressed) rethrow;
            if (attempt >= maxAttemptsPerSegment * 2) rethrow;
            // A stalled URL tends to stay stalled — swap it mid-budget.
            if (attempt >= 2) await tryRefreshUrl();
            await Future<void>.delayed(retryDelay);
          }
        }
      }
      await sink.flush();
    } finally {
      // Fire-and-forget: file teardown must never block the caller.
      unawaited(sink.close().catchError((_) {}));
    }
  }

  /// Streams bytes [from]..[to] (inclusive) of [url] into [sink],
  /// reporting every written chunk through [onData].
  /// Completion is driven by our own completer + inactivity watchdog so a
  /// stalled response can never hang the caller.
  Future<void> _fetchRange(
    Uri url,
    int from,
    int to,
    IOSink sink,
    void Function(int bytes) onData,
    bool Function()? isCancelled,
  ) async {
    final ranged = url.replace(
      queryParameters: {
        ...url.queryParameters,
        'range': '$from-$to',
      },
    );
    final request = http.Request('GET', ranged);
    final response = await _client.send(request).timeout(connectTimeout);
    if (response.statusCode == 403 || response.statusCode == 410) {
      throw UrlExpired();
    }
    if (response.statusCode >= 400) {
      throw HttpException('HTTP ${response.statusCode}', uri: ranged);
    }

    final wanted = to - from + 1;
    var gotThisRequest = 0;
    final done = Completer<void>();
    Timer? watchdog;
    void armWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(inactivityTimeout, () {
        if (!done.isCompleted) {
          done.completeError(TimeoutException(
              'No data for ${inactivityTimeout.inSeconds}s'));
        }
      });
    }

    armWatchdog();
    final sub = response.stream.listen(
      (chunk) {
        if (done.isCompleted) return;
        if (isCancelled?.call() ?? false) {
          done.completeError(DownloadCancelled());
          return;
        }
        armWatchdog();
        // Never write more than the window we asked for (defensive: some
        // servers ignore range hints and stream the whole file).
        final remaining = wanted - gotThisRequest;
        final usable =
            chunk.length <= remaining ? chunk : chunk.sublist(0, remaining);
        sink.add(usable);
        gotThisRequest += usable.length;
        onData(usable.length);
        if (gotThisRequest >= wanted) done.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: () {
        if (!done.isCompleted) {
          if (gotThisRequest >= wanted) {
            done.complete();
          } else {
            done.completeError(const HttpException('Connection closed early'));
          }
        }
      },
      cancelOnError: true,
    );

    try {
      await done.future;
    } finally {
      watchdog?.cancel();
      unawaited(sub.cancel().catchError((_) {}));
    }
  }

  void close() {
    _client.close();
  }
}
