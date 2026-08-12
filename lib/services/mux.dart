import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

/// Merges a video-only and audio-only file into [outPath] with stream copy
/// (no re-encode — fast and battery-cheap). Returns false on any failure so
/// the caller can fall back to a pre-muxed download.
Future<bool> muxCopy(String videoPath, String audioPath, String outPath) async {
  try {
    final args = [
      '-y',
      '-i', videoPath,
      '-i', audioPath,
      '-c', 'copy',
      if (outPath.endsWith('.mp4')) ...['-movflags', '+faststart'],
      outPath,
    ];
    final session = await FFmpegKit.executeWithArguments(args);
    final rc = await session.getReturnCode();
    return ReturnCode.isSuccess(rc);
  } catch (_) {
    return false;
  }
}
