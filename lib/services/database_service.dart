import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/location_point.dart';

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
    final dbFilePath = join(dbPath, 'fog_of_war.db');
    return await openDatabase(
      dbFilePath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE location_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            timestamp INTEGER NOT NULL
          )
        ''');
      },
    );
  }

  Future<int> insertPoint(LocationPoint point) async {
    final db = await database;
    return await db.insert('location_points', point.toMap());
  }

  Future<List<LocationPoint>> getAllPoints() async {
    final db = await database;
    final maps = await db.query('location_points', orderBy: 'timestamp ASC');
    return maps.map((m) => LocationPoint.fromMap(m)).toList();
  }
}
