import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../domain/source_merge.dart';
import 'sync/sync_core.dart';

/// Local store for offline use. Everything StrideMate shows works from here;
/// the server only receives what account features need.
class LocalDb implements SyncStore {
  LocalDb._(this.db);
  final Database db;

  static Future<LocalDb> open() async {
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'stridemate.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE source_hourly (
            source_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            hour_utc INTEGER NOT NULL,
            steps INTEGER NOT NULL,
            updated_ms INTEGER NOT NULL,
            synced_steps INTEGER NOT NULL DEFAULT -1,
            PRIMARY KEY (source_id, hour_utc)
          )''');
        await db.execute('CREATE INDEX source_hourly_hour ON source_hourly (hour_utc)');
        await db.execute('CREATE TABLE rest_days (day TEXT PRIMARY KEY, synced INTEGER NOT NULL DEFAULT 0, deleted INTEGER NOT NULL DEFAULT 0)');
        await db.execute('CREATE TABLE goal_history (effective_from TEXT PRIMARY KEY, goal INTEGER NOT NULL)');
        await db.execute('CREATE TABLE achievements (key TEXT PRIMARY KEY, unlocked_on TEXT NOT NULL, synced INTEGER NOT NULL DEFAULT 0)');
        await db.execute('''
          CREATE TABLE outbox (
            batch_id TEXT PRIMARY KEY,
            payload TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_ms INTEGER NOT NULL DEFAULT 0,
            created_ms INTEGER NOT NULL
          )''');
      },
    );
    return LocalDb._(db);
  }

  /// Max-merge source buckets (a source's hour total only grows).
  Future<int> upsertBuckets(Iterable<SourceBucket> buckets) async {
    var changed = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      for (final b in buckets) {
        if (b.steps < 0) continue;
        // INSERT OR IGNORE + UPDATE: UPSERT syntax needs SQLite 3.24 (Android 11+).
        await txn.rawInsert(
          'INSERT OR IGNORE INTO source_hourly (source_id, kind, hour_utc, steps, updated_ms) VALUES (?, ?, ?, 0, ?)',
          [b.sourceId, b.kind.name, b.hourMsUtc, now],
        );
        changed += await txn.rawUpdate(
          'UPDATE source_hourly SET steps = ?, updated_ms = ? WHERE source_id = ? AND hour_utc = ? AND steps < ?',
          [b.steps, now, b.sourceId, b.hourMsUtc, b.steps],
        );
      }
    });
    return changed;
  }

  /// Restored-from-cloud buckets are stored as already synced.
  Future<void> importSyncedBuckets(Iterable<SourceBucket> buckets) async {
    await upsertBuckets(buckets);
    await db.transaction((txn) async {
      for (final b in buckets) {
        await txn.rawUpdate('UPDATE source_hourly SET synced_steps = steps WHERE source_id = ? AND hour_utc = ?',
            [b.sourceId, b.hourMsUtc]);
      }
    });
  }

  Future<List<SourceBucket>> bucketsBetween(DateTime fromUtc, DateTime toUtc) async {
    final rows = await db.rawQuery(
      'SELECT source_id, kind, hour_utc, steps FROM source_hourly WHERE hour_utc >= ? AND hour_utc < ?',
      [fromUtc.millisecondsSinceEpoch, toUtc.millisecondsSinceEpoch],
    );
    return rows.map(_bucket).toList();
  }

  Future<int?> latestUpdateMs() async {
    final r = await db.rawQuery('SELECT MAX(updated_ms) AS m FROM source_hourly');
    return r.first['m'] as int?;
  }

  Future<int?> earliestHourMs() async {
    final r = await db.rawQuery('SELECT MIN(hour_utc) AS m FROM source_hourly');
    return r.first['m'] as int?;
  }

  Future<List<String>> sourceIds() async {
    final r = await db.rawQuery('SELECT DISTINCT source_id FROM source_hourly');
    return r.map((e) => e['source_id'] as String).toList();
  }

  /// "Disconnect" keeps history by default; this removes a source's data entirely.
  Future<void> deleteSource(String sourceId) =>
      db.delete('source_hourly', where: 'source_id = ?', whereArgs: [sourceId]);

  // ---- rest days / goals / achievements ------------------------------------
  Future<Set<String>> restDays() async {
    final r = await db.query('rest_days', where: 'deleted = 0');
    return r.map((e) => e['day'] as String).toSet();
  }

  Future<void> setRestDay(String day, bool on) => db.insert(
        'rest_days',
        {'day': day, 'synced': 0, 'deleted': on ? 0 : 1},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  Future<List<Map<String, Object?>>> unsyncedRestDays() => db.query('rest_days', where: 'synced = 0');

  Future<void> markRestDaySynced(String day) =>
      db.update('rest_days', {'synced': 1}, where: 'day = ?', whereArgs: [day]);

  Future<void> replaceRestDays(Iterable<String> days) async {
    await db.transaction((txn) async {
      await txn.delete('rest_days', where: 'synced = 1');
      for (final d in days) {
        await txn.insert('rest_days', {'day': d, 'synced': 1, 'deleted': 0}, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<Map<String, int>> goalHistory() async {
    final r = await db.query('goal_history');
    return {for (final e in r) e['effective_from'] as String: e['goal'] as int};
  }

  Future<void> setGoalFrom(String day, int goal) => db.insert(
      'goal_history', {'effective_from': day, 'goal': goal},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<void> replaceGoalHistory(Map<String, int> history) async {
    await db.transaction((txn) async {
      for (final e in history.entries) {
        await txn.insert('goal_history', {'effective_from': e.key, 'goal': e.value},
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<Map<String, String>> achievementsUnlocked() async {
    final r = await db.query('achievements');
    return {for (final e in r) e['key'] as String: e['unlocked_on'] as String};
  }

  Future<void> saveAchievements(Map<String, String> unlocked) async {
    await db.transaction((txn) async {
      for (final e in unlocked.entries) {
        await txn.insert('achievements', {'key': e.key, 'unlocked_on': e.value, 'synced': 0},
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<List<Map<String, Object?>>> unsyncedAchievements() => db.query('achievements', where: 'synced = 0');

  Future<void> markAchievementSynced(String key) =>
      db.update('achievements', {'synced': 1}, where: 'key = ?', whereArgs: [key]);

  // ---- SyncStore ------------------------------------------------------------
  @override
  Future<List<SourceBucket>> unsyncedBuckets({int limit = 500}) async {
    final rows = await db.rawQuery(
      '''SELECT source_id, kind, hour_utc, steps FROM source_hourly
         WHERE steps <> synced_steps AND source_id NOT LIKE 'cloud:%'
           AND NOT EXISTS (SELECT 1 FROM outbox)  -- one batch in flight at a time
         ORDER BY hour_utc LIMIT ?''',
      [limit],
    );
    return rows.map(_bucket).toList();
  }

  @override
  Future<List<OutboxBatch>> pendingBatches() async {
    final rows = await db.query('outbox', orderBy: 'created_ms');
    return rows.map((r) {
      final list = (jsonDecode(r['payload'] as String) as List).cast<Map<String, dynamic>>();
      return OutboxBatch(
        batchId: r['batch_id'] as String,
        buckets: list.map((m) => SourceBucket(
              sourceId: m['s'] as String,
              kind: m['k'] == 'health' ? SourceKind.health : SourceKind.phone,
              hourUtc: DateTime.fromMillisecondsSinceEpoch(m['h'] as int, isUtc: true),
              steps: m['n'] as int,
            )).toList(),
        attempts: r['attempts'] as int,
        nextAttemptMs: r['next_attempt_ms'] as int,
      );
    }).toList();
  }

  @override
  Future<void> saveBatch(OutboxBatch batch) => db.insert('outbox', {
        'batch_id': batch.batchId,
        'payload': jsonEncode(batch.buckets
            .map((b) => {'s': b.sourceId, 'k': b.kind.name, 'h': b.hourMsUtc, 'n': b.steps})
            .toList()),
        'attempts': batch.attempts,
        'next_attempt_ms': batch.nextAttemptMs,
        'created_ms': DateTime.now().millisecondsSinceEpoch,
      });

  @override
  Future<void> completeBatch(OutboxBatch batch) async {
    await db.transaction((txn) async {
      for (final b in batch.buckets) {
        // Acknowledge exactly the value that was sent; newer local growth stays unsynced.
        await txn.rawUpdate(
          'UPDATE source_hourly SET synced_steps = MAX(synced_steps, ?) WHERE source_id = ? AND hour_utc = ?',
          [b.steps, b.sourceId, b.hourMsUtc],
        );
      }
      await txn.delete('outbox', where: 'batch_id = ?', whereArgs: [batch.batchId]);
    });
  }

  @override
  Future<void> updateBatch(OutboxBatch batch) => db.update(
        'outbox',
        {'attempts': batch.attempts, 'next_attempt_ms': batch.nextAttemptMs},
        where: 'batch_id = ?',
        whereArgs: [batch.batchId],
      );

  Future<int> pendingUploadCount() async {
    final r = await db.rawQuery("SELECT COUNT(*) AS c FROM source_hourly WHERE steps <> synced_steps AND source_id NOT LIKE 'cloud:%'");
    return (r.first['c'] as int?) ?? 0;
  }

  /// Everything stored on this device, for the personal data export.
  Future<Map<String, dynamic>> exportAll() async => {
        'hourly_by_source': await db.query('source_hourly', columns: ['source_id', 'kind', 'hour_utc', 'steps']),
        'rest_days': (await restDays()).toList()..sort(),
        'goal_history': await goalHistory(),
        'achievements': await achievementsUnlocked(),
      };

  Future<void> wipe() async {
    for (final t in ['source_hourly', 'rest_days', 'goal_history', 'achievements', 'outbox']) {
      await db.delete(t);
    }
  }

  /// After signing out, cloud-restored rows go; local recordings stay but are
  /// re-uploaded if the user signs in again (idempotent).
  Future<void> resetSyncState() async {
    await db.delete('source_hourly', where: "source_id LIKE 'cloud:%'");
    await db.update('source_hourly', {'synced_steps': -1});
    await db.delete('outbox');
    await db.update('rest_days', {'synced': 0});
    await db.update('achievements', {'synced': 0});
  }

  static SourceBucket _bucket(Map<String, Object?> r) => SourceBucket(
        sourceId: r['source_id'] as String,
        kind: r['kind'] == 'health' ? SourceKind.health : SourceKind.phone,
        hourUtc: DateTime.fromMillisecondsSinceEpoch(r['hour_utc'] as int, isUtc: true),
        steps: r['steps'] as int,
      );
}
