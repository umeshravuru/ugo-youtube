import 'dart:async';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/video_item.dart';
import '../services/keepalive.dart' as svc;
import '../services/library_store.dart';
import '../util/resume.dart';

/// Inline docked player (YouTube-style): 16:9 video with a title/close row.
/// Plays the local file when the download is done, otherwise streams the
/// video's pre-muxed network URL so watching can start mid-download.
/// Saves the watch position for resume and keeps audio alive in background
/// via the media-playback foreground service.
class PlayerPanel extends StatefulWidget {
  const PlayerPanel({
    super.key,
    required this.item,
    required this.store,
    required this.onClose,
  });

  final VideoItem item;
  final LibraryStore store;
  final VoidCallback onClose;

  @override
  State<PlayerPanel> createState() => _PlayerPanelState();
}

class _PlayerPanelState extends State<PlayerPanel> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  String? _error;
  Timer? _positionSaver;
  bool _serviceStarted = false;
  bool _lastReportedPlaying = false;

  // Source is decided once at creation; a mid-watch swap (download finishing)
  // would dispose controllers under chewie's fullscreen route.
  late final bool _useLocalFile =
      widget.item.status == VideoStatus.done && widget.item.filePath != null;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    svc.KeepAlive.ensureMediaHandler();
    svc.KeepAlive.onMediaAction = _onMediaAction;
    svc.KeepAlive.onMediaSeek = _onMediaSeek;
    _init();
  }

  /// Lock-screen / headset button presses.
  void _onMediaAction(String action) {
    final video = _video;
    if (video == null || !video.value.isInitialized) return;
    switch (action) {
      case 'play':
        video.play();
      case 'pause':
        video.pause();
      case 'playPause':
        video.value.isPlaying ? video.pause() : video.play();
    }
  }

  void _onMediaSeek(Duration position) {
    _video?.seekTo(position);
  }

  Future<void> _init() async {
    try {
      final options = VideoPlayerOptions(allowBackgroundPlayback: true);
      final VideoPlayerController controller;
      if (_useLocalFile) {
        controller = VideoPlayerController.file(
          File(widget.item.filePath!),
          videoPlayerOptions: options,
        );
      } else if (widget.item.previewUrl != null) {
        controller = VideoPlayerController.networkUrl(
          Uri.parse(widget.item.previewUrl!),
          videoPlayerOptions: options,
        );
      } else {
        setState(() => _error = 'Not playable yet');
        return;
      }
      await controller.initialize();

      final resume = computeResumeOffset(
        lastPositionMs: widget.item.lastPositionMs,
        durationMs: widget.item.durationMs,
      );
      if (resume > Duration.zero) {
        await controller.seekTo(resume);
      }

      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        aspectRatio: 16 / 9,
        allowFullScreen: true,
        allowMuting: true,
        allowPlaybackSpeedChanging: true,
        playbackSpeeds: const [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2],
      );

      if (!mounted) {
        chewie.dispose();
        controller.dispose();
        return;
      }
      controller.addListener(_onPlayStateChanged);
      setState(() {
        _video = controller;
        _chewie = chewie;
      });
      _onPlayStateChanged();
      _positionSaver = Timer.periodic(const Duration(seconds: 5), (_) {
        _savePosition();
        // Keep the lock-screen seek bar in sync.
        if (_serviceStarted && _lastReportedPlaying) {
          _pushPlaybackState(true);
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = _useLocalFile
            ? 'Could not play file: $e'
            : 'Preview unavailable — let the download finish.\n$e');
      }
    }
  }

  /// Mirror play/pause into the media-playback service, which keeps audio
  /// alive in background and drives the lock-screen media card. The service
  /// stays up (paused state) while the panel is open so the lock screen can
  /// un-pause; it stops when the panel closes.
  void _onPlayStateChanged() {
    final playing = _video?.value.isPlaying ?? false;
    if (!_serviceStarted && !playing) return;
    if (_serviceStarted && playing == _lastReportedPlaying) return;
    _serviceStarted = true;
    _lastReportedPlaying = playing;
    _pushPlaybackState(playing);
    if (!playing) _savePosition();
  }

  void _pushPlaybackState(bool playing) {
    final value = _video?.value;
    svc.KeepAlive.updatePlayback(
      title: widget.item.title,
      isPlaying: playing,
      positionMs: value?.position.inMilliseconds ?? 0,
      durationMs: widget.item.durationMs,
      thumbPath: widget.item.thumbPath,
    );
  }

  void _savePosition() {
    final value = _video?.value;
    if (value == null || !value.isInitialized) return;
    final pos = value.position.inMilliseconds;
    if (pos == widget.item.lastPositionMs) return;
    widget.item.lastPositionMs = pos;
    widget.store.upsert(widget.item);
  }

  @override
  void dispose() {
    _positionSaver?.cancel();
    _savePosition();
    svc.KeepAlive.onMediaAction = null;
    svc.KeepAlive.onMediaSeek = null;
    if (_serviceStarted) svc.KeepAlive.stopPlayback();
    WakelockPlus.disable();
    _video?.removeListener(_onPlayStateChanged);
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: Colors.black,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: _error != null
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                      child: Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                : _chewie != null
                    ? Chewie(controller: _chewie!)
                    : const Center(child: CircularProgressIndicator()),
          ),
          Container(
            color: scheme.surfaceContainerHigh,
            padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                      if (!_useLocalFile)
                        Text(
                          'Streaming preview — downloading in background',
                          style: TextStyle(
                              fontSize: 11, color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Close player',
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
