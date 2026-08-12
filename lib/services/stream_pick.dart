import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Result of choosing which streams to download for a video.
///
/// Preference order:
///  1. Adaptive H.264 (avc1) MP4 video ≤ [maxHeight] + best AAC (m4a) audio
///     → muxed on-device into a single .mp4 (stream copy, no re-encode).
///  2. Adaptive VP9 WebM video ≤ [maxHeight] + best Opus WebM audio → .webm.
///  3. Best pre-muxed stream (usually 360p) → direct single-file download.
class StreamPick {
  StreamPick({this.video, this.audio, this.muxed, this.extension = 'mp4'});

  final VideoOnlyStreamInfo? video;
  final AudioOnlyStreamInfo? audio;
  final MuxedStreamInfo? muxed;

  /// File extension of the final output ('mp4' or 'webm').
  final String extension;

  bool get isAdaptive => video != null && audio != null;

  int get totalBytes {
    if (isAdaptive) {
      return video!.size.totalBytes + audio!.size.totalBytes;
    }
    return muxed?.size.totalBytes ?? 0;
  }

  String describe() {
    if (isAdaptive) {
      return '${video!.qualityLabel} ${video!.videoCodec.split('.').first}'
          ' + ${audio!.audioCodec.split('.').first}';
    }
    if (muxed != null) return '${muxed!.qualityLabel} (muxed)';
    return 'none';
  }
}

/// The smaller of width/height must fit within [maxHeight] so vertical
/// Shorts (1080x1920) still count as 1080p.
bool _fitsQuality(VideoResolution res, int maxHeight) {
  final smallSide =
      res.width < res.height ? res.width : res.height;
  // Some streams report 0x0; keep them rather than losing the video.
  if (smallSide <= 0) return true;
  return smallSide <= maxHeight;
}

VideoOnlyStreamInfo? _bestVideo(
  Iterable<VideoOnlyStreamInfo> streams,
  String containerName,
  String codecPrefix,
  int maxHeight,
) {
  VideoOnlyStreamInfo? best;
  for (final s in streams) {
    if (s.container.name != containerName) continue;
    if (!s.videoCodec.toLowerCase().startsWith(codecPrefix)) continue;
    if (!_fitsQuality(s.videoResolution, maxHeight)) continue;
    if (best == null ||
        _area(s.videoResolution) > _area(best.videoResolution) ||
        (_area(s.videoResolution) == _area(best.videoResolution) &&
            s.bitrate.bitsPerSecond > best.bitrate.bitsPerSecond)) {
      best = s;
    }
  }
  return best;
}

int _area(VideoResolution r) => r.width * r.height;

AudioOnlyStreamInfo? _bestAudio(
  Iterable<AudioOnlyStreamInfo> streams,
  String containerName,
) {
  AudioOnlyStreamInfo? best;
  for (final s in streams) {
    if (s.container.name != containerName) continue;
    if (best == null || s.bitrate.bitsPerSecond > best.bitrate.bitsPerSecond) {
      best = s;
    }
  }
  return best;
}

MuxedStreamInfo? _bestMuxed(Iterable<MuxedStreamInfo> streams) {
  MuxedStreamInfo? best;
  for (final s in streams) {
    if (best == null || _area(s.videoResolution) > _area(best.videoResolution)) {
      best = s;
    }
  }
  return best;
}

StreamPick pickStreams(StreamManifest manifest, {int maxHeight = 1080}) {
  final muxed = _bestMuxed(manifest.muxed);

  // Tier 1: H.264 + AAC in MP4 — plays everywhere, stream-copy muxable.
  final v264 = _bestVideo(manifest.videoOnly, 'mp4', 'avc1', maxHeight);
  final aac = _bestAudio(manifest.audioOnly, 'mp4');
  if (v264 != null && aac != null) {
    return StreamPick(video: v264, audio: aac, muxed: muxed, extension: 'mp4');
  }

  // Tier 2: VP9 + Opus in WebM.
  final vp9 = _bestVideo(manifest.videoOnly, 'webm', 'vp', maxHeight);
  final opus = _bestAudio(manifest.audioOnly, 'webm');
  if (vp9 != null && opus != null) {
    return StreamPick(video: vp9, audio: opus, muxed: muxed, extension: 'webm');
  }

  // Tier 3: whatever pre-muxed stream exists.
  return StreamPick(
    muxed: muxed,
    extension: muxed?.container.name == 'webm' ? 'webm' : 'mp4',
  );
}
