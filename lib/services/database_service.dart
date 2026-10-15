import 'dart:async';
import 'dart:math' as math;

import 'package:k100/core/constants.dart';
import 'package:k100/core/logger.dart';
import 'package:k100/models/chat_message.dart';
import 'package:k100/models/learner_profile.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local SQLite store: sessions, messages, the vocabulary bank and daily stats.
///
/// Deliberately boring: one file, four tables, no ORM, no code generation. Every
/// query is written out so that what the app stores — and what "erase my data"
/// deletes — is auditable in one screen of code.
///
/// Nothing here ever touches the network, and the database lives in the app's
/// private storage, so "your data stays on your device" is a fact rather than a
/// policy.
class DatabaseService {
  DatabaseService({DatabaseFactory? factory}) : _factoryOverride = factory;

  final DatabaseFactory? _factoryOverride;

  Database? _db;
  Completer<Database>? _opening;

  bool get isOpen => _db?.isOpen ?? false;

  /// Opens (and migrates) the database. Concurrent calls share one future.
  Future<Database> get database async {
    final Database? existing = _db;
    if (existing != null && existing.isOpen) return existing;

    final Completer<Database>? opening = _opening;
    if (opening != null) return opening.future;

    final Completer<Database> completer = Completer<Database>();
    _opening = completer;
    try {
      final Database db = await _open();
      _db = db;
      completer.complete(db);
      return db;
    } catch (error, stack) {
      completer.completeError(error, stack);
      rethrow;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _open() async {
    final DatabaseFactory factory = _factoryOverride ?? databaseFactory;
    final String path = p.join(await factory.getDatabasesPath(), AppConfig.databaseName);
    Log.info('Opening local database at $path');
    return factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: AppConfig.databaseVersion,
        onConfigure: (Database db) async {
          // Foreign keys are off by default in SQLite; without this a session
          // delete would orphan its messages.
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
  }

  Future<void> _createSchema(Database db, int version) async {
    final Batch batch = db.batch();

    batch.execute('''
      CREATE TABLE ${DbTables.sessions} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scenario_id TEXT NOT NULL,
        scenario_title TEXT NOT NULL,
        target_lang TEXT NOT NULL,
        native_lang TEXT NOT NULL,
        level TEXT NOT NULL,
        started_at INTEGER NOT NULL,
        ended_at INTEGER,
        message_count INTEGER NOT NULL DEFAULT 0,
        avg_score REAL NOT NULL DEFAULT 0,
        seconds_spent INTEGER NOT NULL DEFAULT 0
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_sessions_started ON ${DbTables.sessions}(started_at DESC)',
    );

    batch.execute('''
      CREATE TABLE ${DbTables.messages} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id INTEGER,
        role TEXT NOT NULL,
        text TEXT NOT NULL,
        translation TEXT,
        romanization TEXT,
        correction TEXT,
        explanation TEXT,
        score INTEGER,
        key_phrase TEXT,
        key_phrase_translation TEXT,
        parse_mode TEXT,
        latency_ms INTEGER,
        tokens_predicted INTEGER,
        degraded INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        FOREIGN KEY (session_id) REFERENCES ${DbTables.sessions}(id) ON DELETE CASCADE
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_messages_session ON ${DbTables.messages}(session_id, created_at)',
    );

    batch.execute('''
      CREATE TABLE ${DbTables.vocabulary} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        term TEXT NOT NULL,
        target_lang TEXT NOT NULL,
        translation TEXT,
        example TEXT,
        source_scenario_id TEXT,
        strength INTEGER NOT NULL DEFAULT 0,
        times_reviewed INTEGER NOT NULL DEFAULT 0,
        times_correct INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        last_reviewed_at INTEGER,
        due_at INTEGER,
        UNIQUE(term, target_lang)
      )
    ''');
    batch.execute(
      'CREATE INDEX idx_vocab_due ON ${DbTables.vocabulary}(target_lang, due_at)',
    );

    batch.execute('''
      CREATE TABLE ${DbTables.dailyStats} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day TEXT NOT NULL UNIQUE,
        messages INTEGER NOT NULL DEFAULT 0,
        minutes INTEGER NOT NULL DEFAULT 0,
        avg_score REAL NOT NULL DEFAULT 0,
        new_words INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await batch.commit(noResult: true);
    Log.info('Database schema created (v$version)');
  }

  Future<void> _upgradeSchema(Database db, int oldVersion, int newVersion) async {
    // v1 is the first shipped schema. Future migrations go here, one `if
    // (oldVersion < n)` block each — never a destructive drop.
    Log.info('Database upgrade $oldVersion → $newVersion');
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  SESSIONS
  // ══════════════════════════════════════════════════════════════════════════

  /// Opens a practice session row and returns its id.
  Future<int?> startSession({
    required String scenarioId,
    required String scenarioTitle,
    required LearnerProfile profile,
  }) async {
    try {
      final Database db = await database;
      final int id = await db.insert(
        DbTables.sessions,
        <String, Object?>{
          'scenario_id': scenarioId,
          'scenario_title': scenarioTitle,
          'target_lang': profile.targetLanguage.code,
          'native_lang': profile.nativeLanguage.code,
          'level': profile.proficiency.name,
          'started_at': DateTime.now().millisecondsSinceEpoch,
        },
      );
      await _pruneSessions(db);
      return id;
    } catch (error, stack) {
      Log.error('Could not open a session row', error, stack);
      return null;
    }
  }

  /// Closes a session, storing the aggregates the history list displays.
  Future<void> endSession(int sessionId) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> countRows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM ${DbTables.messages} WHERE session_id = ?',
        <Object?>[sessionId],
      );
      final int messageCount = (countRows.first['c'] as int?) ?? 0;

      final List<Map<String, Object?>> scoreRows = await db.rawQuery(
        'SELECT AVG(score) AS a FROM ${DbTables.messages} '
        'WHERE session_id = ? AND score IS NOT NULL',
        <Object?>[sessionId],
      );
      final double avgScore = ((scoreRows.first['a'] as num?) ?? 0).toDouble();

      final List<Map<String, Object?>> sessionRows = await db.query(
        DbTables.sessions,
        columns: <String>['started_at'],
        where: 'id = ?',
        whereArgs: <Object?>[sessionId],
        limit: 1,
      );
      final int startedAt = (sessionRows.isEmpty
              ? DateTime.now().millisecondsSinceEpoch
              : sessionRows.first['started_at'] as int?) ??
          DateTime.now().millisecondsSinceEpoch;
      final int seconds =
          ((DateTime.now().millisecondsSinceEpoch - startedAt) / 1000).round();

      await db.update(
        DbTables.sessions,
        <String, Object?>{
          'ended_at': DateTime.now().millisecondsSinceEpoch,
          'message_count': messageCount,
          'avg_score': avgScore,
          'seconds_spent': seconds,
        },
        where: 'id = ?',
        whereArgs: <Object?>[sessionId],
      );
    } catch (error, stack) {
      Log.error('Could not close session $sessionId', error, stack);
    }
  }

  Future<List<PracticeSession>> recentSessions({int limit = 100}) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.sessions,
        orderBy: 'started_at DESC',
        limit: limit,
      );
      return rows.map(PracticeSession.fromMap).toList();
    } catch (error, stack) {
      Log.error('Could not read sessions', error, stack);
      return <PracticeSession>[];
    }
  }

  Future<PracticeSession?> session(int id) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.sessions,
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      return rows.isEmpty ? null : PracticeSession.fromMap(rows.first);
    } catch (error, stack) {
      Log.error('Could not read session $id', error, stack);
      return null;
    }
  }

  /// Deletes a session and (through `ON DELETE CASCADE`) its messages.
  Future<void> deleteSession(int id) async {
    try {
      final Database db = await database;
      await db.delete(DbTables.sessions, where: 'id = ?', whereArgs: <Object?>[id]);
    } catch (error, stack) {
      Log.error('Could not delete session $id', error, stack);
    }
  }

  /// Keeps the newest [AppConfig.maxStoredSessions] sessions and drops the rest.
  Future<void> _pruneSessions(Database db) async {
    try {
      await db.rawDelete(
        'DELETE FROM ${DbTables.sessions} WHERE id NOT IN ('
        'SELECT id FROM ${DbTables.sessions} ORDER BY started_at DESC LIMIT ?)',
        <Object?>[AppConfig.maxStoredSessions],
      );
    } catch (error) {
      Log.warn('Session pruning failed', error);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  MESSAGES
  // ══════════════════════════════════════════════════════════════════════════

  /// Inserts a message and returns its rowid.
  Future<int?> insertMessage(ChatMessage message) async {
    try {
      final Database db = await database;
      return await db.insert(DbTables.messages, message.toMap());
    } catch (error, stack) {
      Log.error('Could not insert a message', error, stack);
      return null;
    }
  }

  /// Attaches grammar feedback to a message that was already on screen.
  Future<void> updateMessageFeedback(
    int messageId, {
    required String? correction,
    required String? explanation,
    required int? score,
    required String? parseMode,
  }) async {
    try {
      final Database db = await database;
      await db.update(
        DbTables.messages,
        <String, Object?>{
          'correction': correction,
          'explanation': explanation,
          'score': score,
          'parse_mode': parseMode,
        },
        where: 'id = ?',
        whereArgs: <Object?>[messageId],
      );
    } catch (error, stack) {
      Log.error('Could not attach feedback to message $messageId', error, stack);
    }
  }

  Future<List<ChatMessage>> messagesFor(int sessionId) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.messages,
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
        orderBy: 'created_at ASC, id ASC',
      );
      return rows.map(ChatMessage.fromMap).toList();
    } catch (error, stack) {
      Log.error('Could not read messages for session $sessionId', error, stack);
      return <ChatMessage>[];
    }
  }

  /// The most recent turns of a session, newest last — what the prompt builder
  /// needs for conversation context.
  Future<List<ChatMessage>> recentMessages(int sessionId, {int limit = 12}) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.messages,
        where: 'session_id = ?',
        whereArgs: <Object?>[sessionId],
        orderBy: 'created_at DESC, id DESC',
        limit: limit,
      );
      return rows.reversed.map(ChatMessage.fromMap).toList();
    } catch (error, stack) {
      Log.error('Could not read recent messages', error, stack);
      return <ChatMessage>[];
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  VOCABULARY BANK
  // ══════════════════════════════════════════════════════════════════════════

  /// Inserts a phrase, or refreshes the example if the term already exists.
  Future<int?> upsertVocabulary(VocabularyItem item) async {
    try {
      final Database db = await database;
      final int id = await db.insert(
        DbTables.vocabulary,
        item.toMap(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (id != 0) return id;
      // Already there: keep the newest example and bump the due date.
      await db.update(
        DbTables.vocabulary,
        <String, Object?>{
          if (item.example != null) 'example': item.example,
          if (item.translation != null) 'translation': item.translation,
          'due_at': DateTime.now()
              .add(VocabularyItem.intervalFor(0))
              .millisecondsSinceEpoch,
        },
        where: 'term = ? AND target_lang = ?',
        whereArgs: <Object?>[item.term, item.targetLanguageCode],
      );
      return null;
    } catch (error, stack) {
      Log.error('Could not store vocabulary', error, stack);
      return null;
    }
  }

  Future<List<VocabularyItem>> vocabulary({
    required String targetLanguageCode,
    int limit = 500,
  }) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.vocabulary,
        where: 'target_lang = ?',
        whereArgs: <Object?>[targetLanguageCode],
        orderBy: 'created_at DESC',
        limit: limit,
      );
      return rows.map(VocabularyItem.fromMap).toList();
    } catch (error, stack) {
      Log.error('Could not read vocabulary', error, stack);
      return <VocabularyItem>[];
    }
  }

  /// Items whose review interval has elapsed, weakest first.
  Future<List<VocabularyItem>> dueVocabulary({
    required String targetLanguageCode,
    int limit = 40,
  }) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.vocabulary,
        where: 'target_lang = ? AND (due_at IS NULL OR due_at <= ?)',
        whereArgs: <Object?>[targetLanguageCode, DateTime.now().millisecondsSinceEpoch],
        orderBy: 'strength ASC, due_at ASC',
        limit: limit,
      );
      return rows.map(VocabularyItem.fromMap).toList();
    } catch (error, stack) {
      Log.error('Could not read due vocabulary', error, stack);
      return <VocabularyItem>[];
    }
  }

  int vocabScoreFor(VocabularyItem item) =>
      (item.strength * 20 + item.accuracy * 100 * 0.5).round();

  /// Applies a review result with a Leitner-style schedule: a correct recall grows
  /// the strength (longer interval), a miss resets it to 0.
  Future<void> reviewVocabulary(int id, {required bool remembered}) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.vocabulary,
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) return;
      final Map<String, Object?> row = rows.first;
      final int strength = math.max(
        0,
        remembered
            ? math.min(5, ((row['strength'] as int?) ?? 0) + 1)
            : ((row['strength'] as int?) ?? 0) - 2,
      );
      await db.update(
        DbTables.vocabulary,
        <String, Object?>{
          'strength': strength,
          'times_reviewed': ((row['times_reviewed'] as int?) ?? 0) + 1,
          'times_correct': ((row['times_correct'] as int?) ?? 0) + (remembered ? 1 : 0),
          'last_reviewed_at': DateTime.now().millisecondsSinceEpoch,
          'due_at': DateTime.now()
              .add(VocabularyItem.intervalFor(strength))
              .millisecondsSinceEpoch,
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    } catch (error, stack) {
      Log.error('Could not record a vocabulary review', error, stack);
    }
  }

  Future<void> deleteVocabulary(int id) async {
    try {
      final Database db = await database;
      await db.delete(DbTables.vocabulary, where: 'id = ?', whereArgs: <Object?>[id]);
    } catch (error, stack) {
      Log.error('Could not delete vocabulary item $id', error, stack);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  //  DAILY STATS
  // ══════════════════════════════════════════════════════════════════════════

  static String dayKey([DateTime? date]) {
    final DateTime value = date ?? DateTime.now();
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  /// Adds practice to today's row (creating it when needed).
  Future<void> recordPractice({
    required int seconds,
    required int messages,
    int newWords = 0,
    double? score,
  }) async {
    try {
      final Database db = await database;
      final String day = dayKey();
      final List<Map<String, Object?>> existing = await db.query(
        DbTables.dailyStats,
        where: 'day = ?',
        whereArgs: <Object?>[day],
        limit: 1,
      );

      if (existing.isEmpty) {
        await db.insert(DbTables.dailyStats, <String, Object?>{
          'day': day,
          'messages': messages,
          'minutes': (seconds / 60).round(),
          'avg_score': score ?? 0,
          'new_words': newWords,
        });
        return;
      }

      final Map<String, Object?> row = existing.first;
      final int oldMessages = (row['messages'] as int?) ?? 0;
      final double oldAverage = ((row['avg_score'] as num?) ?? 0).toDouble();
      final int totalMessages = oldMessages + messages;
      final double blendedScore = score == null
          ? oldAverage
          : totalMessages == 0
              ? score
              : (oldAverage * oldMessages + score * messages) / totalMessages;

      await db.update(
        DbTables.dailyStats,
        <String, Object?>{
          'messages': totalMessages,
          'minutes': ((row['minutes'] as int?) ?? 0) + (seconds / 60).round(),
          'avg_score': blendedScore,
          'new_words': ((row['new_words'] as int?) ?? 0) + newWords,
        },
        where: 'day = ?',
        whereArgs: <Object?>[day],
      );
    } catch (error, stack) {
      Log.error('Could not record practice stats', error, stack);
    }
  }

  /// The last [days] days, oldest first, **including days with no activity** so
  /// the weekly chart has a stable shape.
  Future<List<DailyProgress>> recentStats({int days = 7}) async {
    try {
      final Database db = await database;
      final DateTime now = DateTime.now();
      final DateTime from = now.subtract(Duration(days: days - 1));
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.dailyStats,
        where: 'day >= ?',
        whereArgs: <Object?>[dayKey(from)],
        orderBy: 'day ASC',
      );
      final Map<String, DailyProgress> byDay = <String, DailyProgress>{
        for (final Map<String, Object?> row in rows)
          DailyProgress.fromMap(row).day: DailyProgress.fromMap(row),
      };
      return List<DailyProgress>.generate(days, (int index) {
        final DateTime date = from.add(Duration(days: index));
        final String key = dayKey(date);
        return byDay[key] ?? DailyProgress(day: key);
      });
    } catch (error, stack) {
      Log.error('Could not read recent stats', error, stack);
      return <DailyProgress>[];
    }
  }

  /// Consecutive days ending today (or yesterday — a streak survives until the
  /// day is over).
  Future<int> currentStreak() async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.query(
        DbTables.dailyStats,
        columns: <String>['day', 'messages', 'minutes'],
        where: '(messages > 0 OR minutes > 0)',
        orderBy: 'day DESC',
        limit: 400,
      );
      if (rows.isEmpty) return 0;

      final Set<String> activeDays = rows
          .map((Map<String, Object?> row) => '${row['day']}')
          .toSet();

      final DateTime today = DateTime.now();
      // Allow the streak to still be alive if the learner practised yesterday.
      DateTime cursor = activeDays.contains(dayKey(today))
          ? today
          : today.subtract(const Duration(days: 1));

      int streak = 0;
      while (activeDays.contains(dayKey(cursor))) {
        streak++;
        cursor = cursor.subtract(const Duration(days: 1));
        if (streak > 365) break;
      }
      return streak;
    } catch (error, stack) {
      Log.error('Could not compute the streak', error, stack);
      return 0;
    }
  }

  /// Mean fluency score over the last [days] days, or 0 when nothing is scored.
  Future<double> averageScore({int days = 30}) async {
    try {
      final Database db = await database;
      final DateTime from = DateTime.now().subtract(Duration(days: days));
      final List<Map<String, Object?>> rows = await db.rawQuery(
        'SELECT AVG(avg_score) AS a FROM ('
        '  SELECT avg_score FROM ${DbTables.dailyStats} '
        '  WHERE day >= ? AND avg_score > 0 LIMIT 60'
        ')',
        <Object?>[dayKey(from)],
      );
      return ((rows.first['a'] as num?) ?? 0).toDouble();
    } catch (error, stack) {
      Log.error('Could not compute the average score', error, stack);
      return 0;
    }
  }

  /// Total minutes practised in the last [days] days.
  Future<int> totalMinutes({int days = 30}) async {
    try {
      final Database db = await database;
      final List<Map<String, Object?>> rows = await db.rawQuery(
        'SELECT SUM(minutes) AS m FROM ${DbTables.dailyStats} WHERE day >= ?',
        <Object?>[dayKey(DateTime.now().subtract(Duration(days: days)))],
      );
      return (rows.first['m'] as int?) ?? 0;
    } catch (error) {
      return 0;
    }
  }

  /// Row counts shown in Settings ("what is on this device?").
  Future<Map<String, int>> counts() async {
    try {
      final Database db = await database;
      Future<int> count(String table) async {
        final List<Map<String, Object?>> rows =
            await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
        return (rows.first['c'] as int?) ?? 0;
      }

      return <String, int>{
        'sessions': await count(DbTables.sessions),
        'messages': await count(DbTables.messages),
        'vocabulary': await count(DbTables.vocabulary),
        'days': await count(DbTables.dailyStats),
      };
    } catch (error, stack) {
      Log.error('Could not count rows', error, stack);
      return <String, int>{'sessions': 0, 'messages': 0, 'vocabulary': 0, 'days': 0};
    }
  }

  /// Removes sessions older than [AppConfig.historyRetention].
  Future<int> pruneOldSessions() async {
    try {
      final Database db = await database;
      final int cutoff = DateTime.now()
          .subtract(AppConfig.historyRetention)
          .millisecondsSinceEpoch;
      return await db.delete(
        DbTables.sessions,
        where: 'started_at < ?',
        whereArgs: <Object?>[cutoff],
      );
    } catch (error, stack) {
      Log.error('Could not prune old sessions', error, stack);
      return 0;
    }
  }

  /// Deletes every row (but keeps the schema). Used by "erase all local data".
  Future<void> wipeEverything() async {
    try {
      final Database db = await database;
      final Batch batch = db.batch();
      batch.delete(DbTables.messages);
      batch.delete(DbTables.sessions);
      batch.delete(DbTables.vocabulary);
      batch.delete(DbTables.dailyStats);
      await batch.commit(noResult: true);
      Log.warn('All local learning data erased by the user');
    } catch (error, stack) {
      Log.error('Could not wipe the database', error, stack);
    }
  }

  Future<void> close() async {
    final Database? db = _db;
    _db = null;
    if (db != null && db.isOpen) await db.close();
  }
}
