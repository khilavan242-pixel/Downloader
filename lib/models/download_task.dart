import 'quality.dart';

enum TaskStatus {
  queued,
  fetching,
  downloading,
  converting,
  completed,
  failed,
  cancelled;

  static TaskStatus fromName(String? name) => TaskStatus.values
      .firstWhere((s) => s.name == name, orElse: () => TaskStatus.queued);

  bool get isActive =>
      this == queued || this == fetching || this == downloading || this == converting;
  bool get isFinished => this == completed || this == failed || this == cancelled;
}

/// Immutable snapshot of a single download. The native layer is the source of
/// truth while a download runs; finished items are kept in the saved history.
class DownloadTask {
  DownloadTask({
    required this.id,
    required this.url,
    required this.kind,
    required this.quality,
    this.title,
    this.status = TaskStatus.queued,
    this.progress = 0,
    this.etaSeconds = -1,
    this.error,
    this.savedTo,
    this.playlist = false,
    this.fileUri,
    this.fileSize,
    DateTime? createdAt,
    this.finishedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  final String url;
  final MediaKind kind;
  final QualityOption quality;
  final String? title;
  final TaskStatus status;

  /// 0..100
  final double progress;
  final int etaSeconds;
  final String? error;

  /// Human readable location, e.g. `Music/Tapnab`.
  final String? savedTo;
  final bool playlist;

  /// `content://` address of the saved file, used to play, share and delete.
  final String? fileUri;

  /// Size in bytes, when known.
  final int? fileSize;

  final DateTime createdAt;
  final DateTime? finishedAt;

  /// The moment shown in the list and used for date grouping.
  DateTime get when => finishedAt ?? createdAt;

  String get displayTitle => (title == null || title!.trim().isEmpty) ? url : title!;

  String get mime => kind == MediaKind.mp3 ? 'audio/mpeg' : 'video/mp4';

  DownloadTask copyWith({
    String? title,
    TaskStatus? status,
    double? progress,
    int? etaSeconds,
    String? error,
    String? savedTo,
    String? fileUri,
    int? fileSize,
    DateTime? finishedAt,
    bool clearError = false,
  }) {
    return DownloadTask(
      id: id,
      url: url,
      kind: kind,
      quality: quality,
      playlist: playlist,
      createdAt: createdAt,
      title: title ?? this.title,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      error: clearError ? null : (error ?? this.error),
      savedTo: savedTo ?? this.savedTo,
      fileUri: fileUri ?? this.fileUri,
      fileSize: fileSize ?? this.fileSize,
      finishedAt: finishedAt ?? this.finishedAt,
    );
  }

  static QualityOption _quality(MediaKind kind, int value) =>
      QualityOption.forKind(kind).firstWhere(
        (q) => q.value == value,
        orElse: () => QualityOption.defaultFor(kind),
      );

  /// Builds a task from the map the native layer sends.
  factory DownloadTask.fromMap(Map<dynamic, dynamic> m) {
    final kind = MediaKind.fromName(m['kind'] as String? ?? 'mp3');
    final size = (m['fileSize'] as num?)?.toInt();
    return DownloadTask(
      id: m['id'] as String,
      url: m['url'] as String? ?? '',
      kind: kind,
      quality: _quality(kind, (m['quality'] as num?)?.toInt() ?? 0),
      playlist: m['playlist'] as bool? ?? false,
      title: m['title'] as String?,
      status: TaskStatus.fromName(m['status'] as String?),
      progress: (m['progress'] as num?)?.toDouble() ?? 0,
      etaSeconds: (m['eta'] as num?)?.toInt() ?? -1,
      error: m['error'] as String?,
      savedTo: m['savedTo'] as String?,
      fileUri: m['fileUri'] as String?,
      fileSize: (size == null || size <= 0) ? null : size,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'url': url,
        'kind': kind.name,
        'quality': quality.value,
        'playlist': playlist,
        'title': title,
        'status': status.name,
        'progress': progress,
        'error': error,
        'savedTo': savedTo,
        'fileUri': fileUri,
        'fileSize': fileSize,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'finishedAt': finishedAt?.millisecondsSinceEpoch,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) {
    final kind = MediaKind.fromName(j['kind'] as String? ?? 'mp3');
    final finished = j['finishedAt'] as int?;
    return DownloadTask(
      id: j['id'] as String,
      url: j['url'] as String? ?? '',
      kind: kind,
      quality: _quality(kind, (j['quality'] as num?)?.toInt() ?? 0),
      playlist: j['playlist'] as bool? ?? false,
      title: j['title'] as String?,
      status: TaskStatus.fromName(j['status'] as String?),
      progress: (j['progress'] as num?)?.toDouble() ?? 0,
      error: j['error'] as String?,
      savedTo: j['savedTo'] as String?,
      fileUri: j['fileUri'] as String?,
      fileSize: (j['fileSize'] as num?)?.toInt(),
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (j['createdAt'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ),
      finishedAt: finished == null ? null : DateTime.fromMillisecondsSinceEpoch(finished),
    );
  }
}
