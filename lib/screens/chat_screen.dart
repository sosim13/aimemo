import 'dart:async';
import 'package:flutter/material.dart';
import '../models/memo.dart';
import '../models/chat_message.dart';
import '../services/chat_service.dart';
import '../services/llm_service.dart';
import 'memo_detail_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _chatService = ChatService();
  final _llmService = LlmService();
  final _textController = TextEditingController();
  final _scrollController = ScrollController();

  bool _isAiAvailable = false;
  DateTime? _generationStartTime;
  int _elapsedSeconds = 0;
  Timer? _elapsedTimer;

  @override
  void initState() {
    super.initState();
    _checkAiAvailable();
    _chatService.onStateChanged = _onChatStateChanged;
    // Show welcome message only on first visit
    if (_chatService.messages.isEmpty) {
      _addWelcomeMessage();
    }
  }

  @override
  void dispose() {
    _elapsedTimer?.cancel();
    _chatService.onStateChanged = null;
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onChatStateChanged() {
    if (mounted) {
      setState(() {
        if (_chatService.isGenerating && _generationStartTime == null) {
          // Generation just started — begin timing
          _generationStartTime = DateTime.now();
          _elapsedSeconds = 0;
          _startElapsedTimer();
        } else if (!_chatService.isGenerating && _generationStartTime != null) {
          // Generation just finished — record elapsed time
          _elapsedSeconds = DateTime.now().difference(_generationStartTime!).inSeconds;
          _stopElapsedTimer();
          _generationStartTime = null;
        }
      });
      _scrollToBottom();
    }
  }

  Future<void> _checkAiAvailable() async {
    final available = await _llmService.isAvailable();
    if (mounted) {
      setState(() => _isAiAvailable = available);
    }
  }

  void _addWelcomeMessage() {
    _chatService.messages.add(ChatMessage(
      text: '안녕하세요! Aimemo Assistant입니다.\n\n'
          '저장된 메모를 바탕으로 질문에 답변해드립니다.\n\n'
          '💡 예시 질문:\n'
          '• "청약 신청하는 방법 알려줘"\n'
          '• "당근이랑 토마토로 할 수 있는 요리 추천해줘"\n'
          '• "Python으로 웹 서버 만드는 방법"\n'
          '• "아버지가 가방에 들어가신다 메모로 저장해줘"\n\n'
          '메모가 관련 있으면 자동으로 찾아서 답변에 활용해요!',
      isUser: false,
    ));
  }

  Future<void> _sendMessage(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _chatService.isGenerating) return;

    if (!_isAiAvailable) {
      _showSnackBar('❌ AI 모델이 준비되지 않았습니다.\n설정에서 모델을 다운로드해주세요.');
      return;
    }

    _textController.clear();

    // Remove welcome message when user starts their first real query
    if (_chatService.messages.length == 1 &&
        _chatService.messages.first.text.startsWith('안녕하세요! Aimemo Assistant입니다.')) {
      _chatService.messages.clear();
    }

    await _chatService.ask(trimmed);
    // State updates happen via onStateChanged callback
  }

  void _startNewSession() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('새 세션'),
        content: const Text('대화를 초기화하고 새 세션을 시작하시겠습니까?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('새 세션'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      _chatService.clearMessages();
      _addWelcomeMessage();
      setState(() {});
    }
  }

  void _cancelGeneration() {
    _chatService.cancelGeneration();
  }

  void _startElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _chatService.isGenerating && _generationStartTime != null) {
        setState(() {
          _elapsedSeconds = DateTime.now().difference(_generationStartTime!).inSeconds;
        });
      }
    });
  }

  void _stopElapsedTimer() {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _openMemoDetail(Memo memo) {
    if (memo.id == null) {
      _showSnackBar('메모 ID가 유효하지 않습니다.');
      return;
    }
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MemoDetailScreen(memoId: memo.id!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 챗봇'),
        backgroundColor: theme.colorScheme.inversePrimary,
        actions: [
          // Cancel generation button
          if (_chatService.isGenerating)
            IconButton(
              icon: const Icon(Icons.stop_circle_outlined, color: Colors.red),
              tooltip: '응답 중단',
              onPressed: _cancelGeneration,
            ),
          // AI availability warning
          if (!_isAiAvailable)
            IconButton(
              icon: Icon(Icons.warning_amber_rounded, color: Colors.orange[700]),
              tooltip: 'AI 모델 연결 필요',
              onPressed: () {},
            ),
          // New session button
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '새 세션',
            onPressed: _startNewSession,
          ),
        ],
      ),
      body: Column(
        children: [
          // Messages list
          Expanded(
            child: _chatService.messages.isEmpty
                ? const Center(child: Text('메시지가 없습니다.'))
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(
                      left: 12,
                      right: 12,
                      top: 8,
                      bottom: 8,
                    ),
                    itemCount: _chatService.messages.length +
                        (_chatService.isGenerating ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (_chatService.isGenerating &&
                          index == _chatService.messages.length) {
                        return _buildTypingIndicator();
                      }
                      final message = _chatService.messages[index];
                      return _buildMessageBubble(message, theme);
                    },
                  ),
          ),

          // Input bar
          _buildInputBar(theme),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment:
            message.isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Sender label
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              message.isUser ? '나' : 'Aimemo AI',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: message.isUser
                    ? theme.colorScheme.primary
                    : Colors.grey[600],
              ),
            ),
          ),

          // Bubble
          Row(
            mainAxisAlignment:
                message.isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!message.isUser) const SizedBox(width: 4),
              Flexible(
                child: Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.75,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: message.isUser
                        ? theme.colorScheme.primaryContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.only(
                      topLeft: const Radius.circular(20),
                      topRight: const Radius.circular(20),
                      bottomLeft: message.isUser
                          ? const Radius.circular(20)
                          : const Radius.circular(4),
                      bottomRight: message.isUser
                          ? const Radius.circular(4)
                          : const Radius.circular(20),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Message text
                      SelectableText(
                        message.text,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.5,
                          color: message.isUser
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),

                      // Memo references (AI messages only)
                      if (!message.isUser &&
                          message.referencedMemos != null &&
                          message.referencedMemos!.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        const Divider(height: 1),
                        const SizedBox(height: 8),
                        Text(
                          '📎 참조한 메모',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600],
                          ),
                        ),
                        const SizedBox(height: 4),
                        ...message.referencedMemos!.map(
                          (memo) => _buildMemoRefChip(memo, theme),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (message.isUser) const SizedBox(width: 4),
            ],
          ),

          // Timestamp (show elapsed time for AI responses)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              !message.isUser
                  ? _formatAiElapsed(message, _chatService.messages)
                  : _formatTime(message.timestamp),
              style: TextStyle(
                fontSize: 10,
                color: Colors.grey[400],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMemoRefChip(Memo memo, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: InkWell(
        onTap: () => _openMemoDetail(memo),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.article_outlined,
                  size: 14, color: theme.colorScheme.secondary),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  memo.title,
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Icon(Icons.open_in_new, size: 12, color: Colors.grey[500]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Text(
              'Aimemo AI',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey[600],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(4),
                topRight: const Radius.circular(20),
                bottomLeft: const Radius.circular(20),
                bottomRight: const Radius.circular(20),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_formatDuration(_elapsedSeconds)} 생각 중...',
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(ThemeData theme) {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
        top: 8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: Colors.grey[200]!),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
              textInputAction: TextInputAction.send,
              maxLines: 5,
              minLines: 1,
              decoration: InputDecoration(
                hintText: '메모에 대해 질문해보세요...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                isDense: true,
              ),
              onSubmitted: (value) => _sendMessage(value),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            child: IconButton.filled(
              onPressed: _chatService.isGenerating
                  ? null
                  : () => _sendMessage(_textController.text),
              icon: _chatService.isGenerating
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded),
              tooltip: '전송',
              style: IconButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                disabledBackgroundColor: Colors.grey[300],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Format elapsed time for AI responses: find the preceding user message
  /// and compute the generation duration.
  String _formatAiElapsed(ChatMessage message, List<ChatMessage> allMessages) {
    final msgIndex = allMessages.indexOf(message);
    if (msgIndex <= 0) return '';
    final prevMsg = allMessages[msgIndex - 1];
    if (!prevMsg.isUser) return '';
    final elapsedSec = message.timestamp.difference(prevMsg.timestamp).inSeconds;
    if (elapsedSec < 1) return '';
    return '⏱ ${_formatDuration(elapsedSec)}';
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);

    if (diff.inMinutes < 1) return '방금 전';
    if (diff.inHours < 1) return '${diff.inMinutes}분 전';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }
}
