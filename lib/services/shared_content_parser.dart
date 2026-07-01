import 'background_queue_service.dart';

class SharedContentParser {
  static final _urlPattern = RegExp(
    r'''https?://[^\s<>"']+''',
    caseSensitive: false,
  );

  static List<BackgroundQueueItem> parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const [];

    final urls = _urlPattern
        .allMatches(trimmed)
        .map((match) => match.group(0)!)
        .map(_trimUrlPunctuation)
        .where((url) => url.isNotEmpty)
        .toSet()
        .toList();

    if (urls.isNotEmpty) {
      return urls
          .map((url) => BackgroundQueueItem(
                content: url,
                type: BackgroundQueueType.url,
              ))
          .toList();
    }

    return [
      BackgroundQueueItem(
        content: trimmed,
        type: BackgroundQueueType.text,
      ),
    ];
  }

  static String _trimUrlPunctuation(String url) {
    var value = url;
    while (value.isNotEmpty && '.,);]}>'.contains(value[value.length - 1])) {
      value = value.substring(0, value.length - 1);
    }
    return value;
  }
}
