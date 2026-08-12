import 'package:flutter_test/flutter_test.dart';
import 'package:ugo_yt/models/video_item.dart';
import 'package:ugo_yt/util/resume.dart';

void main() {
  group('computeResumeOffset', () {
    test('starts over when barely watched', () {
      expect(
        computeResumeOffset(lastPositionMs: 3000, durationMs: 600000),
        Duration.zero,
      );
    });

    test('resumes mid-video', () {
      expect(
        computeResumeOffset(lastPositionMs: 120000, durationMs: 600000),
        const Duration(minutes: 2),
      );
    });

    test('starts over when effectively finished (>=95%)', () {
      expect(
        computeResumeOffset(lastPositionMs: 590000, durationMs: 600000),
        Duration.zero,
      );
    });

    test('resumes when duration unknown', () {
      expect(
        computeResumeOffset(lastPositionMs: 60000, durationMs: 0),
        const Duration(minutes: 1),
      );
    });
  });

  group('VideoItem persistence', () {
    test('round-trips lastPositionMs, never persists previewUrl', () {
      final item = VideoItem(
        id: 'dQw4w9WgXcQ',
        createdAt: 42,
        status: VideoStatus.done,
        lastPositionMs: 98765,
      )..previewUrl = 'https://example.com/expired-soon';

      final json = item.toJson();
      expect(json['lastPositionMs'], 98765);
      expect(json.containsKey('previewUrl'), isFalse);

      final back = VideoItem.fromJson(json);
      expect(back.lastPositionMs, 98765);
      expect(back.previewUrl, isNull);
    });

    test('isPlayable logic', () {
      final done = VideoItem(
          id: 'aaaaaaaaaaa',
          createdAt: 1,
          status: VideoStatus.done,
          filePath: '/tmp/x.mp4');
      expect(done.isPlayable, isTrue);

      final downloading = VideoItem(
          id: 'bbbbbbbbbbb', createdAt: 1, status: VideoStatus.downloading);
      expect(downloading.isPlayable, isFalse);
      downloading.previewUrl = 'https://example.com/muxed';
      expect(downloading.isPlayable, isTrue);

      final failed = VideoItem(
          id: 'ccccccccccc', createdAt: 1, status: VideoStatus.failed)
        ..previewUrl = 'https://example.com/muxed';
      expect(failed.isPlayable, isFalse);
    });
  });
}
