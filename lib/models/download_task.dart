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
/// truth; the Dart side only mirrors the state it is told about.
class DownloadTask {
  const DownloadTask({
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
  });

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

  String get displayTitle => (title == null || title!.trim().isEmpty) ? url : title!;

  DownloadTask copyWith({
    String? title,
    TaskStatus? status,
    double? progress,
    int? etaSeconds,
    String? error,
    String? savedTo,
    bool clearError = false,
  }) {
    return DownloadTask(
      id: id,
      url: url,
      kind: kind,
      quality: quality,
      playlist: playlist,
      title: title ?? this.title,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      etaSeconds: etaSeconds ?? this.etaSeconds,
      error: clearError ? null : (error ?? this.error),
      savedTo: savedTo ?? this.savedTo,
    );
  }

  /// Builds a task from the map the native layer sends.
  factory DownloadTask.fromMap(Map<dynamic, dynamic> m) {
    final kind = MediaKind.fromName(m['kind'] as String? ?? 'mp3');
    final value = (m['quality'] as num?)?.toInt() ?? 0;
    final quality = QualityOption.forKind(kind).firstWhere(
      (q) => q.value == value,
      orElse: () => QualityOption.defaultFor(kind),
    );
    return DownloadTask(
      id: m['id'] as String,
      url: m['url'] as String? ?? '',
      kind: kind,
      quality: quality,
      playlist: m['playlist'] as bool? ?? false,
      title: m['title'] as String?,
      status: TaskStatus.fromName(m['status'] as String?),
      progress: (m['progress'] as num?)?.toDouble() ?? 0,
      etaSeconds: (m['eta'] as num?)?.toInt() ?? -1,
      error: m['error'] as String?,
      savedTo: m['savedTo'] as String?,
    );
  }
}
