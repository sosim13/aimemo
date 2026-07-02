import '../models/memo.dart';
import '../models/chat_message.dart';
import 'category_detector.dart';
import 'database_service.dart';
import 'llm_service.dart';

/// Result from a chat Q&A
class ChatResult {
  final String answer;
  final List<Memo> referencedMemos;
  final bool hasMemoContext;

  ChatResult({
    required this.answer,
    required this.referencedMemos,
    this.hasMemoContext = false,
  });
}

/// Pair of a memo and its relevance score for ranked retrieval.
class _ScoredMemo {
  final Memo memo;
  final double score;
  const _ScoredMemo(this.memo, this.score);
}

/// Chat service with RAG (Retrieval-Augmented Generation) over memos.
///
/// For each user query:
/// 1. Searches memos for relevant content via keyword matching
/// 2. If memos found → builds a prompt with memo context + user question
/// 3. If no relevant memos → builds a simple general Q&A prompt
/// 4. Sends the prompt to the LLM and returns the answer
///
/// Also handles "save as memo" requests and maintains conversation history.
class ChatService {
  static final ChatService _instance = ChatService._internal();
  factory ChatService() => _instance;
  ChatService._internal();

  final _llmService = LlmService();
  final _databaseService = DatabaseService();

  /// Max memos to include as context in the prompt
  static const int _maxContextMemos = 5;

  /// Max content length per memo to avoid exceeding token limits
  static const int _maxMemoContentLength = 800;

  /// Common query stop words that carry no semantic meaning.
  /// These appear in user questions but shouldn't drive memo matching.
  static const _stopWords = <String>{
    '찾아줘', '찾아', '찾는', '찾을',
    '알려줘', '알려', '알려주', '알고',
    '해줘', '보여줘', '보여',
    '하는', '있는', '그거', '이거', '저거',
    '어떻게', '뭔지', '무엇', '어디', '뭐가',
    '있을까', '할까', '될까', '주라',
    '좀', '밖에', '대해', '관련', '통해',
    '싶어', '궁금', '줘',
    'please', 'help', 'find', 'show', 'tell',
    'search', 'look', 'need', 'want',
  };

  // ─── Persistent conversation state ───────────────────────────────

  /// Full conversation history — persists across screen navigation.
  final List<ChatMessage> messages = [];

  /// Whether the AI is currently generating a response.
  bool isGenerating = false;

  /// Callback invoked when state changes (so the UI can rebuild).
  void Function()? onStateChanged;

  void _notifyStateChanged() {
    onStateChanged?.call();
  }

  // ─── Save-memo patterns ──────────────────────────────────────────

  static final _saveMemoPattern = RegExp(
    r'메모로\s*(저장|추가|만들)|'
    r'저장해줘|'
    r'메모\s*(추가|작성|만들어)|'
    r'기록해줘|'
    r'메모해줘',
    caseSensitive: false,
  );

  /// Ask a question — may be a normal RAG query or a save-memo request.
  Future<void> ask(String query) async {
    if (isGenerating) return;

    // 1. Add user message to history
    messages.add(ChatMessage(text: query, isUser: true));
    isGenerating = true;
    _notifyStateChanged();

    try {
      final ChatResult result;

      if (_isSaveMemoRequest(query)) {
        result = await _handleSaveMemo(query);
      } else {
        result = await _handleRagQuery(query);
      }

      // 2. Add AI message to history
      messages.add(ChatMessage(
        text: result.answer,
        isUser: false,
        referencedMemos: result.hasMemoContext ? result.referencedMemos : null,
      ));
    } catch (e) {
      final errorText = e.toString().contains('취소')
          ? '⚠️ 응답이 취소되었습니다.'
          : '⚠️ 응답 생성 중 오류가 발생했습니다.\n\n$e';
      messages.add(ChatMessage(text: errorText, isUser: false));
    } finally {
      isGenerating = false;
      _notifyStateChanged();
    }
  }

  /// Cancel the currently running AI generation.
  void cancelGeneration() {
    if (!isGenerating) return;
    _llmService.cancel();
  }

  /// Start a new session — clear conversation history.
  void clearMessages() {
    messages.clear();
    _notifyStateChanged();
  }

  // ─── Save-memo flow ──────────────────────────────────────────────

  /// Check whether the user is asking to save a memo.
  bool _isSaveMemoRequest(String query) {
    return _saveMemoPattern.hasMatch(query);
  }

  /// Handle a save-memo request: extract content → insert directly → confirm.
  /// Saves raw content without AI summarization.
  Future<ChatResult> _handleSaveMemo(String query) async {
    final rawContent = _extractSaveContent(query);

    // Use first line as title (truncate if too long)
    final firstLine = rawContent.split('\n').first.trim();
    final title = firstLine.length > 30
        ? '${firstLine.substring(0, 30)}...'
        : (firstLine.isNotEmpty ? firstLine : '제목 없음');

    // Keyword-based category detection (no LLM needed)
    final detected = CategoryDetector.detect(rawContent);
    final category = (detected != null && detected != '기타') ? detected : '기타';

    final memo = Memo(
      title: title,
      content: rawContent,
      category: category,
    );
    final id = await _databaseService.insertMemo(memo);
    final savedMemo = memo.copyWith(id: id);

    final preview = rawContent.length > 200
        ? '${rawContent.substring(0, 200)}...'
        : rawContent;

    return ChatResult(
      answer: '✅ 메모가 저장되었습니다!\n\n'
          '📌 **$title**\n$preview\n\n'
          '카테고리: $category',
      referencedMemos: [savedMemo],
      hasMemoContext: true,
    );
  }

  /// Strip the save-memo command suffix/prefix from the query.
  String _extractSaveContent(String query) {
    // Remove common save-memo patterns from the end
    var content = query.replaceFirst(RegExp(
      r'\s*메모로\s*(저장해줘|추가해줘|만들어줘)',
      caseSensitive: false,
    ), '');
    content = content.replaceFirst(RegExp(
      r'\s*(저장해줘|메모해줘|기록해줘|메모\s*(추가|작성|만들어))',
      caseSensitive: false,
    ), '');
    // Also handle "X 메모 추가" (without ~해줘)
    content = content.replaceFirst(RegExp(
      r'\s*메모\s*(추가|작성|만들)',
      caseSensitive: false,
    ), '');
    return content.trim();
  }

  // ─── RAG query flow ──────────────────────────────────────────────

  /// Handle a normal RAG query (search + LLM).
  Future<ChatResult> _handleRagQuery(String query) async {
    final memos = await _searchMemos(query);

    final String prompt;
    final bool hasContext;

    if (memos.isNotEmpty) {
      prompt = _buildRagPrompt(query, memos);
      hasContext = true;
    } else {
      prompt = _buildGeneralPrompt(query);
      hasContext = false;
    }

    final answer = await _llmService.ask(prompt: prompt);

    return ChatResult(
      answer: answer,
      referencedMemos: memos,
      hasMemoContext: hasContext,
    );
  }

  /// Search memos with relevance scoring.
  Future<List<Memo>> _searchMemos(String query) async {
    final meaningfulKeywords = _extractMeaningfulKeywords(query);

    if (meaningfulKeywords.isEmpty) {
      return (await _databaseService.searchMemos(query))
          .take(_maxContextMemos)
          .toList();
    }

    final seen = <int>{};
    final scored = <_ScoredMemo>[];

    double scoreMemo(Memo memo) {
      double score = 0;
      final lowerTitle = memo.title.toLowerCase();
      final lowerContent = memo.content.toLowerCase();
      for (final kw in meaningfulKeywords) {
        final lowerKw = kw.toLowerCase();
        if (lowerTitle.contains(lowerKw)) {
          score += 2.0;
        } else if (lowerContent.contains(lowerKw)) {
          score += 1.0;
        } else if (memo.category.contains(kw)) {
          score += 0.5;
        }
      }
      if (lowerTitle.contains(query.toLowerCase())) {
        score += 1.0;
      }
      return score;
    }

    final directResults = await _databaseService.searchMemos(query);
    for (final memo in directResults) {
      if (seen.add(memo.id!)) {
        scored.add(_ScoredMemo(memo, scoreMemo(memo)));
      }
    }

    for (final keyword in meaningfulKeywords) {
      if (seen.length >= _maxContextMemos * 2) break;
      final keywordResults = await _databaseService.searchMemos(keyword);
      for (final memo in keywordResults) {
        if (seen.add(memo.id!)) {
          scored.add(_ScoredMemo(memo, scoreMemo(memo)));
        }
      }
    }

    final minScore = meaningfulKeywords.length >= 2 ? 2.0 : 1.0;
    scored.sort((a, b) => b.score.compareTo(a.score));

    return scored
        .where((sm) => sm.score >= minScore)
        .take(_maxContextMemos)
        .map((sm) => sm.memo)
        .toList();
  }

  /// Extract meaningful keywords from a query, removing stop words.
  List<String> _extractMeaningfulKeywords(String query) {
    final tokens = query.split(RegExp(r'[\s,，、.。!！?？/]+'));
    return tokens
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty && t.length >= 2 && !_stopWords.contains(t))
        .toList();
  }

  /// Build a RAG prompt with memo context.
  String _buildRagPrompt(String query, List<Memo> memos) {
    final buf = StringBuffer();

    buf.writeln('You are a helpful assistant with access to the user\'s memo database.');
    buf.writeln('Answer the user\'s question based on the relevant memos below.');
    buf.writeln('If the memos contain the answer, provide it clearly and informatively.');
    buf.writeln('If the memos are not fully relevant, use your own knowledge to supplement.');
    buf.writeln('');
    buf.writeln('--- Relevant Memos ---');

    for (int i = 0; i < memos.length; i++) {
      final memo = memos[i];
      final content = memo.content.length > _maxMemoContentLength
          ? '${memo.content.substring(0, _maxMemoContentLength)}...'
          : memo.content;
      buf.writeln('[Memo ${i + 1}]');
      buf.writeln('Title: ${memo.title}');
      buf.writeln('Category: ${memo.category}');
      buf.writeln('Content: $content');
      buf.writeln('');
    }

    buf.writeln('---');
    buf.writeln('');
    buf.writeln('User: $query');
    buf.writeln('Assistant:');

    return buf.toString();
  }

  /// Build a general Q&A prompt (no memo context).
  String _buildGeneralPrompt(String query) {
    return '''
You are a helpful Korean-speaking AI assistant. Answer the user's question politely and informatively.
Be concise but thorough. If you don't know the answer, say so honestly.

User: $query
Assistant:''';
  }
}
