import 'package:flutter/services.dart';

enum BackgroundQueueType { url, text }

class BackgroundQueueItem {
  final String content;
  final BackgroundQueueType type;

  const BackgroundQueueItem({
    required this.content,
    required this.type,
  });

  Map<String, Object> toMap() => {
        'content': content,
        'type': type == BackgroundQueueType.url ? 'url' : 'text',
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
    final type = map['type'] == 'url'
        ? BackgroundQueueType.url
        : BackgroundQueueType.text;
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
}
