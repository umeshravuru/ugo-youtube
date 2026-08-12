// Host-side probe for the segmented downloader against a real video.
//   dart run tool/probe_segmented.dart [youtube-url]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ugo_yt/services/segmented_downloader.dart';
import 'package:ugo_yt/services/stream_pick.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty
      ? args[0]
      : 'https://www.youtube.com/watch?v=LXb3EKWsInQ';
  final yt = YoutubeExplode();
  try {
    final id = VideoId(url);
    final manifest = await yt.videos.streamsClient.getManifest(id);
    final pick = pickStreams(manifest);
    if (!pick.isAdaptive) {
      print('No adaptive pick — nothing to probe');
      return;
    }
    final v = pick.video!;
    print('Stream: ${v.qualityLabel} ${v.videoCodec} '
        '${(v.size.totalBytes / 1024 / 1024).toStringAsFixed(1)}MB tag=${v.tag}');
    print('URL host: ${v.url.host}');

    final dir = await Directory.systemTemp.createTemp('ugo_seg_probe');
    final target = File('${dir.path}/v.bin');
    var got = 0;
    const limit = 24 * 1024 * 1024; // stop after ~24MB (3 segments)
    final dl = SegmentedDownloader(
      inactivityTimeout: const Duration(seconds: 20),
    );
    try {
      await dl.download(
        url: v.url,
        totalBytes: v.size.totalBytes,
        target: target,
        onChunk: (n) {
          got += n;
        },
        isCancelled: () => got >= limit,
        refreshUrl: () async {
          print('(refreshUrl invoked)');
          final m2 = await yt.videos.streamsClient.getManifest(id);
          for (final s in m2.streams) {
            if (s.tag == v.tag) return s.url;
          }
          return null;
        },
      );
      print('Downloaded fully: $got bytes');
    } on DownloadCancelled {
      print('Reached probe limit: $got bytes — SEGMENTED PATH OK');
    } catch (e) {
      print('SEGMENTED PATH FAILED after $got bytes: $e');
      exitCode = 1;
    } finally {
      dl.close();
      await dir.delete(recursive: true);
    }
  } finally {
    yt.close();
  }
}
