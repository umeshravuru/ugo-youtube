import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/video_item.dart';

/// Persistent index of downloaded videos, backed by `library.json` in
/// [baseDir]. Keeps at most [maxItems] completed videos — oldest evicted,
/// including their media files.
class LibraryStore {
  LibraryStore(this.baseDir, {this.maxItems = 10});

  final Directory baseDir;
  final int maxItems;

  final ValueNotifier<List<VideoItem>> items =
      ValueNotifier<List<VideoItem>>(const []);

  File get _file => File('${baseDir.path}/library.json');
  Future<void> _saving = Future.value();

  Future<void> load() async {
    var list = <VideoItem>[];
    try {
      if (await _file.exists()) {
        final raw = jsonDecode(await _file.readAsString()) as List<dynamic>;
        list = raw
            .map((e) => VideoItem.fromJson(e as Map<String, dynamic>))
            .toList();
      }
    } catch (_) {
      list = [];
    }
    // Anything that was mid-flight when the process died is now failed.
    for (final it in list) {
      if (it.status.isActive) {
        it.status = VideoStatus.failed;
        it.error = 'Interrupted — tap retry';
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    items.value = List.unmodifiable(list);
    _persist();
  }

  VideoItem? byId(String id) {
    for (final it in items.value) {
      if (it.id == id) return it;
    }
    return null;
  }

  void upsert(VideoItem item, {bool persist = true}) {
    final list = [...items.value];
    final i = list.indexWhere((e) => e.id == item.id);
    if (i >= 0) {
      list[i] = item;
    } else {
      list.insert(0, item);
    }
    items.value = List.unmodifiable(list);
    if (persist) _persist();
  }

  Future<void> remove(String id) async {
    final list = [...items.value];
    final i = list.indexWhere((e) => e.id == id);
    if (i < 0) return;
    final victim = list.removeAt(i);
    items.value = List.unmodifiable(list);
    _persist();
    await _deleteFiles(victim);
  }

  /// Evict oldest completed videos beyond [maxItems].
  Future<void> enforceLimit() async {
    final done = items.value
        .where((e) => e.status == VideoStatus.done)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (done.length <= maxItems) return;
    for (final victim in done.sublist(maxItems)) {
      await remove(victim.id);
    }
  }

  /// Await all pending disk writes (used by tests and shutdown).
  Future<void> flush() => _saving;

  Future<void> _deleteFiles(VideoItem item) async {
    for (final path in [item.filePath, item.thumbPath]) {
      if (path == null) continue;
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  void _persist() {
    final snapshot = items.value.map((e) => e.toJson()).toList();
    _saving = _saving.then((_) async {
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(jsonEncode(snapshot));
      await tmp.rename(_file.path);
    }).catchError((_) {});
  }
}
