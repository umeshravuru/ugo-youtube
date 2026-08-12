enum VideoStatus { queued, fetching, downloading, muxing, done, failed }

extension VideoStatusX on VideoStatus {
  bool get isActive =>
      this == VideoStatus.queued ||
      this == VideoStatus.fetching ||
      this == VideoStatus.downloading ||
      this == VideoStatus.muxing;
}

class VideoItem {
  VideoItem({
    required this.id,
    required this.createdAt,
    this.title = '',
    this.author = '',
    this.durationMs = 0,
    this.sizeBytes = 0,
    this.status = VideoStatus.queued,
    this.progress = 0,
    this.error,
    this.filePath,
    this.thumbPath,
  });

  factory VideoItem.queued(String id) => VideoItem(
        id: id,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        title: 'Fetching…',
      );

  final String id; // YouTube video id
  String title;
  String author;
  int durationMs;
  int sizeBytes;
  VideoStatus status;
  double progress; // 0..1 while downloading
  String? error;
  String? filePath; // final playable file
  String? thumbPath;
  final int createdAt; // epoch ms when first queued

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'durationMs': durationMs,
        'sizeBytes': sizeBytes,
        'status': status.name,
        'progress': progress,
        'error': error,
        'filePath': filePath,
        'thumbPath': thumbPath,
        'createdAt': createdAt,
      };

  factory VideoItem.fromJson(Map<String, dynamic> json) => VideoItem(
        id: json['id'] as String,
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
        status: VideoStatus.values.asNameMap()[json['status']] ??
            VideoStatus.failed,
        progress: (json['progress'] as num?)?.toDouble() ?? 0,
        error: json['error'] as String?,
        filePath: json['filePath'] as String?,
        thumbPath: json['thumbPath'] as String?,
      );
}
