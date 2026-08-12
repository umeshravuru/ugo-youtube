// Host-side live probe: verifies YouTube extraction + streaming works from
// this machine before building the app.
//
//   dart run tool/probe.dart [youtube-url] [--download]
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:ugo_yt/services/stream_pick.dart';
import 'package:ugo_yt/util/url_parse.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

Future<void> main(List<String> args) async {
  final url = args.where((a) => !a.startsWith('--')).firstOrNull ??
      'https://www.youtube.com/watch?v=jNQXAC9IVRw'; // "Me at the zoo", 19s
  final download = args.contains('--download');

  final id = extractYoutubeVideoId(url);
  if (id == null) {
    print('FAIL: could not parse video id from: $url');
    exit(1);
  }
  print('Video id: $id');

  final yt = YoutubeExplode();
  try {
    final video = await yt.videos.get(VideoId(id));
    print('Title   : ${video.title}');
    print('Author  : ${video.author}');
    print('Duration: ${video.duration}');
    print('Live    : ${video.isLive}');

    final manifest = await yt.videos.streamsClient.getManifest(VideoId(id));
    print('\nStreams: ${manifest.streams.length} total');
    print('  muxed    : ${manifest.muxed.length}');
    for (final s in manifest.muxed) {
      print('    ${s.qualityLabel} ${s.container.name} ${s.videoCodec} '
          '${(s.size.totalBytes / 1024 / 1024).toStringAsFixed(1)}MB');
    }
    print('  videoOnly: ${manifest.videoOnly.length}');
    print('  audioOnly: ${manifest.audioOnly.length}');

    final pick = pickStreams(manifest);
    print('\nPick: ${pick.describe()} '
        '(${(pick.totalBytes / 1024 / 1024).toStringAsFixed(1)}MB, '
        '.${pick.extension}, adaptive=${pick.isAdaptive})');

    if (download) {
      final dir = await Directory.systemTemp.createTemp('ugo_probe');
      Future<int> pull(StreamInfo info, String name) async {
        final f = File('${dir.path}/$name');
        final sink = f.openWrite();
        var n = 0;
        await for (final chunk in yt.videos.streamsClient.get(info)) {
          sink.add(chunk);
          n += chunk.length;
        }
        await sink.flush();
        await sink.close();
        return n;
      }

      if (pick.isAdaptive) {
        final vb = await pull(pick.video!, 'v.bin');
        print('video bytes: $vb (expected ${pick.video!.size.totalBytes})');
        final ab = await pull(pick.audio!, 'a.bin');
        print('audio bytes: $ab (expected ${pick.audio!.size.totalBytes})');
      } else if (pick.muxed != null) {
        final mb = await pull(pick.muxed!, 'm.bin');
        print('muxed bytes: $mb (expected ${pick.muxed!.size.totalBytes})');
      }
      await dir.delete(recursive: true);
      print('DOWNLOAD OK');
    }
    print('\nPROBE OK');
  } finally {
    yt.close();
  }
}
