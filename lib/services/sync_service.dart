import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/book.dart';
import '../models/memo.dart';
import 'database_service.dart';
import 'thumbnail_sync_service.dart';

/// Supabase 기반 책 데이터 동기화 서비스.
///
/// 동기화 원칙:
/// - 로컬 DB가 Single Source of Truth. Supabase는 백업/복원 용도.
/// - 동기화 조건: Supabase Auth 세션이 있고 provider가 google인 경우에만 동작.
///   비로그인/익명 사용자면 로컬에만 저장하고 Supabase 호출 금지.
/// - Push: 로컬 먼저 저장 → 1초 debounce 후 supabase upsert (백그라운드).
///   실패 시 sync_queue에 저장.
/// - Pull: (1) 로그인 직후, (2) AppLifecycleState.resumed 시.
///   remote의 deleted_at이 null인 것만 조회.
/// - 충돌: updated_at 기반 last-write-wins.
/// - 썸네일: 저장 시 image 패키지로 800px 리사이즈 + webp 압축 → Storage 업로드 →
///   publicUrl을 thumbnail_url로 저장. 로드 시 thumbnail_url 있고 로컬 없으면
///   백그라운드 다운로드.
///
/// 모든 로그는 debugPrint로만 출력.
class SyncService {
  static final SyncService _instance = SyncService._internal();
  factory SyncService() => _instance;
  SyncService._internal();

  final _db = DatabaseService();
  ThumbnailSyncService? _thumbnail;

  /// Supabase 클라이언트 — 지연 초기화.
  ///
  /// 백그라운드 isolate(main.dart의 backgroundMain)에서는 `Supabase.initialize()`가
  /// 호출되지 않으므로, 생성 시점에 `Supabase.instance`에 접근하면 크래시한다.
  /// (supabase_flutter는 미초기화 시 AssertionError/NoSuchMethodError를 던진다.)
  /// 따라서 사용 시점에 최초 1회만 접근하고, 초기화되지 않은 환경에서는 null을
  /// 반환하여 동기화를 조용히 건너뛴다.
  SupabaseClient? _client;

  SupabaseClient? get _clientOrNull {
    if (_client != null) return _client;
    try {
      _client = Supabase.instance.client;
    } catch (_) {
      // Supabase 미초기화 (백그라운드 isolate 등) — 동기화 비활성으로 진행
      _client = null;
    }
    return _client;
  }

  /// 썸네일 서비스 — 지연 생성.
  /// ThumbnailSyncService 생성자도 Supabase.instance에 접근하므로,
  /// 동기화가 실제로 가능한 시점에만 생성한다.
  ThumbnailSyncService get _thumbnailService =>
      _thumbnail ??= ThumbnailSyncService();

  /// debouncing용 타이머 맵 (bookId → Timer)
  final Map<String, Timer> _debounceTimers = {};

  /// 메모용 debouncing 타이머 맵 (memoId → Timer)
  final Map<String, Timer> _memoDebounceTimers = {};

  /// 동기화 가능 여부: 현재 사용자가 Supabase Auth 세션을 가지고 있고
  /// provider가 google인지 확인. 비로그인/익명이면 false.
  ///
  /// Supabase 미초기화 환경(백그라운드 isolate 등)에서는 예외 없이 false 반환.
  bool get _canSync {
    try {
      final client = _clientOrNull;
      if (client == null) {
        return false;
      }
      final user = client.auth.currentUser;
      if (user == null) {
        return false;
      }
      // provider 확인 — appMetadata에서 'provider' 값이 'google'인지 검사
      final provider = user.appMetadata['provider'];
      return provider == 'google';
    } catch (_) {
      return false;
    }
  }

  /// 현재 로그인 사용자의 uid.
  /// Supabase 미초기화/미로그인 시 null.
  String? get _currentUserId {
    try {
      return _clientOrNull?.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Push (로컬 → 원격)
  // ---------------------------------------------------------------------------

  /// 단일 책을 Supabase에 upsert.
  /// thumbnail_url이 없으면 썸네일 업로드 시도 후 포함.
  /// 실패 시 sync_queue에 저장.
  Future<void> pushBook(Book book) async {
    if (!_canSync) {
      debugPrint('[SyncService] 동기화 불가 (비로그인/익명) — push 생략: ${book.bookId}');
      return;
    }

    final uid = _currentUserId!;
    try {
      // thumbnail_url이 없고 로컬 파일이 있으면 업로드 시도
      String? thumbnailUrl = book.thumbnailUrl;
      if (thumbnailUrl == null && book.coverThumbnailPath.isNotEmpty) {
        thumbnailUrl = await _thumbnailService.uploadThumbnail(book, uid);
      }

      // upsert용 데이터 맵 (snake_case — Supabase 스키마와 일치)
      final now = DateTime.now().toUtc().toIso8601String();
      final data = {
        'book_id': book.bookId,
        'user_id': uid,
        'title': book.title,
        'author': book.author,
        'cover_thumbnail_path': book.coverThumbnailPath,
        'thumbnail_url': thumbnailUrl,
        'category': book.category,
        'total_read_count': book.totalReadCount,
        'updated_at': book.updatedAt?.toUtc().toIso8601String() ?? now,
      };

      await _clientOrNull!.from('books').upsert(data, onConflict: 'book_id');
      debugPrint('[SyncService] push 성공: ${book.bookId}');
    } catch (e) {
      debugPrint('[SyncService] push 실패, 큐에 저장: ${book.bookId} — $e');
      // sync_queue에 저장하여 나중에 재시도
      await _db.insertSyncQueue(book.bookId, 'upsert');
    }
  }

  /// 책 삭제를 Supabase에 반영 (soft delete — deletedAt 업데이트).
  Future<void> pushDelete(String bookId) async {
    if (!_canSync) {
      debugPrint('[SyncService] 동기화 불가 (비로그인/익명) — delete 생략: $bookId');
      return;
    }

    final uid = _currentUserId!;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _clientOrNull!
          .from('books')
          .update({'deleted_at': now, 'updated_at': now})
          .eq('book_id', bookId)
          .eq('user_id', uid);
      debugPrint('[SyncService] delete push 성공: $bookId');
    } catch (e) {
      debugPrint('[SyncService] delete push 실패, 큐에 저장: $bookId — $e');
      await _db.insertSyncQueue(bookId, 'delete');
    }
  }

  /// 1초 debounce 후 pushBook 호출.
  /// 연속된 업데이트(예: totalReadCount 증가)에 대해 과도한 API 호출 방지.
  void debouncePush(Book book) {
    if (!_canSync) return;

    // 기존 타이머가 있으면 취소
    final existing = _debounceTimers[book.bookId];
    existing?.cancel();

    // 1초 후 pushBook 실행
    _debounceTimers[book.bookId] = Timer(const Duration(seconds: 1), () {
      _debounceTimers.remove(book.bookId);
      pushBook(book).catchError((e) {
        debugPrint('[SyncService] debouncePush 오류: ${book.bookId} — $e');
      });
    });
    debugPrint('[SyncService] debouncePush 예약: ${book.bookId}');
  }

  // ---------------------------------------------------------------------------
  // Push (로컬 → 원격) — 메모
  // ---------------------------------------------------------------------------

  /// 단일 메모를 Supabase에 upsert.
  /// createdAt/updatedAt은 마지막 로컬 값 유지. soft delete는 deletedAt으로 표현.
  Future<void> pushMemo(Memo memo) async {
    if (!_canSync) {
      debugPrint(
        '[SyncService] 동기화 불가 (비로그인/익명) — pushMemo 생략: ${memo.memoId}',
      );
      return;
    }
    if (memo.memoId.isEmpty) {
      debugPrint('[SyncService] pushMemo — memoId 없음, skip');
      return;
    }

    final uid = _currentUserId!;
    try {
      final data = {
        'memo_id': memo.memoId,
        'user_id': uid,
        'title': memo.title,
        'content': memo.content,
        'category': memo.category,
        'source_url': memo.sourceUrl,
        'youtube_video_id': memo.youtubeVideoId,
        'thumbnail_url': memo.thumbnailUrl,
        'image_path': memo.imagePath,
        'address': memo.address,
        'search_keyword': memo.searchKeyword,
        'kakao_lat': memo.kakaoLat,
        'kakao_lng': memo.kakaoLng,
        'naver_x': memo.naverX,
        'naver_y': memo.naverY,
        'created_at': memo.createdAt.toUtc().toIso8601String(),
        'updated_at': memo.updatedAt.toUtc().toIso8601String(),
        'deleted_at': memo.deletedAt?.toUtc().toIso8601String(),
      };

      await _clientOrNull!.from('memos').upsert(data, onConflict: 'memo_id');
      debugPrint('[SyncService] pushMemo 성공: ${memo.memoId}');
    } catch (e) {
      debugPrint('[SyncService] pushMemo 실패, 큐에 저장: ${memo.memoId} — $e');
      await _db.insertSyncQueue(
        memo.memoId,
        'upsert',
        entityType: 'memo',
        entityId: memo.memoId,
      );
    }
  }

  /// 메모 삭제를 Supabase에 반영 (soft delete).
  Future<void> pushMemoDelete(String memoId) async {
    if (!_canSync) {
      debugPrint('[SyncService] 동기화 불가 — pushMemoDelete 생략: $memoId');
      return;
    }
    if (memoId.isEmpty) return;

    final uid = _currentUserId!;
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      await _clientOrNull!
          .from('memos')
          .update({'deleted_at': now, 'updated_at': now})
          .eq('memo_id', memoId)
          .eq('user_id', uid);
      debugPrint('[SyncService] pushMemoDelete 성공: $memoId');
    } catch (e) {
      debugPrint('[SyncService] pushMemoDelete 실패, 큐에 저장: $memoId — $e');
      await _db.insertSyncQueue(
        memoId,
        'delete',
        entityType: 'memo',
        entityId: memoId,
      );
    }
  }

  /// 1초 debounce 후 pushMemo 호출.
  void debouncePushMemo(Memo memo) {
    if (!_canSync) return;
    if (memo.memoId.isEmpty) return;

    final existing = _memoDebounceTimers[memo.memoId];
    existing?.cancel();

    _memoDebounceTimers[memo.memoId] = Timer(const Duration(seconds: 1), () {
      _memoDebounceTimers.remove(memo.memoId);
      pushMemo(memo).catchError((e) {
        debugPrint('[SyncService] debouncePushMemo 오류: ${memo.memoId} — $e');
      });
    });
    debugPrint('[SyncService] debouncePushMemo 예약: ${memo.memoId}');
  }

  // ---------------------------------------------------------------------------
  // Pull (원격 → 로컬)
  // ---------------------------------------------------------------------------

  /// 원격에서 현재 사용자의 책 목록을 조회.
  /// deleted_at이 null인 활성 책만 가져옴.
  Future<List<Map<String, dynamic>>> pullBooks() async {
    if (!_canSync) {
      debugPrint('[SyncService] 동기화 불가 (비로그인/익명) — pull 생략');
      return [];
    }

    final uid = _currentUserId!;
    try {
      final response = await _clientOrNull!
          .from('books')
          .select()
          .eq('user_id', uid)
          .filter('deleted_at', 'is', null);
      debugPrint('[SyncService] pull 조회: ${response.length}건');
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('[SyncService] pull 실패: $e');
      return [];
    }
  }

  /// 원격에서 현재 사용자의 메모 목록을 조회.
  /// deleted_at이 null인 활성 메모만 가져옴.
  Future<List<Map<String, dynamic>>> pullMemos() async {
    if (!_canSync) {
      debugPrint('[SyncService] 동기화 불가 — pullMemos 생략');
      return [];
    }

    final uid = _currentUserId!;
    try {
      final response = await _clientOrNull!
          .from('memos')
          .select()
          .eq('user_id', uid)
          .filter('deleted_at', 'is', null);
      debugPrint('[SyncService] pullMemos 조회: ${response.length}건');
      return List<Map<String, dynamic>>.from(response);
    } catch (e) {
      debugPrint('[SyncService] pullMemos 실패: $e');
      return [];
    }
  }

  /// Supabase에서 풀 + 충돌 해결 + 로컬 DB 업데이트.
  ///
  /// 충돌 해결: updated_at 기반 last-write-wins.
  /// - remote가 더 최신이면 로컬 덮어쓰기.
  /// - 로컬이 더 최신이면 push.
  /// - 로컬에 없는 remote 책이면 로컬에 추가.
  Future<void> pullFromSupabase() async {
    if (!_canSync) {
      debugPrint('[SyncService] 동기화 불가 (비로그인/익명) — pullFromSupabase 생략');
      return;
    }

    debugPrint('[SyncService] pullFromSupabase 시작');

    // 로컬이 Single Source of Truth이므로, pull이 로컬을 덮어쓰기 전에
    // 로컬 변경사항을 먼저 원격에 반영한다.
    // (트리거 제거 후 클라이언트 updated_at이 존중되므로, push 후 pull에서는
    //  동일한 내용 + 동일한 updated_at이 유지되어 로컬이 보존된다.)
    await pushAllLocalMemos();
    await _pushAllLocalBooks();

    final remoteBooks = await pullBooks();
    if (remoteBooks.isEmpty) {
      debugPrint('[SyncService] 원격에 책 없음 — pull 종료');
      return;
    }

    final uid = _currentUserId!;

    // 각 remote 책에 대해 충돌 해결
    for (final remoteRow in remoteBooks) {
      final remoteBookId = remoteRow['book_id'] as String;
      final remoteUpdatedAtStr = remoteRow['updated_at'] as String?;
      // DateTime.isAfter는 내부 UTC 인스턴스 기준 비교이므로
      // 로컬(로컬 시간대, Z 없음)과 remote(UTC, Z 포함)의 표기가 달라도 올바르다.
      final remoteUpdatedAt =
          remoteUpdatedAtStr != null
              ? DateTime.tryParse(remoteUpdatedAtStr)
              : null;

      // 로컬 책 조회
      final localBook = await _db.getBookById(remoteBookId);

      if (localBook == null) {
        // 로컬에 없는 remote 책 → 로컬에 추가
        await _upsertLocalFromRemote(remoteRow, uid);
        debugPrint('[SyncService] 로컬에 추가: $remoteBookId');
      } else {
        // 충돌 해결: updated_at 비교
        final localUpdatedAt = localBook.updatedAt;

        if (remoteUpdatedAt != null &&
            (localUpdatedAt == null ||
                remoteUpdatedAt.isAfter(localUpdatedAt))) {
          // remote가 더 최신 → 로컬 덮어쓰기
          await _upsertLocalFromRemote(remoteRow, uid);
          debugPrint('[SyncService] remote 우선 → 로컬 덮어쓰기: $remoteBookId');
        } else {
          // 로컬이 더 최신 → push
          await pushBook(localBook);
          debugPrint('[SyncService] 로컬 우선 → push: $remoteBookId');
        }
      }
    }

    debugPrint('[SyncService] pullFromSupabase 완료 (책)');

    // --- 메모 pull ---
    await _pullMemosFromSupabase(uid);
    debugPrint('[SyncService] pullFromSupabase 완료 (메모)');
  }

  /// Supabase에서 메모를 풀 + 충돌 해결 + 로컬 DB 업데이트.
  Future<void> _pullMemosFromSupabase(String uid) async {
    final remoteMemos = await pullMemos();
    if (remoteMemos.isEmpty) {
      debugPrint('[SyncService] 원격에 메모 없음 — pull 종료');
      return;
    }

    for (final remoteRow in remoteMemos) {
      final remoteMemoId = remoteRow['memo_id'] as String?;
      if (remoteMemoId == null || remoteMemoId.isEmpty) continue;

      final remoteUpdatedAtStr = remoteRow['updated_at'] as String?;
      final remoteUpdatedAt =
          remoteUpdatedAtStr != null
              ? DateTime.tryParse(remoteUpdatedAtStr)?.toLocal()
              : null;

      final localMemo = await _db.getMemoByMemoId(remoteMemoId);

      if (localMemo == null) {
        // 로컬에 없는 remote 메모 → 로컬에 추가
        await _upsertLocalMemoFromRemote(remoteRow, uid);
        debugPrint('[SyncService] 로컬에 메모 추가: $remoteMemoId');
      } else {
        // 충돌 해결: updated_at 기반 last-write-wins.
        // remote가 더 최신일 때만 로컬을 덮어쓰고, 그 외(동일/로컬 최신)에는
        // 로컬 우선 push. pullFromSupabase가 pull 전 로컬 push를 먼저 수행하므로
        // 정상 흐름에서는 로컬 내용이 보존된다.
        final localUpdatedAt = localMemo.updatedAt;
        if (remoteUpdatedAt != null &&
            remoteUpdatedAt.isAfter(localUpdatedAt)) {
          // remote가 더 최신 → 로컬 덮어쓰기
          await _upsertLocalMemoFromRemote(remoteRow, uid, existing: localMemo);
          debugPrint('[SyncService] remote 우선 → 로컬 메모 덮어쓰기: $remoteMemoId');
        } else {
          // 로컬이 더 최신 → push
          await pushMemo(localMemo);
          debugPrint('[SyncService] 로컬 우선 → pushMemo: $remoteMemoId');
        }
      }
    }
  }

  /// remote 메모 행을 로컬 DB에 upsert.
  /// [existing]이 있으면 기존 int id를 유지 (AUTOINCREMENT PK 보존).
  Future<void> _upsertLocalMemoFromRemote(
    Map<String, dynamic> remoteRow,
    String userId, {
    Memo? existing,
  }) async {
    final memo = Memo(
      id: existing?.id,
      memoId: remoteRow['memo_id'] as String,
      title: (remoteRow['title'] as String?) ?? '',
      content: (remoteRow['content'] as String?) ?? '',
      category: (remoteRow['category'] as String?) ?? '',
      sourceUrl: _parseNullable(remoteRow['source_url']),
      youtubeVideoId: _parseNullable(remoteRow['youtube_video_id']),
      thumbnailUrl: _parseNullable(remoteRow['thumbnail_url']),
      imagePath: _parseNullable(remoteRow['image_path']),
      address: _parseNullable(remoteRow['address']),
      searchKeyword: _parseNullable(remoteRow['search_keyword']),
      kakaoLat: (remoteRow['kakao_lat'] as num?)?.toDouble(),
      kakaoLng: (remoteRow['kakao_lng'] as num?)?.toDouble(),
      naverX: (remoteRow['naver_x'] as num?)?.toDouble(),
      naverY: (remoteRow['naver_y'] as num?)?.toDouble(),
      createdAt:
          _parseDate(remoteRow['created_at'])?.toLocal() ?? DateTime.now(),
      updatedAt:
          _parseDate(remoteRow['updated_at'])?.toLocal() ?? DateTime.now(),
      userId: userId,
      deletedAt: _parseDate(remoteRow['deleted_at'])?.toLocal(),
    );

    await _db.insertMemo(memo);
  }

  /// remote 행(row)을 로컬 DB에 upsert.
  /// snake_case → camelCase 매핑 + 안전 파싱.
  Future<void> _upsertLocalFromRemote(
    Map<String, dynamic> remoteRow,
    String userId,
  ) async {
    final book = Book(
      bookId: remoteRow['book_id'] as String,
      title: remoteRow['title'] as String? ?? '',
      author: (remoteRow['author'] as String?) ?? '',
      coverThumbnailPath: (remoteRow['cover_thumbnail_path'] as String?) ?? '',
      category: (remoteRow['category'] as String?) ?? '독서',
      totalReadCount: (remoteRow['total_read_count'] as int?) ?? 0,
      thumbnailUrl: _parseNullable(remoteRow['thumbnail_url']),
      userId: userId,
      updatedAt: _parseDate(remoteRow['updated_at']),
      deletedAt: _parseDate(remoteRow['deleted_at']),
    );

    // 로컬에 upsert (ConflictAlgorithm.replace)
    await _db.insertBook(book);

    // thumbnail_url이 있고 로컬 파일이 없으면 백그라운드 다운로드
    if (book.thumbnailUrl != null && book.coverThumbnailPath.isEmpty) {
      // 백그라운드에서 다운로드 (완료 대기 안 함)
      _thumbnailService
          .downloadThumbnail(book)
          .then((localPath) {
            if (localPath != null) {
              // 다운로드 완료 후 로컬 coverThumbnailPath 업데이트
              _db.updateBook(book.copyWith(coverThumbnailPath: localPath));
              debugPrint('[SyncService] 썸네일 다운로드 후 로컬 경로 업데이트: ${book.bookId}');
            }
          })
          .catchError((e) {
            debugPrint('[SyncService] 썸네일 다운로드 실패: ${book.bookId} — $e');
          });
    }
  }

  // ---------------------------------------------------------------------------
  // 전체 Push (로컬 → 원격) — 로그인 직후 로컬 백업
  // ---------------------------------------------------------------------------

  /// 로컬에 있는 모든 메모를 Supabase에 push (백업/초기 업로드).
  /// 로그인 직후 또는 pull 전에 호출하여 로컬 데이터를 원격에 반영.
  Future<void> pushAllLocalMemos() async {
    if (!_canSync) return;

    try {
      final memos = await _db.getAllMemos();
      debugPrint('[SyncService] pushAllLocalMemos: ${memos.length}건');
      for (final memo in memos) {
        if (memo.memoId.isEmpty) continue;
        await pushMemo(memo);
      }
      debugPrint('[SyncService] pushAllLocalMemos 완료');
    } catch (e) {
      debugPrint('[SyncService] pushAllLocalMemos 실패: $e');
    }
  }

  /// 로컬에 있는 모든 책을 Supabase에 push (백업/초기 업로드).
  /// pull이 로컬을 덮어쓰기 전에 로컬 데이터를 원격에 반영하기 위해 사용.
  Future<void> _pushAllLocalBooks() async {
    if (!_canSync) return;

    try {
      final books = await _db.getAllBooks();
      debugPrint('[SyncService] _pushAllLocalBooks: ${books.length}건');
      for (final book in books) {
        await pushBook(book);
      }
      debugPrint('[SyncService] _pushAllLocalBooks 완료');
    } catch (e) {
      debugPrint('[SyncService] _pushAllLocalBooks 실패: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Sync Queue 재시도
  // ---------------------------------------------------------------------------

  /// sync_queue에 쌓인 항목을 재시도.
  /// 네트워크 복구 후 또는 앱 재시작 시 호출.
  Future<void> processSyncQueue() async {
    if (!_canSync) {
      debugPrint('[SyncService] 동기화 불가 — processSyncQueue 생략');
      return;
    }

    final items = await _db.getAllSyncQueue();
    if (items.isEmpty) {
      debugPrint('[SyncService] sync_queue 비어있음');
      return;
    }

    debugPrint('[SyncService] sync_queue 처리: ${items.length}건');

    for (final item in items) {
      final id = item['id'] as int;
      final bookId = item['bookId'] as String?;
      final operation = item['operation'] as String;
      final entityType = (item['entityType'] as String?) ?? 'book';
      final entityId = item['entityId'] as String?;

      try {
        if (entityType == 'memo') {
          // 메모 재시도
          final memoId = entityId ?? bookId ?? '';
          if (memoId.isEmpty) {
            await _db.deleteSyncQueue(id);
            continue;
          }
          if (operation == 'delete') {
            await pushMemoDelete(memoId);
          } else {
            final memo = await _db.getMemoByMemoId(memoId);
            if (memo != null) {
              await pushMemo(memo);
            }
          }
          await _db.deleteSyncQueue(id);
          continue;
        }

        // 책 재시도 (기존 동작)
        final targetBookId = entityId ?? bookId ?? '';
        if (targetBookId.isEmpty) {
          await _db.deleteSyncQueue(id);
          continue;
        }
        if (operation == 'delete') {
          await pushDelete(targetBookId);
        } else {
          // upsert
          final book = await _db.getBookById(targetBookId);
          if (book != null) {
            await pushBook(book);
          } else {
            // 로컬에 없는 책의 upsert — 스킵 (이미 삭제되었을 가능성)
            debugPrint('[SyncService] 로컬에 없는 책 — 큐 항목 삭제: $targetBookId');
          }
        }
        // 성공 시 큐에서 제거
        await _db.deleteSyncQueue(id);
      } catch (e) {
        debugPrint('[SyncService] 큐 재시도 실패: ${entityId ?? bookId} — $e');
        // 실패 시 큐에 유지 (다음에 재시도)
      }
    }
  }

  // ---------------------------------------------------------------------------
  // 헬퍼
  // ---------------------------------------------------------------------------

  /// null/빈 문자열 → null
  static String? _parseNullable(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  /// ISO 8601 문자열 → DateTime?. 파싱 실패 시 null.
  static DateTime? _parseDate(dynamic v) {
    if (v == null) return null;
    final s = v.toString();
    if (s.isEmpty) return null;
    return DateTime.tryParse(s);
  }
}
