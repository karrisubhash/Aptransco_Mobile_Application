import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/models/li_session.dart';
import 'package:drone_inspection_app/services/auth_store.dart';
import 'package:drone_inspection_app/services/offline/li_cache_keys.dart';
import 'package:drone_inspection_app/services/offline/local_store.dart';
import 'package:drone_inspection_app/services/offline/outbox.dart';

/// Signing out and signing in as somebody else showed the previous employee's
/// data — their lines, their towers, their tickets, their KPI numbers.
///
/// Nothing on the device was ever per-employee. Cache keys are per-resource
/// (`li_lines_all`, `li_dash_x`, `li_towers_<id>`), sign-out cleared only the
/// auth token out of SharedPreferences, and because master data is held for ten
/// minutes the new session did not even go to the server to correct itself. The
/// outbox was worse than stale: a change queued by one engineer had no owner, so
/// the sync engine would upload it under the next employee's token — and the
/// server credits an inspection to the token holder, not to the payload.
///
/// So: a wipe on sign-out *and* on switching employee (the app is force-killed
/// far more often than it is signed out of), with the durable queue exempted from
/// the wipe and scoped by owner instead.
///
/// Exercises the genuine file-backed store in a temp dir. A plain `test()`, not
/// `testWidgets`: real file I/O never completes under the widget tester's fake
/// clock.
void main() {
  late Directory tmp;

  LiSession sessionFor(String id) =>
      LiSession(employeeId: id, token: 'tok-$id', displayName: 'Emp $id');

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('li_session_switch_test');
    await LocalStore.instance.initUnder(tmp);
    await OutboxStore.instance.init();
    for (final op in await OutboxStore.instance.listAll()) {
      await OutboxStore.instance.remove(op);
    }
    await AuthStore.instance.clear();
  });

  tearDown(() async {
    await AuthStore.instance.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // A Windows AV/indexer lock must not fail the run.
    }
  });

  /// Fill the store with what one employee's session would have left behind.
  Future<void> cacheSomeJurisdiction() async {
    await LocalStore.instance.putCache(LiCacheKeys.linesAll, '[{"id":7}]');
    await LocalStore.instance.putCache(LiCacheKeys.towers(7), '[{"id":42}]');
    await LocalStore.instance.putCache(LiCacheKeys.dashboard(), '{"tower_total":66000}');
    await LocalStore.instance.putCache(LiCacheKeys.tickets(status: 'open'), '[]');
  }

  Future<bool> hasCachedJurisdiction() async =>
      await LocalStore.instance.getCache(LiCacheKeys.linesAll) != null ||
      await LocalStore.instance.getCache(LiCacheKeys.towers(7)) != null ||
      await LocalStore.instance.getCache(LiCacheKeys.dashboard()) != null;

  Future<OutboxOp> queueInspectionAs(String inspector, {int towerId = 42}) =>
      OutboxStore.instance.enqueue(OpType.inspection, {
        'tower_id': towerId,
        'inspector_employee_id': inspector,
        'date': '2026-07-30',
        'items': const [],
      });

  // ---- the cache -----------------------------------------------------------

  test('a different employee signing in wipes the previous one\'s data',
      () async {
    await AuthStore.instance.save(sessionFor('01019688'));
    await cacheSomeJurisdiction();
    expect(await hasCachedJurisdiction(), isTrue, reason: 'precondition');

    await AuthStore.instance.save(sessionFor('02233445'));

    expect(await hasCachedJurisdiction(), isFalse,
        reason: "the new employee must not be served the old one's scope");
  });

  test('signing out wipes the cache, so the next sign-in starts from the server',
      () async {
    await AuthStore.instance.save(sessionFor('01019688'));
    await cacheSomeJurisdiction();

    await AuthStore.instance.clear();

    expect(await hasCachedJurisdiction(), isFalse);
  });

  test('the same employee re-saving their session keeps the cache', () async {
    // The scope picker calls save() with a copyWith of the live session. Purging
    // there would throw away a warmed jurisdiction on every scope change and make
    // the app unusable offline, so the guard compares employee ids, not sessions.
    final me = sessionFor('01019688');
    await AuthStore.instance.save(me);
    await cacheSomeJurisdiction();

    await AuthStore.instance.save(me.copyWith(subdivisionId: 12));

    expect(await hasCachedJurisdiction(), isTrue);
    expect(AuthStore.instance.session?.subdivisionId, 12);
  });

  test('the wipe covers offline photos but spares the queue, its media and tiles',
      () async {
    await AuthStore.instance.save(sessionFor('01019688'));
    final photo = File('${LocalStore.instance.photosDir.path}/abc.img');
    await photo.writeAsBytes(const [1, 2, 3]);
    final staged = await LocalStore.instance
        .stageMedia(photo, 'staged_photo_0.jpg');
    final tile = File('${LocalStore.instance.tilesDir.path}/tile.img');
    await tile.writeAsBytes(const [4, 5, 6]);
    await queueInspectionAs('01019688');

    await AuthStore.instance.save(sessionFor('02233445'));

    expect(await photo.exists(), isFalse,
        reason: "another employee's evidence must not stay readable");
    expect(await File(staged).exists(), isTrue,
        reason: 'a queued inspection still needs its photos to upload');
    expect(await tile.exists(), isTrue,
        reason: 'public base-map imagery is not user data');
    expect(await OutboxStore.instance.listAll(), hasLength(1),
        reason: 'unsynced field work is the one thing a wipe must not take');
  });

  // ---- the queue -----------------------------------------------------------

  test('queued work is invisible to a different employee, and never drained',
      () async {
    await AuthStore.instance.save(sessionFor('01019688'));
    await queueInspectionAs('01019688');

    await AuthStore.instance.save(sessionFor('02233445'));

    expect(await OutboxStore.instance.list(), isEmpty,
        reason: 'the drain reads list() — this is what stops the misattribution');
    expect(await OutboxStore.instance.pendingCount(), 0,
        reason: "the status bar must not advertise someone else's changes");
    expect(await OutboxStore.instance.listAll(), hasLength(1),
        reason: 'still on disk, just not this session\'s to send');
  });

  test('queued work comes back when its author signs in again', () async {
    await AuthStore.instance.save(sessionFor('01019688'));
    await queueInspectionAs('01019688');
    await AuthStore.instance.save(sessionFor('02233445'));
    expect(await OutboxStore.instance.list(), isEmpty, reason: 'precondition');

    await AuthStore.instance.save(sessionFor('01019688'));

    final mine = await OutboxStore.instance.list();
    expect(mine, hasLength(1));
    expect(mine.single.payload['inspector_employee_id'], '01019688');
  });

  test('nothing is drained while signed out', () async {
    // SyncEngine.start() runs from main() before any login. Without the owner
    // check it drained with no token, burning an attempt per pass until the op
    // was parked as permanently failed — losing the work to a 401 that had
    // nothing to do with the work.
    await AuthStore.instance.save(sessionFor('01019688'));
    await queueInspectionAs('01019688');

    await AuthStore.instance.clear();

    expect(await OutboxStore.instance.list(), isEmpty);
    expect(await OutboxStore.instance.listAll(), hasLength(1));
  });

  test('enqueue stamps the signed-in employee', () async {
    await AuthStore.instance.save(sessionFor('01019688'));

    final op = await queueInspectionAs('01019688');

    expect(op.owner, '01019688');
    expect(op.ownerId, '01019688');
  });

  test('an op queued before the owner stamp resolves from its payload',
      () async {
    // An in-place upgrade can find ops already on disk with no `owner` field.
    // Every op OfflineActions writes names its author in the payload, so those
    // still resolve to the right person instead of being stranded or misdirected.
    await OutboxStore.instance.update(OutboxOp(
      id: 'legacy-1',
      seq: 900,
      type: OpType.ticketClose,
      payload: const {'ticket_id': 5, 'closed_by': '01019688'},
      createdAt: 0,
    ));

    await AuthStore.instance.save(sessionFor('02233445'));
    expect(await OutboxStore.instance.list(), isEmpty,
        reason: 'the payload names 01019688, not this session');

    await AuthStore.instance.save(sessionFor('01019688'));
    expect(await OutboxStore.instance.list(), hasLength(1));
  });
}
