import 'dart:io';

import 'package:flutter/material.dart';

import '../models/video_item.dart';
import '../services/downloader.dart';
import '../services/library_store.dart';
import '../util/format.dart';
import 'player_panel.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen(
      {super.key, required this.store, required this.downloader});

  final LibraryStore store;
  final DownloadManager downloader;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  String? _playingId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ugo-yt',
            style: TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5)),
        actions: [
          IconButton(
            tooltip: 'Add link',
            icon: const Icon(Icons.add_link),
            onPressed: () => _promptForLink(context),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<VideoItem>>(
        valueListenable: widget.store.items,
        builder: (context, items, _) {
          VideoItem? playing;
          for (final it in items) {
            if (it.id == _playingId) {
              playing = it;
              break;
            }
          }
          return Column(
            children: [
              if (playing != null)
                PlayerPanel(
                  // Source (file vs network preview) is fixed per panel
                  // instance; keying by id keeps it stable while the item's
                  // status/progress fields update underneath.
                  key: ValueKey('player-${playing.id}'),
                  item: playing,
                  store: widget.store,
                  onClose: () => setState(() => _playingId = null),
                ),
              Expanded(
                child: items.isEmpty
                    ? const _EmptyHint()
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (context, i) => _VideoTile(
                          item: items[i],
                          downloader: widget.downloader,
                          store: widget.store,
                          isPlaying: items[i].id == _playingId,
                          onPlay: _onPlay,
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  void _onPlay(VideoItem item) {
    setState(() => _playingId = item.id);
  }

  Future<void> _promptForLink(BuildContext context) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add YouTube link'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'https://youtu.be/…'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Download'),
          ),
        ],
      ),
    );
    if (text != null && text.trim().isNotEmpty) {
      await widget.downloader.enqueueFromSharedText(text);
    }
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.download_for_offline_outlined, size: 72, color: muted),
            const SizedBox(height: 16),
            Text(
              'No videos yet',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Text(
              'In YouTube, tap Share → ugo-yt and the video '
              'will download here.\n\nKeeps your last 10 videos.',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _VideoTile extends StatelessWidget {
  const _VideoTile({
    required this.item,
    required this.downloader,
    required this.store,
    required this.isPlaying,
    required this.onPlay,
  });

  final VideoItem item;
  final DownloadManager downloader;
  final LibraryStore store;
  final bool isPlaying;
  final void Function(VideoItem) onPlay;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color:
          isPlaying ? scheme.surfaceContainerHighest : scheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: item.isPlayable ? () => onPlay(item) : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumb(item: item),
              const SizedBox(width: 12),
              Expanded(child: _Details(item: item, downloader: downloader)),
              _Menu(item: item, store: store, downloader: downloader),
            ],
          ),
        ),
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({required this.item});

  final VideoItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget child;
    if (item.thumbPath != null && File(item.thumbPath!).existsSync()) {
      child = Image.file(
        File(item.thumbPath!),
        width: 120,
        height: 68,
        fit: BoxFit.cover,
      );
    } else {
      child = Container(
        width: 120,
        height: 68,
        color: scheme.surfaceContainerHighest,
        child: Icon(Icons.smart_display_outlined,
            color: scheme.onSurfaceVariant),
      );
    }
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        ClipRRect(borderRadius: BorderRadius.circular(8), child: child),
        if (item.durationMs > 0)
          Padding(
            padding: const EdgeInsets.all(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                formatDuration(item.durationMs),
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
            ),
          ),
      ],
    );
  }
}

class _Details extends StatelessWidget {
  const _Details({required this.item, required this.downloader});

  final VideoItem item;
  final DownloadManager downloader;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(color: scheme.onSurfaceVariant, fontSize: 12);

    final subtitle = [
      if (item.author.isNotEmpty) item.author,
      if (item.sizeBytes > 0) formatBytes(item.sizeBytes),
    ].join(' • ');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title.isEmpty ? item.id : item.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600, height: 1.2),
        ),
        const SizedBox(height: 4),
        if (subtitle.isNotEmpty) Text(subtitle, style: muted),
        const SizedBox(height: 6),
        _StatusRow(item: item, downloader: downloader),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.item, required this.downloader});

  final VideoItem item;
  final DownloadManager downloader;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (item.status) {
      case VideoStatus.done:
        return const SizedBox.shrink();
      case VideoStatus.failed:
        return Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: scheme.error),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                item.error ?? 'Failed',
                style: TextStyle(color: scheme.error, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: () => downloader.retry(item.id),
              child: const Text('Retry'),
            ),
          ],
        );
      case VideoStatus.queued:
      case VideoStatus.fetching:
      case VideoStatus.muxing:
      case VideoStatus.downloading:
        final label = switch (item.status) {
          VideoStatus.queued => 'Queued',
          VideoStatus.fetching => 'Fetching info…',
          VideoStatus.muxing => 'Merging…',
          _ => item.previewUrl != null
              ? 'Downloading ${(item.progress * 100).round()}% • tap to watch now'
              : 'Downloading ${(item.progress * 100).round()}%',
        };
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(fontSize: 12, color: scheme.primary)),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: item.status == VideoStatus.downloading &&
                      item.progress > 0
                  ? item.progress
                  : null,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
          ],
        );
    }
  }
}

class _Menu extends StatelessWidget {
  const _Menu({
    required this.item,
    required this.store,
    required this.downloader,
  });

  final VideoItem item;
  final LibraryStore store;
  final DownloadManager downloader;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (value) {
        if (value == 'delete') downloader.cancelAndRemove(item.id);
        if (value == 'retry') downloader.retry(item.id);
      },
      itemBuilder: (context) => [
        if (item.status == VideoStatus.failed)
          const PopupMenuItem(value: 'retry', child: Text('Retry')),
        PopupMenuItem(
          value: 'delete',
          child: Text(item.status.isActive ? 'Cancel download' : 'Delete'),
        ),
      ],
    );
  }
}
