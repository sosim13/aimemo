import 'package:flutter/services.dart';

enum BackgroundQueueType { url, text, image }

class BackgroundQueueItem {
  final String content;
  final BackgroundQueueType type;

  const BackgroundQueueItem({
    required this.content,
    required this.type,
  });

  Map<String, Object> toMap() => {
        'content': content,
        'type': switch (type) {
          BackgroundQueueType.url => 'url',
          BackgroundQueueType.image => 'image',
          BackgroundQueueType.text => 'text',
        },
      };
}

class BackgroundQueuedWork {
  final String id;
  final String content;
  final BackgroundQueueType type;

  const BackgroundQueuedWork({
    required this.id,
    required this.content,
    required this.type,
  });

  factory BackgroundQueuedWork.fromMap(Map<dynamic, dynamic> map) {
    final type = switch (map['type'] as String?) {
      'url' => BackgroundQueueType.url,
      'image' => BackgroundQueueType.image,
      _ => BackgroundQueueType.text,
    };
    return BackgroundQueuedWork(
      id: map['id'] as String,
      content: map['content'] as String,
      type: type,
    );
  }
}

class BackgroundQueueService {
  static const _channel = MethodChannel('com.aimemo.aimemo/background_queue');

  Future<void> enqueueItems(List<BackgroundQueueItem> items) async {
    if (items.isEmpty) return;
    await _channel.invokeMethod<void>(
      'enqueueItems',
      items.map((item) => item.toMap()).toList(),
    );
  }

  Future<List<BackgroundQueuedWork>> getPendingItems() async {
    final rawItems = await _channel.invokeMethod<List<dynamic>>(
          'getPendingItems',
        ) ??
        const [];
    return rawItems
        .map((item) => BackgroundQueuedWork.fromMap(item as Map<dynamic, dynamic>))
        .toList();
  }

  Future<void> markComplete(String id) async {
    await _channel.invokeMethod<void>('markComplete', {'id': id});
  }

  Future<void> notifyComplete({
    required String title,
    required bool success,
    String? error,
  }) async {
    await _channel.invokeMethod<void>('notifyComplete', {
      'title': title,
      'success': success,
      if (error != null) 'error': error,
    });
  }

  Future<void> stopServiceIfIdle() async {
    await _channel.invokeMethod<void>('stopServiceIfIdle');
  }

  /// native(Android) SharedPreferences에 저장된 백그라운드 큐를
  /// 모두 비운다. 처리가 hang된 아이템이 UI에 무한히 남는 현상 방지.
  /// MainActivity, AimemoBackgroundService 양쪽 채널에 모두 구현되어 있어
  /// 어느 쪽이 받아도 동작한다.
  Future<void> clearAll() async {
    try {
      await _channel.invokeMethod<void>('clearAll');
    } on MissingPluginException {
      // 채널이 아직 연결되지 않았을 때 — 무시
    } catch (_) {}
  }

  /// 지정한 id의 아이템만 큐에서 제거한다.
  /// backgroundMain이 처리 중 hang되어 markComplete를 못 한 아이템을
  /// 앱 재시작 시 강제 제거할 때 사용한다.
  Future<void> removeById(String id) async {
    try {
      await _channel.invokeMethod<void>('removeById', {'id': id});
    } on MissingPluginException {
      // 무시
    } catch (_) {}
  }

  /// Get the number of pending items in the native queue.
  Future<int> pendingCount() async {
    try {
      final count = await _channel.invokeMethod<int>('pendingCount');
      return count ?? 0;
    } on MissingPluginException {
      return 0;
    } catch (e) {
      return 0;
    }
  }

  /// Run ML Kit OCR on the image at the given content URI.
  /// Returns the recognized text and local image path.
  /// If no text found, [text] is null but [localImagePath] may still be set.
  Future<({String? text, String? localImagePath})> performOcr(
      String imageUri) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'performOcr',
        {'imageUri': imageUri},
      );
      if (result == null) return (text: null, localImagePath: null);
      final hasText = result['hasText'] as bool? ?? false;
      final text = result['text'] as String? ?? '';
      final localImagePath = result['localPath'] as String?;
      return (
        text: hasText ? text : null,
        localImagePath: localImagePath,
      );
    } on MissingPluginException {
      return (text: null, localImagePath: null);
    } catch (e) {
      return (text: null, localImagePath: null);
    }
  }
}
