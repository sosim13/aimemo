import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/memo.dart';
import '../models/queue_state.dart';

class DatabaseService {
  static final DatabaseService _instance = DatabaseService._internal();
  factory DatabaseService() => _instance;
  DatabaseService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'aimemo.db');

    return await openDatabase(
      path,
      version: 13,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE memos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        memoId TEXT NOT NULL UNIQUE,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        category TEXT NOT NULL,
        sourceUrl TEXT,
        youtubeVideoId TEXT,
        thumbnailUrl TEXT,
        imagePath TEXT,
        address TEXT,
        searchKeyword TEXT,
        kakaoLat REAL,
        kakaoLng REAL,
        naverX REAL,
        naverY REAL,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL,
        userId TEXT,
        deletedAt TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_memos_category ON memos(category)
    ''');

    await db.execute('''
      CREATE INDEX idx_memos_created_at ON memos(createdAt)
    ''');

    await db.execute('''
      CREATE INDEX idx_memos_memoId ON memos(memoId)
    ''');

    await db.execute('''
      CREATE TABLE processing_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        itemId TEXT NOT NULL,
        content TEXT NOT NULL,
        type TEXT NOT NULL,
        status TEXT NOT NULL,
        progress REAL DEFAULT 1.0,
        error TEXT,
        memoTitle TEXT,
        memoId INTEGER,
        createdAt TEXT NOT NULL,
        completedAt TEXT,
        userId TEXT,
        updatedAt TEXT,
        deletedAt TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_history_created_at ON processing_history(createdAt)
    ''');

    // Sync queue (version 9) — 오프라인 상태에서 Supabase 동기화 실패 시
    // 재시도를 위해 쌓아두는 로컬 큐. SyncService가 처리.
    // version 10에서 entityType/entityId 추가 (메모 동기화 지원).
    await db.execute('''
      CREATE TABLE sync_queue (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bookId TEXT,
        operation TEXT NOT NULL,
        createdAt TEXT NOT NULL,
        entityType TEXT NOT NULL DEFAULT 'book',
        entityId TEXT
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_sync_queue_bookId ON sync_queue(bookId)
    ''');

    await db.execute('''
      CREATE INDEX idx_sync_queue_entityId ON sync_queue(entityId)
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'ALTER TABLE memos ADD COLUMN thumbnailUrl TEXT',
      );
      await db.execute(
        'ALTER TABLE memos ADD COLUMN imagePath TEXT',
      );
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS processing_history (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          itemId TEXT NOT NULL,
          content TEXT NOT NULL,
          type TEXT NOT NULL,
          status TEXT NOT NULL,
          progress REAL DEFAULT 1.0,
          error TEXT,
          memoTitle TEXT,
          createdAt TEXT NOT NULL,
          completedAt TEXT
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_history_created_at ON processing_history(createdAt)
      ''');
    }
    if (oldVersion < 4) {
      await db.execute(
        'ALTER TABLE processing_history ADD COLUMN memoId INTEGER',
      );
    }
    // version 11: 신규 설치 시 _onCreate의 processing_history CREATE TABLE에
    // memoId가 누락되어 있었음. 이미 컬럼이 있는 DB(oldVersion<4 경로로 추가된
    // 경우)는 중복 추가 오류가 나므로 존재 여부를 먼저 확인.
    if (oldVersion < 11) {
      final cols = await db.rawQuery('PRAGMA table_info(processing_history)');
      final hasMemoId = cols.any((c) => c['name'] == 'memoId');
      if (!hasMemoId) {
        await db.execute(
          'ALTER TABLE processing_history ADD COLUMN memoId INTEGER',
        );
      }
    }
    if (oldVersion < 5) {
      await db.execute(
        'ALTER TABLE memos ADD COLUMN kakaoLat REAL',
      );
      await db.execute(
        'ALTER TABLE memos ADD COLUMN kakaoLng REAL',
      );
      await db.execute(
        'ALTER TABLE memos ADD COLUMN naverX REAL',
      );
      await db.execute(
        'ALTER TABLE memos ADD COLUMN naverY REAL',
      );
    }
    if (oldVersion < 6) {
      await db.execute(
        'ALTER TABLE memos ADD COLUMN address TEXT',
      );
    }
    if (oldVersion < 7) {
      await db.execute(
        'ALTER TABLE memos ADD COLUMN searchKeyword TEXT',
      );
    }
    if (oldVersion < 8) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS books (
          bookId TEXT PRIMARY KEY,
          title TEXT NOT NULL,
          author TEXT NOT NULL DEFAULT '',
          coverThumbnailPath TEXT NOT NULL,
          category TEXT NOT NULL DEFAULT '독서',
          totalReadCount INTEGER NOT NULL DEFAULT 0
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_books_title ON books(title)
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS reading_sessions (
          sessionId TEXT PRIMARY KEY,
          bookId TEXT NOT NULL,
          readRound INTEGER NOT NULL DEFAULT 1,
          firstStartDate TEXT NOT NULL,
          completedDate TEXT,
          accumulatedActiveTime INTEGER NOT NULL DEFAULT 0,
          status TEXT NOT NULL DEFAULT 'READING',
          FOREIGN KEY (bookId) REFERENCES books(bookId) ON DELETE CASCADE
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_sessions_bookId ON reading_sessions(bookId)
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_sessions_status ON reading_sessions(status)
      ''');
    }
    // version 9: 동기화용 컬럼 + sync_queue 테이블 추가
    if (oldVersion < 9) {
      // books 테이블에 동기화 관련 컬럼 추가 (ALTER TABLE)
      await db.execute(
        'ALTER TABLE books ADD COLUMN thumbnailUrl TEXT',
      );
      await db.execute(
        'ALTER TABLE books ADD COLUMN userId TEXT',
      );
      await db.execute(
        'ALTER TABLE books ADD COLUMN updatedAt TEXT',
      );
      await db.execute(
        'ALTER TABLE books ADD COLUMN deletedAt TEXT',
      );

      // sync_queue 테이블 생성 — 오프라인 동기화 재시도 큐
      await db.execute('''
        CREATE TABLE IF NOT EXISTS sync_queue (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          bookId TEXT NOT NULL,
          operation TEXT NOT NULL,
          createdAt TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_queue_bookId ON sync_queue(bookId)
      ''');
    }
    // version 10: 메모 동기화 — memos 테이블에 memoId/userId/deletedAt 컬럼 추가,
    // 기존 메모에 고유 memoId 자동 부여, sync_queue에 entityType/entityId 컬럼 추가.
    if (oldVersion < 10) {
      // memos 테이블에 동기화 컬럼 추가
      await db.execute(
        'ALTER TABLE memos ADD COLUMN memoId TEXT',
      );
      await db.execute(
        'ALTER TABLE memos ADD COLUMN userId TEXT',
      );
      await db.execute(
        'ALTER TABLE memos ADD COLUMN deletedAt TEXT',
      );

      // 기존 메모에 고유 memoId 부여 (없는 것만)
      await db.execute('''
        UPDATE memos
        SET memoId = 'migrated-' || id || '-' || CAST(strftime('%s','now') AS INTEGER)
        WHERE memoId IS NULL OR memoId = ''
      ''');

      // memoId UNIQUE 인덱스 생성 (이미 중복이 없으므로 안전)
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_memos_memoId ON memos(memoId)
      ''');

      // sync_queue에 entityType/entityId 컬럼 추가 (기존 행은 'book'으로 채움)
      await db.execute(
        "ALTER TABLE sync_queue ADD COLUMN entityType TEXT NOT NULL DEFAULT 'book'",
      );
      await db.execute(
        'ALTER TABLE sync_queue ADD COLUMN entityId TEXT',
      );
      // 기존 큐 항목의 entityId를 bookId로 채움
      await db.execute('''
        UPDATE sync_queue SET entityId = bookId WHERE entityId IS NULL
      ''');
      await db.execute('''
        CREATE INDEX IF NOT EXISTS idx_sync_queue_entityId ON sync_queue(entityId)
      ''');
    }
    // version 12: reading_sessions/processing_history 동기화 — userId/updatedAt/deletedAt
    // 컬럼 추가. 컬럼 존재 여부를 먼저 확인해 중복 추가 오류를 방지한다.
    if (oldVersion < 12) {
      // reading_sessions 동기화 컬럼
      var cols = await db.rawQuery('PRAGMA table_info(reading_sessions)');
      if (!cols.any((c) => c['name'] == 'userId')) {
        await db.execute('ALTER TABLE reading_sessions ADD COLUMN userId TEXT');
      }
      if (!cols.any((c) => c['name'] == 'updatedAt')) {
        await db.execute('ALTER TABLE reading_sessions ADD COLUMN updatedAt TEXT');
      }
      if (!cols.any((c) => c['name'] == 'deletedAt')) {
        await db.execute('ALTER TABLE reading_sessions ADD COLUMN deletedAt TEXT');
      }

      // processing_history 동기화 컬럼
      cols = await db.rawQuery('PRAGMA table_info(processing_history)');
      if (!cols.any((c) => c['name'] == 'userId')) {
        await db.execute('ALTER TABLE processing_history ADD COLUMN userId TEXT');
      }
      if (!cols.any((c) => c['name'] == 'updatedAt')) {
        await db.execute('ALTER TABLE processing_history ADD COLUMN updatedAt TEXT');
      }
      if (!cols.any((c) => c['name'] == 'deletedAt')) {
        await db.execute('ALTER TABLE processing_history ADD COLUMN deletedAt TEXT');
      }
    }
    // version 13: 독서 기록 기능 제거 — books/reading_sessions 테이블과
    // 동기화 큐에 남은 독서 항목 삭제.
    if (oldVersion < 13) {
      await db.execute('DROP TABLE IF EXISTS reading_sessions');
      await db.execute('DROP TABLE IF EXISTS books');
      await db.execute(
        "DELETE FROM sync_queue WHERE entityType IN ('book', 'reading_session')",
      );
    }
  }

  // CRUD Operations

  Future<int> insertMemo(Memo memo) async {
    final db = await database;
    return await db.insert('memos', memo.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Memo>> getAllMemos() async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: 'deletedAt IS NULL',
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  /// 메모 목록을 페이지 단위로 조회 (무한 스크롤용).
  /// [category]가 주어지면 해당 카테고리만, [searchQuery]가 주어지면
  /// 제목/내용/카테고리에 부분 일치하는 것만 DB 레벨에서 필터링해서 반환한다.
  Future<List<Memo>> getMemosPage({
    required int limit,
    required int offset,
    String? category,
    String? searchQuery,
    bool noLocationOnly = false,
  }) async {
    final db = await database;
    final where = StringBuffer('deletedAt IS NULL');
    final args = <Object?>[];

    if (category != null) {
      where.write(' AND category = ?');
      args.add(category);
    }

    if (searchQuery != null && searchQuery.trim().isNotEmpty) {
      where.write(' AND (title LIKE ? OR content LIKE ? OR category LIKE ?)');
      final pattern = '%${searchQuery.trim()}%';
      args.addAll([pattern, pattern, pattern]);
    }

    // 지도 좌표(kakaoLat/kakaoLng)가 없는 메모만 — "지도 정보 없는 메모" 필터.
    if (noLocationOnly) {
      where.write(' AND (kakaoLat IS NULL OR kakaoLng IS NULL)');
    }

    final maps = await db.query(
      'memos',
      where: where.toString(),
      whereArgs: args,
      orderBy: 'createdAt DESC',
      limit: limit,
      offset: offset,
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  /// [category] 카테고리에서 지도 좌표가 없는 메모 전체를 (페이지네이션 없이)
  /// 반환한다 — "전체 삭제" 같이 필터에 해당하는 모든 항목이 필요한 액션용.
  Future<List<Memo>> getAllMemosMissingLocation(String category) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where:
          'deletedAt IS NULL AND category = ? AND (kakaoLat IS NULL OR kakaoLng IS NULL)',
      whereArgs: [category],
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  Future<List<Memo>> getMemosByCategory(String category) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: 'category = ? AND deletedAt IS NULL',
      whereArgs: [category],
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  Future<List<String>> getAllCategories() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT DISTINCT category FROM memos WHERE deletedAt IS NULL ORDER BY category',
    );
    return result.map((row) => row['category'] as String).toList();
  }

  Future<Memo?> getMemoById(int id) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return Memo.fromMap(maps.first);
  }

  /// memoId(UUID)로 메모 조회 — Supabase 동기화용.
  Future<Memo?> getMemoByMemoId(String memoId) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: 'memoId = ?',
      whereArgs: [memoId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Memo.fromMap(maps.first);
  }

  Future<int> updateMemo(Memo memo) async {
    final db = await database;
    return await db.update(
      'memos',
      memo.toMap(),
      where: 'id = ?',
      whereArgs: [memo.id],
    );
  }

  /// 메모 하드 삭제 (기존 동작 유지).
  Future<int> deleteMemo(int id) async {
    final db = await database;
    return await db.delete(
      'memos',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 메모 소프트 삭제 — deletedAt만 업데이트 (Supabase 동기화와 호환).
  /// SyncService가 deletedAt이 설정된 메모를 remote에서도 soft delete.
  Future<int> softDeleteMemo(int id) async {
    final db = await database;
    return await db.update(
      'memos',
      {
        'deletedAt': DateTime.now().toIso8601String(),
        'updatedAt': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// deletedAt이 null이 아닌(소프트 삭제된) 메모들의 memoId 목록 반환.
  Future<List<String>> getSoftDeletedMemoIds() async {
    final db = await database;
    final maps = await db.query(
      'memos',
      columns: ['memoId'],
      where: 'deletedAt IS NOT NULL',
    );
    return maps.map((m) => m['memoId'] as String).toList();
  }

  Future<List<Memo>> getMemosWithCoordinates() async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: 'kakaoLat IS NOT NULL AND kakaoLng IS NOT NULL AND deletedAt IS NULL',
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  Future<List<Memo>> searchMemos(String query) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: '(title LIKE ? OR content LIKE ? OR category LIKE ?) AND deletedAt IS NULL',
      whereArgs: ['%$query%', '%$query%', '%$query%'],
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  Future<Map<String, int>> getMemoCountByCategory() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT category, COUNT(*) as count FROM memos WHERE deletedAt IS NULL GROUP BY category ORDER BY count DESC',
    );
    final map = <String, int>{};
    for (final row in result) {
      map[row['category'] as String] = row['count'] as int;
    }
    return map;
  }

  // ---------------------------------------------------------------------------
  // Processing History CRUD
  // ---------------------------------------------------------------------------

  Future<int> insertProcessingHistory(ProcessingHistoryItem item) async {
    final db = await database;
    return await db.insert('processing_history', item.toMap());
  }

  Future<List<ProcessingHistoryItem>> getAllProcessingHistory() async {
    final db = await database;
    final maps = await db.query(
      'processing_history',
      orderBy: 'createdAt DESC',
    );
    return maps.map((m) => ProcessingHistoryItem.fromMap(m)).toList();
  }

  Future<int> deleteProcessingHistory(int id) async {
    final db = await database;
    return await db.delete('processing_history', where: 'id = ?', whereArgs: [id]);
  }

  /// itemId(UUID)로 처리 이력 조회 — sync_queue 재시도/pull 충돌 해결용.
  Future<ProcessingHistoryItem?> getProcessingHistoryByItemId(String itemId) async {
    final db = await database;
    final maps = await db.query(
      'processing_history',
      where: 'itemId = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return ProcessingHistoryItem.fromMap(maps.first);
  }

  /// id 기준 처리 이력 업데이트 — pull 충돌 해결(remote 우선)용.
  Future<int> updateProcessingHistory(ProcessingHistoryItem item) async {
    final db = await database;
    if (item.id == null) return 0;
    final map = item.toMap()..remove('id');
    return await db.update(
      'processing_history',
      map,
      where: 'id = ?',
      whereArgs: [item.id],
    );
  }

  Future<int> clearAllProcessingHistory() async {
    final db = await database;
    return await db.delete('processing_history');
  }

  /// Find the most recently created memo with the given title.
  /// Used when a ProcessingHistoryItem has no memoId stored (legacy records).
  Future<int?> getMemoIdByTitle(String title) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      columns: ['id'],
      where: "title = ? AND deletedAt IS NULL",
      whereArgs: [title],
      orderBy: 'createdAt DESC',
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return maps.first['id'] as int?;
  }

  Future<int> getProcessingHistoryCount() async {
    final db = await database;
    final result =
        await db.rawQuery('SELECT COUNT(*) as cnt FROM processing_history');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  // ---------------------------------------------------------------------------
  // Sync Queue CRUD (version 9) — SyncService가 사용
  // ---------------------------------------------------------------------------

  /// 동기화 큐에 항목 추가 (Supabase push 실패 시 호출).
  /// [entityType]은 'memo' 또는 'processing_history'.
  /// [entityId]는 해당 엔티티의 식별자. `bookId` 컬럼은 레거시 이름으로 같은 값을 저장.
  Future<int> insertSyncQueue(
    String bookId,
    String operation, {
    String entityType = 'book',
    String? entityId,
  }) async {
    final db = await database;
    return await db.insert('sync_queue', {
      'bookId': bookId,
      'operation': operation,
      'createdAt': DateTime.now().toIso8601String(),
      'entityType': entityType,
      'entityId': entityId ?? bookId,
    });
  }

  /// 동기화 큐의 모든 대기 항목 조회.
  Future<List<Map<String, dynamic>>> getAllSyncQueue() async {
    final db = await database;
    return await db.query('sync_queue', orderBy: 'createdAt ASC');
  }

  /// 동기화 큐에서 단일 항목 삭제.
  Future<int> deleteSyncQueue(int id) async {
    final db = await database;
    return await db.delete('sync_queue', where: 'id = ?', whereArgs: [id]);
  }

  /// 동기화 큐 비우기.
  Future<void> clearSyncQueue() async {
    final db = await database;
    await db.delete('sync_queue');
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
