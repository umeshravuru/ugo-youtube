import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ugo_yt/models/video_item.dart';
import 'package:ugo_yt/services/library_store.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('ugo_test');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  VideoItem doneItem(String id, int createdAt, {String? filePath}) {
    return VideoItem(
      id: id,
      createdAt: createdAt,
      title: 'Video $id',
      status: VideoStatus.done,
      filePath: filePath,
    );
  }

  test('upsert inserts new items at the front and updates in place', () async {
    final store = LibraryStore(tempDir);
    await store.load();

    store.upsert(doneItem('aaaaaaaaaaa', 1));
    store.upsert(doneItem('bbbbbbbbbbb', 2));
    expect(store.items.value.map((e) => e.id).toList(),
        ['bbbbbbbbbbb', 'aaaaaaaaaaa']);

    final updated = doneItem('aaaaaaaaaaa', 1)..title = 'renamed';
    store.upsert(updated);
    expect(store.items.value.length, 2);
    expect(store.byId('aaaaaaaaaaa')!.title, 'renamed');
    await store.flush();
  });

  test('persists and reloads across instances', () async {
    final store = LibraryStore(tempDir);
    await store.load();
    store.upsert(doneItem('aaaaaaaaaaa', 5));
    await store.flush();

    final store2 = LibraryStore(tempDir);
    await store2.load();
    expect(store2.items.value.single.id, 'aaaaaaaaaaa');
    expect(store2.items.value.single.status, VideoStatus.done);
  });

  test('in-flight items are marked failed on reload', () async {
    final store = LibraryStore(tempDir);
    await store.load();
    store.upsert(VideoItem(
      id: 'ccccccccccc',
      createdAt: 1,
      status: VideoStatus.downloading,
      progress: 0.4,
    ));
    await store.flush();

    final store2 = LibraryStore(tempDir);
    await store2.load();
    final item = store2.items.value.single;
    expect(item.status, VideoStatus.failed);
    expect(item.error, contains('Interrupted'));
  });

  test('remove deletes entry and media files', () async {
    final media = File('${tempDir.path}/vid.mp4')..writeAsStringSync('x');
    final thumb = File('${tempDir.path}/vid.jpg')..writeAsStringSync('x');
    final store = LibraryStore(tempDir);
    await store.load();
    final item = doneItem('ddddddddddd', 1, filePath: media.path)
      ..thumbPath = thumb.path;
    store.upsert(item);

    await store.remove('ddddddddddd');
    expect(store.items.value, isEmpty);
    expect(media.existsSync(), isFalse);
    expect(thumb.existsSync(), isFalse);
    await store.flush();
  });

  test('enforceLimit keeps only the 10 newest done videos', () async {
    final store = LibraryStore(tempDir);
    await store.load();

    final files = <String, File>{};
    for (var i = 0; i < 12; i++) {
      final id = 'video${i.toString().padLeft(6, '0')}'; // 11 chars
      final f = File('${tempDir.path}/$id.mp4')..writeAsStringSync('x');
      files[id] = f;
      store.upsert(doneItem(id, i, filePath: f.path));
    }
    // One in-flight item must not count toward the cap.
    store.upsert(VideoItem(
      id: 'inflight123',
      createdAt: 100,
      status: VideoStatus.downloading,
    ));

    await store.enforceLimit();

    final ids = store.items.value.map((e) => e.id).toSet();
    expect(
        store.items.value.where((e) => e.status == VideoStatus.done).length,
        10);
    // Oldest two evicted, files deleted.
    expect(ids.contains('video000000'), isFalse);
    expect(ids.contains('video000001'), isFalse);
    expect(files['video000000']!.existsSync(), isFalse);
    expect(files['video000001']!.existsSync(), isFalse);
    // Newest survivors intact.
    expect(ids.contains('video000011'), isTrue);
    expect(files['video000011']!.existsSync(), isTrue);
    expect(ids.contains('inflight123'), isTrue);
    await store.flush();
  });
}
