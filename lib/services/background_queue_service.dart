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

  /// Run ML Kit OCR on the image at the given content URI.
  /// Returns the recognized text, or null if no text found.
  Future<String?> performOcr(String imageUri) async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'performOcr',
        {'imageUri': imageUri},
      );
      if (result == null) return null;
      final hasText = result['hasText'] as bool? ?? false;
      final text = result['text'] as String? ?? '';
      return hasText ? text : null;
    } on MissingPluginException {
      return null;
    } catch (e) {
      return null;
    }
  }
}
