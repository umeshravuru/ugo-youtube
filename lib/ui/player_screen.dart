import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/video_item.dart';

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

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _init();
  }

  Future<void> _init() async {
    try {
      final controller =
          VideoPlayerController.file(File(widget.item.filePath!));
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
      setState(() {
        _video = controller;
        _chewie = chewie;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    WakelockPlus.disable();
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
