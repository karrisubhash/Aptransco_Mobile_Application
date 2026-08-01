import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/services/offline/outbox.dart';
import 'package:drone_inspection_app/widgets/sync_status_bar.dart';

/// Guards the sync details sheet's post-drain refresh.
///
/// `_reload()` used to read `=> setState(() => _future = ...)`. An arrow closure
/// returns its expression's value and an assignment evaluates to the value
/// assigned, so that handed `setState` a Future and threw "setState() callback
/// argument returned a Future" on every "Sync now" tap — leaving the queued list
/// stale. The analyzer cannot see that shape, so it is pinned here.
///
/// Both the queue source and the drain are injected: the real ones do file I/O
/// (which never completes under the widget tester's fake clock) and reach for
/// connectivity, the network and a retry timer.
OutboxOp _op(int seq, int ticketId, {bool failed = false, String? lastError}) =>
    OutboxOp(
      id: 'op-$seq',
      seq: seq,
      type: OpType.ticketClose,
      payload: {'ticket_id': ticketId},
      createdAt: 0,
      failed: failed,
      lastError: lastError,
    );

void main() {
  Future<void> pumpSheet(
    WidgetTester tester, {
    required Future<List<OutboxOp>> Function() loadQueue,
    required Future<void> Function() syncNow,
    Future<void> Function()? retryFailed,
    Future<void> Function(OutboxOp)? discardOp,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncDetailsSheet(
          loadQueue: loadQueue,
          syncNow: syncNow,
          retryFailed: retryFailed,
          discardOp: discardOp,
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('Sync now refreshes the queued list without throwing',
      (tester) async {
    var queue = [_op(0, 4321)];
    var drained = false;

    await pumpSheet(
      tester,
      loadQueue: () async => queue,
      syncNow: () async {
        queue = const []; // the op uploaded and left the outbox
        drained = true;
      },
    );

    expect(find.text('Close ticket #4321'), findsOneWidget);
    expect(find.text('All changes are synced.'), findsNothing);

    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();

    // This is what used to fail: setState was handed a Future.
    expect(tester.takeException(), isNull);

    // And the refresh re-read the queue rather than showing stale rows.
    expect(drained, isTrue);
    expect(find.text('Close ticket #4321'), findsNothing);
    expect(find.text('All changes are synced.'), findsOneWidget);
  });

  testWidgets('a still-queued op survives a drain that uploaded nothing',
      (tester) async {
    final queue = [_op(0, 99)];

    await pumpSheet(
      tester,
      loadQueue: () async => queue,
      syncNow: () async {/* offline: nothing drains */},
    );

    expect(find.text('Close ticket #99'), findsOneWidget);

    await tester.tap(find.text('Sync now'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Close ticket #99'), findsOneWidget);
  });

  testWidgets('an empty queue reads as fully synced', (tester) async {
    await pumpSheet(
      tester,
      loadQueue: () async => const [],
      syncNow: () async {},
    );

    expect(find.text('All changes are synced.'), findsOneWidget);
  });

  // The whole point of the parked state: `_drain` skips failed ops and nothing
  // used to clear the flag, so three inspections the server would now accept
  // stayed stuck on the device and the banner's "Retry" was a dead end.
  group('retrying parked changes', () {
    testWidgets('the action becomes Retry when something is parked',
        (tester) async {
      await pumpSheet(
        tester,
        loadQueue: () async =>
            [_op(0, 4321, failed: true, lastError: 'Save failed (403)')],
        syncNow: () async {},
      );

      expect(find.text('Retry failed changes'), findsOneWidget);
      expect(find.text('Sync now'), findsNothing);
    });

    testWidgets('stays Sync now when nothing is parked', (tester) async {
      await pumpSheet(
        tester,
        loadQueue: () async => [_op(0, 4321)],
        syncNow: () async {},
      );

      expect(find.text('Sync now'), findsOneWidget);
      expect(find.text('Retry failed changes'), findsNothing);
    });

    testWidgets('retrying uploads the revived change and clears the queue',
        (tester) async {
      var queue = [_op(0, 4321, failed: true, lastError: 'Save failed (403)')];
      var retried = false;

      await pumpSheet(
        tester,
        loadQueue: () async => queue,
        syncNow: () async {},
        retryFailed: () async {
          // What SyncEngine.retryFailed does: un-park, then drain. The server
          // now accepts it, so the op leaves the outbox.
          retried = true;
          queue = const [];
        },
      );

      await tester.tap(find.text('Retry failed changes'));
      await tester.pumpAndSettle();

      expect(retried, isTrue);
      expect(find.text('Close ticket #4321'), findsNothing);
      expect(find.text('All changes are synced.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a change the server still refuses stays parked and visible',
        (tester) async {
      final op = _op(0, 4321, failed: true, lastError: 'Save failed (403)');

      await pumpSheet(
        tester,
        loadQueue: () async => [op],
        syncNow: () async {},
        // Un-parked, sent, refused again, re-parked: the row must survive so the
        // inspector can still see it and choose to discard.
        retryFailed: () async => op.failed = true,
      );

      await tester.tap(find.text('Retry failed changes'));
      await tester.pumpAndSettle();

      expect(find.text('Close ticket #4321'), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });
  });

  // A parked op is skipped by every drain, so without a discard the queue — and
  // the "didn't sync" banner over every screen — can never clear.
  group('discarding a permanently-failed change', () {
    testWidgets('offers discard only on parked ops', (tester) async {
      await pumpSheet(
        tester,
        loadQueue: () async => [
          _op(0, 1),
          _op(1, 2, failed: true, lastError: 'Save failed (403)'),
        ],
        syncNow: () async {},
      );

      // One of the two rows is parked, so exactly one discard button.
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('confirming removes it from the queue', (tester) async {
      var queue = [_op(0, 4321, failed: true, lastError: 'Save failed (403)')];
      OutboxOp? discarded;

      await pumpSheet(
        tester,
        loadQueue: () async => queue,
        syncNow: () async {},
        discardOp: (op) async {
          discarded = op;
          queue = const [];
        },
      );

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      expect(find.text('Discard this change?'), findsOneWidget);

      await tester.tap(find.text('Discard'));
      await tester.pumpAndSettle();

      expect(discarded?.payload['ticket_id'], 4321);
      expect(find.text('Close ticket #4321'), findsNothing);
      expect(find.text('All changes are synced.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeping it discards nothing', (tester) async {
      final queue = [_op(0, 4321, failed: true)];
      var discardCalls = 0;

      await pumpSheet(
        tester,
        loadQueue: () async => queue,
        syncNow: () async {},
        discardOp: (_) async => discardCalls++,
      );

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();

      expect(discardCalls, 0);
      expect(find.text('Close ticket #4321'), findsOneWidget);
    });
  });
}
