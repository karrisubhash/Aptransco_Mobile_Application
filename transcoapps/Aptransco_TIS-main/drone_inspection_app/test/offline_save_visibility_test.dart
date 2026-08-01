import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/models/inspection_catalog.dart';
import 'package:drone_inspection_app/models/li_asset.dart';
import 'package:drone_inspection_app/models/li_session.dart';
import 'package:drone_inspection_app/services/auth_store.dart';
import 'package:drone_inspection_app/services/offline/connectivity_service.dart';
import 'package:drone_inspection_app/services/offline/li_cache_keys.dart';
import 'package:drone_inspection_app/services/offline/local_store.dart';
import 'package:drone_inspection_app/services/offline/offline_actions.dart';
import 'package:drone_inspection_app/services/offline/outbox.dart';

/// An inspection saved with no signal has to be *visible* straight away in every
/// place the same inspection would appear online — that is the whole promise of
/// the optimistic write.
///
/// It wasn't. History deliberately stopped narrowing its query to
/// `?inspector=<me>` (a supervisor captures nothing themselves, so the scoped
/// list left them with an empty tab), which moved the tab onto the *unscoped*
/// cache key — but `OfflineActions` was still writing its optimistic row only to
/// the per-line and per-inspector keys. The result was an inspection that
/// appeared on the Home map, sat safely in the outbox, and was missing from
/// History until it synced: exactly the moment a user has least reason to trust
/// that their work was saved.
///
/// Exercises the genuine file-backed store in a temp dir. A plain `test()`, not
/// `testWidgets`: real file I/O never completes under the widget tester's fake
/// clock.
void main() {
  late Directory tmp;
  late bool wasOnline;

  const tower = LiTower(
    id: 42,
    towerNumber: 'T-42',
    towerType: 'DA',
    voltage: '220kV',
    lineName: 'Kadapa – Proddatur',
    latitude: 14.47,
    longitude: 78.82,
    lineId: 7,
    subdivisionName: 'Kadapa',
  );

  const catalog = InspectionCatalog(
    version: 3,
    groups: [],
    followUps: {},
    criticalityRules: [],
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('li_offline_visibility_test');
    await LocalStore.instance.initUnder(tmp);
    await OutboxStore.instance.init();
    for (final op in await OutboxStore.instance.listAll()) {
      await OutboxStore.instance.remove(op);
    }
    // The queue is scoped to the signed-in employee (see session_switch_test),
    // so the inspector doing the saving has to actually be signed in — which is
    // the only way this path is reached in the app anyway.
    await AuthStore.instance.save(
        const LiSession(employeeId: '01019688', token: 'tok-test'));
    // Force the offline path: no network is attempted, so the save is judged
    // purely on what it leaves on the device.
    wasOnline = ConnectivityService.instance.online.value;
    ConnectivityService.instance.online.value = false;
  });

  tearDown(() async {
    ConnectivityService.instance.online.value = wasOnline;
    await AuthStore.instance.clear();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // A Windows AV/indexer lock must not fail the run.
    }
  });

  Future<void> saveOffline({String inspector = '01019688'}) =>
      OfflineActions.saveInspection(
        tower: tower,
        inspectorEmployeeId: inspector,
        catalogVersion: 3,
        date: '2026-07-29',
        remarks: 'no signal at the structure',
        clientId: 'client-abc-123',
        items: const [],
        photos: const {},
        catalog: catalog,
        worst: 'major',
        defectCount: 2,
      ).then((_) {});

  /// The rows cached under [key], or an empty list when nothing is cached.
  Future<List<dynamic>> rowsAt(String key) async {
    final body = await LocalStore.instance.getCache(key);
    if (body == null) return const [];
    return jsonDecode(body) as List<dynamic>;
  }

  test('an offline save lands in the unscoped list History actually reads',
      () async {
    await saveOffline();

    final rows = await rowsAt(LiCacheKeys.inspections());

    expect(rows, hasLength(1),
        reason: 'History reads the unscoped key — the row has to be there');
    final row = rows.single as Map<String, dynamic>;
    expect(row['tower_number'], 'T-42');
    expect(row['worst_criticality'], 'major');
    expect(row['defect_count'], 2);
    // Marked pending so the row can be badged as "waiting to upload" rather than
    // passing itself off as an inspection the server already has.
    expect(row['_pending'], isTrue);
    // A negative id keeps it from colliding with a server record, and routes the
    // detail read to the locally cached copy.
    expect(row['id'], lessThan(0));
  });

  test('the same save is visible on the map and in the inspector\'s own list',
      () async {
    await saveOffline();

    expect(await rowsAt(LiCacheKeys.inspections(line: 7)), hasLength(1),
        reason: 'the Home map reads the per-line key');
    expect(await rowsAt(LiCacheKeys.inspections(inspector: '01019688')),
        hasLength(1),
        reason: 'callers that still narrow by employee read the scoped key');
  });

  test('the detail page opens offline, before anything has synced', () async {
    await saveOffline();

    final row = (await rowsAt(LiCacheKeys.inspections())).single as Map;
    final detail = await LocalStore.instance
        .getCache(LiCacheKeys.inspectionDetail(row['id'] as int));

    expect(detail, isNotNull,
        reason: 'tapping the row must not dead-end with no signal');
    final decoded = jsonDecode(detail!) as Map<String, dynamic>;
    expect(decoded['remarks'], 'no signal at the structure');
    expect(decoded['catalog_version'], 3);
  });

  test('the work is durably queued, not just shown', () async {
    await saveOffline();

    final queued = await OutboxStore.instance.list();
    expect(queued, hasLength(1));
    expect(queued.single.type, OpType.inspection);
    // The client id doubles as the server's idempotency key, so a retry after a
    // crash can't create the inspection twice.
    expect(queued.single.id, 'client-abc-123');
    expect(queued.single.payload['tower_id'], 42);
  });

  test('a tower with no line context still reaches History', () async {
    const orphan = LiTower(
      id: 99,
      towerNumber: 'T-99',
      towerType: 'SA',
      voltage: '132kV',
      lineName: '',
      latitude: null,
      longitude: null,
      lineId: null, // no line — used to drop the optimistic row entirely
      subdivisionName: 'Kadapa',
    );

    await OfflineActions.saveInspection(
      tower: orphan,
      inspectorEmployeeId: '01019688',
      catalogVersion: 3,
      date: '2026-07-29',
      remarks: '',
      clientId: 'client-orphan-1',
      items: const [],
      photos: const {},
      catalog: catalog,
      worst: 'ok',
      defectCount: 0,
    );

    expect(await rowsAt(LiCacheKeys.inspections()), hasLength(1),
        reason: 'a missing line is no reason to hide the inspection');
  });
}
