import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/services/offline/local_store.dart';
import 'package:drone_inspection_app/services/offline/outbox.dart';
import 'package:drone_inspection_app/services/offline/sync_engine.dart';

/// `_drain` skips ops flagged `failed`, and until [SyncEngine.unparkFailed]
/// nothing ever cleared that flag: a change refused once — a jurisdiction gap
/// since granted, a server bug since fixed — was stranded on the device forever,
/// with the "didn't sync" banner permanently lit and "Retry" unable to do
/// anything about it.
///
/// Exercises the genuine file-backed outbox in a temp dir. A plain `test()`, not
/// `testWidgets`: real file I/O never completes under the widget tester's fake
/// clock.
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('li_unpark_test');
    await LocalStore.instance.initUnder(tmp);
    await OutboxStore.instance.init();
    for (final op in await OutboxStore.instance.list()) {
      await OutboxStore.instance.remove(op);
    }
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // A Windows AV/indexer lock must not fail the run.
    }
  });

  Future<OutboxOp> park(int ticketId, {String? error}) async {
    final op = await OutboxStore.instance
        .enqueue(OpType.ticketClose, {'ticket_id': ticketId});
    op.failed = true;
    op.attempts = 8;
    op.lastError = error ?? 'Save failed (403)';
    await OutboxStore.instance.update(op);
    return op;
  }

  test('revives every parked change, persisting the reset', () async {
    await park(6);
    await park(7);
    await park(14);

    expect((await OutboxStore.instance.list()).where((o) => o.failed).length, 3);
    // Parked ops don't count as pending, which is why the queue looked idle
    // while three inspections sat undelivered.
    expect(await OutboxStore.instance.pendingCount(), 0);

    final revived = await SyncEngine.instance.unparkFailed();

    expect(revived, 3);

    // Re-read from disk: the reset has to survive a restart, not just live in
    // the in-memory objects.
    final after = await OutboxStore.instance.list();
    expect(after.length, 3);
    for (final op in after) {
      expect(op.failed, isFalse);
      expect(op.attempts, 0);
      expect(op.lastError, isNull);
    }
    expect(await OutboxStore.instance.pendingCount(), 3);
  });

  test('leaves changes that are merely pending alone', () async {
    final pending = await OutboxStore.instance
        .enqueue(OpType.ticketClose, {'ticket_id': 1});
    // One real transport failure, nowhere near the parking threshold.
    pending.attempts = 2;
    pending.lastError = 'Connection closed';
    await OutboxStore.instance.update(pending);

    final revived = await SyncEngine.instance.unparkFailed();

    expect(revived, 0);
    final after = (await OutboxStore.instance.list()).single;
    // Its attempt history is untouched — resetting it would hand a genuinely
    // failing op a fresh set of tries it hasn't earned.
    expect(after.attempts, 2);
    expect(after.lastError, 'Connection closed');
  });

  test('an empty queue revives nothing', () async {
    expect(await SyncEngine.instance.unparkFailed(), 0);
  });
}
