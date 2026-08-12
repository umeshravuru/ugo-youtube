// Verifies segmented-download CONTENT correctness against the library's
// own stream downloader for the same video stream.
//   dart run tool/probe_content.dart
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ugo_yt/services/segmented_downloader.dart';
import 'package:ugo_yt/services/stream_pick.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final url = args.isNotEmpty
      ? args[0]
      : 'https://www.youtube.com/watch?v=LXb3EKWsInQ';
  const limit = 12 * 1024 * 1024; // compare first 12MB (crosses a segment edge)
  final yt = YoutubeExplode();
  try {
    final id = VideoId(url);
    final manifest = await yt.videos.streamsClient.getManifest(id);
    final pick = pickStreams(manifest);
    final v = pick.video!;
    print('Stream: ${v.qualityLabel} tag=${v.tag} total=${v.size.totalBytes}');

    final dir = await Directory.systemTemp.createTemp('ugo_content');
    final segFile = File('${dir.path}/seg.bin');
    final refFile = File('${dir.path}/ref.bin');

    // 1) Segmented downloader with a small segment size to cross boundaries.
    var got = 0;
    final dl = SegmentedDownloader(segmentSize: 4 * 1024 * 1024);
    try {
      await dl.download(
        url: v.url,
        totalBytes: v.size.totalBytes,
        target: segFile,
        onChunk: (n) => got += n,
        isCancelled: () => got >= limit,
      );
    } on DownloadCancelled {
      // expected at limit
    }
    // May slightly overshoot limit; trim both to exact limit for comparison.

    // 2) Reference: youtube_explode's own downloader.
    var refGot = 0;
    final sink = refFile.openWrite();
    try {
      await for (final chunk in yt.videos.streamsClient.get(v)) {
        final remaining = limit + 512 * 1024 - refGot;
        if (remaining <= 0) break;
        sink.add(chunk.length <= remaining ? chunk : chunk.sublist(0, remaining));
        refGot += chunk.length;
        if (refGot >= limit + 512 * 1024) break;
      }
    } catch (_) {}
    await sink.flush();
    await sink.close();

    final segBytes = (await segFile.readAsBytes()).sublist(0, limit);
    final refBytes = (await refFile.readAsBytes()).sublist(0, limit);
    final segHash = sha256.convert(segBytes).toString();
    final refHash = sha256.convert(refBytes).toString();
    print('segmented sha256: $segHash');
    print('reference sha256: $refHash');
    if (segHash == refHash) {
      print('CONTENT MATCH — segmented downloader is byte-correct');
    } else {
      // find first divergence
      var i = 0;
      while (i < limit && segBytes[i] == refBytes[i]) {
        i++;
      }
      print('CONTENT MISMATCH at byte $i');
      exitCode = 1;
    }
    await dir.delete(recursive: true);
  } finally {
    yt.close();
  }
}
