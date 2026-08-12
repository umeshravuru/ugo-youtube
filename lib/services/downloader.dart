import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../models/video_item.dart';
import '../util/url_parse.dart';
import 'keepalive.dart';
import 'library_store.dart';
import 'mux.dart';
import 'stream_pick.dart';

/// Thrown internally when the user cancels an in-flight download.
class _Cancelled implements Exception {}

/// Serial download queue: extract → download stream(s) → mux → finalize.
/// Runs in the main isolate; the native foreground service (via [KeepAlive])
/// keeps the process alive while the queue is non-empty.
///
/// Every network stage has a timeout and the byte stream has an inactivity
/// watchdog, so a black-holed connection (flaky network, TLS-inspecting VPN)
/// fails the item with a Retry instead of wedging the queue forever.
class DownloadManager {
  DownloadManager({required this.store, required this.mediaDir});

  static const _metaTimeout = Duration(seconds: 60);
  static const _manifestTimeout = Duration(seconds: 90);
  static const _streamInactivityTimeout = Duration(seconds: 60);
  static const _muxTimeout = Duration(minutes: 10);

  final LibraryStore store;
  final Directory mediaDir;

  /// UI hook for transient messages (snackbars).
  void Function(String message)? onMessage;

  final List<String> _queue = [];
  final Set<String> _cancelRequested = {};
  bool _running = false;
  final YoutubeExplode _yt = YoutubeExplode();

  /// Entry point for anything shared to the app (or pasted manually).
  Future<void> enqueueFromSharedText(String text) async {
    final id = extractYoutubeVideoId(text);
    if (id == null) {
      onMessage?.call('That doesn\'t look like a YouTube link');
      return;
    }
    _cancelRequested.remove(id); // stale flag from an earlier cancel
    final existing = store.byId(id);
    if (existing != null && existing.status == VideoStatus.done) {
      onMessage?.call('Already in your library');
      return;
    }
    if (existing != null && existing.status.isActive) {
      return; // already queued/downloading
    }
    if (existing != null) {
      // failed → reset for retry
      existing.status = VideoStatus.queued;
      existing.error = null;
      existing.progress = 0;
      store.upsert(existing);
    } else {
      store.upsert(VideoItem.queued(id));
    }
    _queue.add(id);
    unawaited(_pump());
  }

  Future<void> retry(String id) => enqueueFromSharedText(id);

  /// Cancel (if in flight) and remove an item, media files included.
  /// Safe to call for any status.
  Future<void> cancelAndRemove(String id) async {
    final item = store.byId(id);
    if (item != null && item.status.isActive) {
      _cancelRequested.add(id); // in-flight loops abort at next checkpoint
    }
    _queue.remove(id);
    await store.remove(id);
  }

  /// Remove leftover .part files from interrupted runs.
  Future<void> cleanupStrayParts() async {
    try {
      await for (final f in mediaDir.list()) {
        if (f is File && f.path.endsWith('.part')) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      await KeepAlive.start('Starting download…');
      while (_queue.isNotEmpty) {
        final id = _queue.removeAt(0);
        if (_cancelRequested.remove(id)) continue;
        final item = store.byId(id);
        if (item == null) continue;
        try {
          await _download(item);
        } on _Cancelled {
          _cancelRequested.remove(id);
          // Item was removed by cancelAndRemove; nothing to update.
        } catch (e) {
          _cancelRequested.remove(id);
          if (store.byId(id) == null) continue; // deleted while failing
          item.status = VideoStatus.failed;
          item.error = _friendlyError(e);
          store.upsert(item);
          onMessage?.call('Download failed: ${item.error}');
        }
      }
    } finally {
      _running = false;
      await KeepAlive.stop();
    }
  }

  void _checkpoint(String id) {
    if (_cancelRequested.contains(id)) throw _Cancelled();
  }

  Future<void> _download(VideoItem item) async {
    final id = VideoId(item.id);

    item.status = VideoStatus.fetching;
    store.upsert(item);

    final video = await _yt.videos.get(id).timeout(_metaTimeout);
    if (video.isLive) {
      throw const FormatException('Live streams are not supported');
    }
    _checkpoint(item.id);
    item.title = video.title;
    item.author = video.author;
    item.durationMs = video.duration?.inMilliseconds ?? 0;
    store.upsert(item);
    await KeepAlive.update(video.title);

    // Thumbnail is best-effort.
    final thumbFile = File('${mediaDir.path}/${item.id}.jpg');
    try {
      final resp = await http
          .get(Uri.parse(video.thumbnails.highResUrl))
          .timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        await thumbFile.writeAsBytes(resp.bodyBytes);
        item.thumbPath = thumbFile.path;
      }
    } catch (_) {}

    _checkpoint(item.id);
    final manifest =
        await _yt.videos.streamsClient.getManifest(id).timeout(_manifestTimeout);
    final pick = pickStreams(manifest);

    item.status = VideoStatus.downloading;
    item.progress = 0;
    store.upsert(item);

    File? result;
    if (pick.isAdaptive) {
      result = await _downloadAdaptive(item, pick);
    }
    _checkpoint(item.id);
    result ??= await _downloadMuxed(item, pick);
    if (result == null) {
      throw const FormatException('No downloadable streams found');
    }

    _checkpoint(item.id);
    item.filePath = result.path;
    item.sizeBytes = await result.length();
    item.status = VideoStatus.done;
    item.progress = 1;
    item.error = null;
    store.upsert(item);
    await store.enforceLimit();
    onMessage?.call('Saved: ${item.title}');
  }

  /// Download video+audio separately, then stream-copy mux into one file.
  /// Returns null on failure (caller falls back to pre-muxed).
  Future<File?> _downloadAdaptive(VideoItem item, StreamPick pick) async {
    final vPart = File('${mediaDir.path}/${item.id}.video.part');
    final aPart = File('${mediaDir.path}/${item.id}.audio.part');
    final out = File('${mediaDir.path}/${item.id}.${pick.extension}');
    try {
      final total = pick.totalBytes;
      var received = 0;
      void onChunk(int bytes) {
        received += bytes;
        _reportProgress(item, total == 0 ? 0 : received / total);
      }

      await _downloadStream(item.id, pick.video!, vPart, onChunk);
      await _downloadStream(item.id, pick.audio!, aPart, onChunk);

      item.status = VideoStatus.muxing;
      store.upsert(item);
      await KeepAlive.update('Merging: ${item.title}', progress: 100);

      final ok = await muxCopy(vPart.path, aPart.path, out.path)
          .timeout(_muxTimeout, onTimeout: () => false);
      if (!ok || !await out.exists() || await out.length() == 0) {
        try {
          if (await out.exists()) await out.delete();
        } catch (_) {}
        return null;
      }
      if (_cancelRequested.contains(item.id)) {
        try {
          await out.delete();
        } catch (_) {}
        throw _Cancelled();
      }
      return out;
    } on _Cancelled {
      rethrow;
    } catch (e) {
      return null;
    } finally {
      for (final f in [vPart, aPart]) {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<File?> _downloadMuxed(VideoItem item, StreamPick pick) async {
    final muxed = pick.muxed;
    if (muxed == null) return null;
    final ext = muxed.container.name == 'webm' ? 'webm' : 'mp4';
    final part = File('${mediaDir.path}/${item.id}.dl.part');
    final out = File('${mediaDir.path}/${item.id}.$ext');
    item.status = VideoStatus.downloading;
    store.upsert(item);
    try {
      final total = muxed.size.totalBytes;
      var received = 0;
      await _downloadStream(item.id, muxed, part, (bytes) {
        received += bytes;
        _reportProgress(item, total == 0 ? 0 : received / total);
      });
      return await part.rename(out.path);
    } finally {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }

  /// Explicit-subscription download loop. Completion is driven only by our
  /// own completer (done / error / cancel / inactivity watchdog), so a
  /// wedged source stream or slow library teardown can never block the
  /// queue — teardown is fire-and-forget.
  Future<void> _downloadStream(
    String itemId,
    StreamInfo info,
    File target,
    void Function(int bytes) onChunk,
  ) async {
    final sink = target.openWrite();
    final done = Completer<void>();
    Timer? watchdog;
    void armWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(_streamInactivityTimeout, () {
        if (!done.isCompleted) {
          done.completeError(
              TimeoutException('No data for ${_streamInactivityTimeout.inSeconds}s'));
        }
      });
    }

    armWatchdog();
    final sub = _yt.videos.streamsClient.get(info).listen(
      (chunk) {
        if (done.isCompleted) return;
        if (_cancelRequested.contains(itemId)) {
          done.completeError(_Cancelled());
          return;
        }
        armWatchdog();
        sink.add(chunk);
        onChunk(chunk.length);
      },
      onError: (Object e, StackTrace st) {
        if (!done.isCompleted) done.completeError(e, st);
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );

    try {
      await done.future;
      await sink.flush();
    } finally {
      watchdog?.cancel();
      // Never await these: library/file teardown must not wedge the queue.
      unawaited(sub.cancel().catchError((_) {}));
      unawaited(sink.close().catchError((_) {}));
    }
  }

  DateTime _lastUiUpdate = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastNotifUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  void _reportProgress(VideoItem item, double progress) {
    final now = DateTime.now();
    item.progress = progress.clamp(0.0, 1.0);
    if (now.difference(_lastUiUpdate).inMilliseconds >= 400) {
      _lastUiUpdate = now;
      store.updateExisting(item); // never re-inserts a just-cancelled item
    }
    if (now.difference(_lastNotifUpdate).inMilliseconds >= 1200) {
      _lastNotifUpdate = now;
      unawaited(KeepAlive.update(
        item.title.isEmpty ? 'Downloading…' : item.title,
        progress: (item.progress * 100).round(),
      ));
    }
  }

  String _friendlyError(Object e) {
    if (e is TimeoutException) {
      return 'Timed out — check connection (VPN?) and retry';
    }
    final s = e.toString();
    if (s.contains('CERTIFICATE_VERIFY_FAILED') ||
        s.contains('HandshakeException')) {
      return 'TLS blocked (corporate VPN/proxy?) — see README';
    }
    if (s.contains('VideoUnavailable') || s.contains('unavailable')) {
      return 'Video unavailable';
    }
    if (s.contains('RequiresLogin') || s.contains('age')) {
      return 'Video requires sign-in (age restricted?)';
    }
    if (s.contains('SocketException')) {
      return 'Network error — check connection';
    }
    if (e is FormatException) return e.message;
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  void dispose() {
    _yt.close();
  }
}
