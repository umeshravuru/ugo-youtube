import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/video_item.dart';
import '../services/keepalive.dart' as svc;

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.item});

  final VideoItem item;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _video;
  ChewieController? _chewie;
  String? _error;
  bool _playbackServiceOn = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _init();
  }

  /// Mirror the play/pause state into the media-playback foreground service
  /// so audio keeps running when the app is minimized.
  void _onPlayStateChanged() {
    final playing = _video?.value.isPlaying ?? false;
    if (playing && !_playbackServiceOn) {
      _playbackServiceOn = true;
      svc.KeepAlive.startPlayback(widget.item.title);
    } else if (!playing && _playbackServiceOn) {
      _playbackServiceOn = false;
      svc.KeepAlive.stopPlayback();
    }
  }

  Future<void> _init() async {
    try {
      // allowBackgroundPlayback: without it video_player force-pauses when
      // the app is minimized, which defeats listen-in-background.
      final controller = VideoPlayerController.file(
        File(widget.item.filePath!),
        videoPlayerOptions: VideoPlayerOptions(allowBackgroundPlayback: true),
      );
      await controller.initialize();
      final chewie = ChewieController(
        videoPlayerController: controller,
        autoPlay: true,
        allowPlaybackSpeedChanging: true,
        playbackSpeeds: const [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2],
        allowFullScreen: true,
        allowMuting: true,
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
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    if (_playbackServiceOn) svc.KeepAlive.stopPlayback();
    _video?.removeListener(_onPlayStateChanged);
    _chewie?.dispose();
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          widget.item.title,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Center(
        child: _error != null
            ? Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not play video:\n$_error',
                    textAlign: TextAlign.center),
              )
            : _chewie != null
                ? Chewie(controller: _chewie!)
                : const CircularProgressIndicator(),
      ),
    );
  }
}
