import 'package:flutter_test/flutter_test.dart';
import 'package:tapnab/models/download_task.dart';
import 'package:tapnab/models/quality.dart';

void main() {
  DownloadTask sample() => DownloadTask(
        id: 'a-1',
        url: 'https://youtu.be/abc',
        kind: MediaKind.mp4,
        quality: QualityOption.video[4],
        title: 'A song',
        status: TaskStatus.completed,
        progress: 100,
        savedTo: 'Movies/Tapnab',
        fileUri: 'content://media/external/video/media/7',
        fileSize: 3555328,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1000000),
        finishedAt: DateTime.fromMillisecondsSinceEpoch(2000000),
      );

  test('JSON round trip keeps everything the list needs', () {
    final back = DownloadTask.fromJson(sample().toJson());
    expect(back.id, 'a-1');
    expect(back.kind, MediaKind.mp4);
    expect(back.quality.value, 720);
    expect(back.status, TaskStatus.completed);
    expect(back.fileUri, 'content://media/external/video/media/7');
    expect(back.fileSize, 3555328);
    expect(back.createdAt.millisecondsSinceEpoch, 1000000);
    expect(back.finishedAt?.millisecondsSinceEpoch, 2000000);
    expect(back.when.millisecondsSinceEpoch, 2000000);
  });

  test('fromMap treats unknown size (-1) as null', () {
    final t = DownloadTask.fromMap({
      'id': 'x',
      'url': 'https://youtu.be/abc',
      'kind': 'mp3',
      'quality': 192,
      'status': 'downloading',
      'progress': 42.5,
      'fileSize': -1,
    });
    expect(t.fileSize, isNull);
    expect(t.quality.value, 192);
    expect(t.status.isActive, isTrue);
  });

  test('copyWith keeps createdAt and clears errors on request', () {
    final failed = sample().copyWith(status: TaskStatus.failed, error: 'boom');
    expect(failed.error, 'boom');
    expect(failed.status.isFinished, isTrue);
    final cleared = failed.copyWith(clearError: true);
    expect(cleared.error, isNull);
    expect(cleared.createdAt, sample().createdAt);
  });

  test('mime follows the kind', () {
    expect(sample().mime, 'video/mp4');
    expect(
      DownloadTask(id: 'b', url: 'u', kind: MediaKind.mp3, quality: QualityOption.audio[0]).mime,
      'audio/mpeg',
    );
  });
}
