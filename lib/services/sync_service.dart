import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../models/book.dart';
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

  final _client = Supabase.instance.client;
  final _db = DatabaseService();
  final _thumbnail = ThumbnailSyncService();

  /// debouncing용 타이머 맵 (bookId → Timer)
  final Map<String, Timer> _debounceTimers = {};

  /// 동기화 가능 여부: 현재 사용자가 Supabase Auth 세션을 가지고 있고
  /// provider가 google인지 확인. 비로그인/익명이면 false.
  bool get _canSync {
    final user = _client.auth.currentUser;
    if (user == null) {
      return false;
    }
    // provider 확인 — appMetadata에서 'provider' 값이 'google'인지 검사
    final provider = user.appMetadata['provider'];
    return provider == 'google';
  }

  /// 현재 로그인 사용자의 uid.
  String? get _currentUserId => _client.auth.currentUser?.id;

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
        thumbnailUrl = await _thumbnail.uploadThumbnail(book, uid);
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

      await _client.from('books').upsert(data, onConflict: 'book_id');
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
      await _client.from('books').update({
        'deleted_at': now,
        'updated_at': now,
      }).eq('book_id', bookId).eq('user_id', uid);
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
      final response = await _client
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
      final remoteUpdatedAt = remoteUpdatedAtStr != null
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

    debugPrint('[SyncService] pullFromSupabase 완료');
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
      _thumbnail.downloadThumbnail(book).then((localPath) {
        if (localPath != null) {
          // 다운로드 완료 후 로컬 coverThumbnailPath 업데이트
          _db.updateBook(book.copyWith(coverThumbnailPath: localPath));
          debugPrint('[SyncService] 썸네일 다운로드 후 로컬 경로 업데이트: ${book.bookId}');
        }
      }).catchError((e) {
        debugPrint('[SyncService] 썸네일 다운로드 실패: ${book.bookId} — $e');
      });
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
      final bookId = item['bookId'] as String;
      final operation = item['operation'] as String;

      try {
        if (operation == 'delete') {
          await pushDelete(bookId);
        } else {
          // upsert
          final book = await _db.getBookById(bookId);
          if (book != null) {
            await pushBook(book);
          } else {
            // 로컬에 없는 책의 upsert — 스킵 (이미 삭제되었을 가능성)
            debugPrint('[SyncService] 로컬에 없는 책 — 큐 항목 삭제: $bookId');
          }
        }
        // 성공 시 큐에서 제거
        await _db.deleteSyncQueue(id);
      } catch (e) {
        debugPrint('[SyncService] 큐 재시도 실패: $bookId — $e');
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
