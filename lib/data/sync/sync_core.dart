/// Offline-first, idempotent upload of step buckets.
///
/// Every bucket is a per-source cumulative hour total, merged on the server with
/// GREATEST(), so re-sending data can never inflate totals. On top of that each
/// upload is a *batch* whose UUID is written to the local outbox BEFORE the
/// request is sent; if the connection drops after the server committed, the retry
/// reuses the same batch id and the server answers "duplicate" from sync_batches.
library;

import 'dart:math';

import '../../domain/source_merge.dart';

class PendingBucket {
  const PendingBucket(this.bucket, this.localSteps);
  final SourceBucket bucket;
  final int localSteps;
}

class OutboxBatch {
  OutboxBatch({required this.batchId, required this.buckets, this.attempts = 0, this.nextAttemptMs = 0});
  final String batchId;
  final List<SourceBucket> buckets;
  int attempts;
  int nextAttemptMs;
}

abstract class SyncStore {
  /// Buckets whose local value differs from the last value acknowledged by the server.
  Future<List<SourceBucket>> unsyncedBuckets({int limit = 500});
  Future<List<OutboxBatch>> pendingBatches();
  Future<void> saveBatch(OutboxBatch batch);
  Future<void> completeBatch(OutboxBatch batch);
  Future<void> updateBatch(OutboxBatch batch);
}

abstract class SyncTransport {
  /// Throws on network/server failure. Returns normally when the server
  /// accepted the batch or recognised it as a duplicate.
  Future<void> uploadBuckets(String batchId, List<SourceBucket> buckets);
}

class SyncReport {
  int batchesSent = 0;
  int duplicates = 0;
  int failures = 0;
  Object? lastError;
}

class SyncCore {
  SyncCore({required this.store, required this.transport, required this.newId, int Function()? clock})
      : clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SyncStore store;
  final SyncTransport transport;
  final String Function() newId;
  final int Function() clock;
  bool _running = false;

  static int backoffMs(int attempts) => min(15 * 60 * 1000, 2000 * pow(2, attempts).toInt());

  Future<SyncReport> run() async {
    final report = SyncReport();
    if (_running) return report;
    _running = true;
    try {
      // 1. Retry batches that were created earlier (possibly already committed).
      for (final b in await store.pendingBatches()) {
        if (b.nextAttemptMs > clock()) continue;
        if (!await _send(b, report)) return report;
      }
      // 2. Package new changes into fresh batches.
      for (var guard = 0; guard < 50; guard++) {
        final changes = await store.unsyncedBuckets(limit: 500);
        if (changes.isEmpty) break;
        final batch = OutboxBatch(batchId: newId(), buckets: changes);
        await store.saveBatch(batch); // persisted before sending => safe retry id
        if (!await _send(batch, report)) return report;
      }
      return report;
    } finally {
      _running = false;
    }
  }

  Future<bool> _send(OutboxBatch b, SyncReport report) async {
    try {
      await transport.uploadBuckets(b.batchId, b.buckets);
      await store.completeBatch(b);
      report.batchesSent++;
      return true;
    } catch (e) {
      b.attempts++;
      b.nextAttemptMs = clock() + backoffMs(b.attempts);
      await store.updateBatch(b);
      report.failures++;
      report.lastError = e;
      return false;
    }
  }
}
