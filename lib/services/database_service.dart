import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/memo.dart';

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
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE memos (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        category TEXT NOT NULL,
        sourceUrl TEXT,
        youtubeVideoId TEXT,
        createdAt TEXT NOT NULL,
        updatedAt TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_memos_category ON memos(category)
    ''');

    await db.execute('''
      CREATE INDEX idx_memos_created_at ON memos(createdAt)
    ''');
  }

  // CRUD Operations

  Future<int> insertMemo(Memo memo) async {
    final db = await database;
    return await db.insert('memos', memo.toMap());
  }

  Future<List<Memo>> getAllMemos() async {
    final db = await database;
    final maps = await db.query(
      'memos',
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  Future<List<Memo>> getMemosByCategory(String category) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  Future<List<String>> getAllCategories() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT DISTINCT category FROM memos ORDER BY category',
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

  Future<int> updateMemo(Memo memo) async {
    final db = await database;
    return await db.update(
      'memos',
      memo.toMap(),
      where: 'id = ?',
      whereArgs: [memo.id],
    );
  }

  Future<int> deleteMemo(int id) async {
    final db = await database;
    return await db.delete(
      'memos',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<List<Memo>> searchMemos(String query) async {
    final db = await database;
    final maps = await db.query(
      'memos',
      where: 'title LIKE ? OR content LIKE ? OR category LIKE ?',
      whereArgs: ['%$query%', '%$query%', '%$query%'],
      orderBy: 'createdAt DESC',
    );
    return maps.map((map) => Memo.fromMap(map)).toList();
  }

  Future<Map<String, int>> getMemoCountByCategory() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT category, COUNT(*) as count FROM memos GROUP BY category ORDER BY count DESC',
    );
    final map = <String, int>{};
    for (final row in result) {
      map[row['category'] as String] = row['count'] as int;
    }
    return map;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database = null;
  }
}
