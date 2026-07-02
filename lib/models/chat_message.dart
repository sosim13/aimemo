import 'memo.dart';

/// A single message in the chatbot conversation.
class ChatMessage {
  final String text;
  final bool isUser;
  final List<Memo>? referencedMemos;
  final DateTime timestamp;

  /// Whether this message represents a newly saved memo confirmation.
  final bool isSaveMemo;

  /// If this is a save-memo confirmation, the saved memo.
  final Memo? savedMemo;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.referencedMemos,
    DateTime? timestamp,
    this.isSaveMemo = false,
    this.savedMemo,
  }) : timestamp = timestamp ?? DateTime.now();
}
