import 'package:flutter_test/flutter_test.dart';
import 'package:stridemate/domain/source_merge.dart';
import 'package:stridemate/data/sync/sync_core.dart';

/// Server double with the same semantics as upload_step_buckets():
/// GREATEST() merge per (source, hour) and replayed batch ids are no-ops.
class FakeServer implements SyncTransport {
  final store = <String, int>{};
  final seenBatches = <String>{};
  bool online = true;
  bool dropResponseAfterCommit = false;
  int calls = 0;

  @override
  Future<void> uploadBuckets(String batchId, List<SourceBucket> buckets) async {
    calls++;
    if (!online) throw Exception('SocketException: offline');
    if (!seenBatches.contains(batchId)) {
      seenBatches.add(batchId);
      for (final b in buckets) {
        final k = '${b.sourceId}@${b.hourMsUtc}';
        final cur = store[k] ?? 0;
        if (b.steps > cur) store[k] = b.steps;
      }
    }
    if (dropResponseAfterCommit) {
      dropResponseAfterCommit = false;
      throw Exception('connection reset after commit');
    }
  }

  int total() => store.values.fold(0, (a, b) => a + b);
}

/// In-memory equivalent of LocalDb's SyncStore behaviour.
class FakeStore implements SyncStore {
  final local = <String, SourceBucket>{};
  final synced = <String, int>{};
  final outbox = <OutboxBatch>[];

  void record(String src, SourceKind kind, int hourMs, int steps) {
    final k = '$src@$hourMs';
    final cur = local[k]?.steps ?? 0;
    if (steps > cur) {
      local[k] = SourceBucket(sourceId: src, kind: kind, hourUtc: DateTime.fromMillisecondsSinceEpoch(hourMs, isUtc: true), steps: steps);
    }
  }

  @override
  Future<List<SourceBucket>> unsyncedBuckets({int limit = 500}) async {
    if (outbox.isNotEmpty) return [];
    return local.entries.where((e) => synced[e.key] != e.value.steps).map((e) => e.value).take(limit).toList();
  }

  @override
  Future<List<OutboxBatch>> pendingBatches() async => List.of(outbox);
  @override
  Future<void> saveBatch(OutboxBatch batch) async => outbox.add(batch);
  @override
  Future<void> updateBatch(OutboxBatch batch) async {}
  @override
  Future<void> completeBatch(OutboxBatch batch) async {
    for (final b in batch.buckets) {
      final k = '${b.sourceId}@${b.hourMsUtc}';
      synced[k] = (synced[k] ?? -1) > b.steps ? synced[k]! : b.steps;
    }
    outbox.removeWhere((x) => x.batchId == batch.batchId);
  }
}

void main() {
  const h = 3600000;
  final t0 = DateTime.utc(2026, 11, 16, 6).millisecondsSinceEpoch;
  late FakeStore store;
  late FakeServer server;
  late SyncCore core;
  var now = 0;
  var ids = 0;

  setUp(() {
    store = FakeStore();
    server = FakeServer();
    now = t0;
    ids = 0;
    core = SyncCore(store: store, transport: server, newId: () => 'batch-${ids++}', clock: () => now);
  });

  test('offline counting is kept locally and uploaded once online', () async {
    server.online = false;
    store.record('phone:android', SourceKind.phone, t0, 500);
    store.record('phone:android', SourceKind.phone, t0 + h, 700);
    final r1 = await core.run();
    expect(r1.failures, 1);
    expect(server.total(), 0);
    server.online = true;
    now += 60 * 60 * 1000; // past the back-off
    await core.run();
    expect(server.total(), 1200);
    expect(store.outbox, isEmpty);
  });

  test('retry after a lost response reuses the batch id and cannot inflate totals', () async {
    store.record('phone:android', SourceKind.phone, t0, 900);
    server.dropResponseAfterCommit = true;
    await core.run(); // server committed, client saw an error
    expect(store.outbox.single.batchId, 'batch-0');
    now += 60 * 60 * 1000;
    await core.run(); // retry with the SAME id => duplicate, no change
    expect(server.seenBatches, {'batch-0'});
    expect(server.total(), 900);
    expect(store.outbox, isEmpty);
  });

  test('an hour that keeps growing is re-sent as a cumulative value, never added', () async {
    store.record('phone:android', SourceKind.phone, t0, 300);
    await core.run();
    store.record('phone:android', SourceKind.phone, t0, 450);
    await core.run();
    await core.run(); // nothing new
    expect(server.total(), 450);
    expect(server.calls, 2);
  });

  test('phone and wearable sources are stored separately; the server merges by policy', () async {
    store.record('phone:android', SourceKind.phone, t0, 1000);
    store.record('health:connect', SourceKind.health, t0, 1200);
    await core.run();
    expect(server.store.length, 2); // de-duplication happens in recompute_effective, not by summing
  });

  test('permission revoked: no new data, old data stays synced and nothing is lost', () async {
    store.record('phone:android', SourceKind.phone, t0, 1000);
    await core.run();
    // permission revoked => the phone source simply stops producing buckets
    final r = await core.run();
    expect(r.batchesSent, 0);
    expect(server.total(), 1000);
  });

  test('exponential back-off is capped at 15 minutes', () {
    expect(SyncCore.backoffMs(1), 4000);
    expect(SyncCore.backoffMs(20), 15 * 60 * 1000);
  });
}
