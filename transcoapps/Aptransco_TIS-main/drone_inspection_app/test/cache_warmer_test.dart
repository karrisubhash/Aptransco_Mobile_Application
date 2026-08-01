import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/models/li_records.dart';
import 'package:drone_inspection_app/models/li_session.dart';
import 'package:drone_inspection_app/services/offline/cache_warmer.dart';
import 'package:drone_inspection_app/services/offline/connectivity_service.dart';
import 'package:drone_inspection_app/services/offline/local_store.dart';

/// The warmer's whole value is that the user never notices it, so what has to be
/// guaranteed is mostly about when it stays *quiet*.
///
/// There is no backend in a unit test, so these cover the guards rather than the
/// fetching: every trigger is a no-op without a session, without a link, or
/// without a store to write into. Those three conditions are what stop it
/// spending a field engineer's data at the wrong moment — and what stop it
/// firing real HTTP from inside a widget test that happens to mount the hub.
void main() {
  late bool wasOnline;

  const session = LiSession(
    employeeId: '01019688',
    token: 'test-token',
    displayName: 'Test Inspector',
    cadre: 'AEE',
    tier: 'field_user',
    subdivisionId: 4,
    subdivisionName: 'Kadapa',
  );

  final summaries = [
    for (var i = 1; i <= 3; i++)
      InspectionSummary(
        id: i,
        towerId: i,
        towerNumber: 'T-$i',
        towerType: 'DA',
        lineName: 'Kadapa – Proddatur',
        date: '2026-07-2$i',
        inspector: '01019688',
        worst: 'minor',
        defectCount: 1,
      ),
  ];

  setUp(() {
    wasOnline = ConnectivityService.instance.online.value;
  });

  tearDown(() {
    CacheWarmer.instance.stop();
    ConnectivityService.instance.online.value = wasOnline;
  });

  test('stays put with no session — nothing to warm for', () {
    ConnectivityService.instance.online.value = true;

    CacheWarmer.instance.kick();

    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  test('stays put while offline, even with a session', () {
    ConnectivityService.instance.online.value = false;

    CacheWarmer.instance.start(session);

    // Warming offline would be a stream of doomed requests; the reconnect
    // listener is what picks this back up.
    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  test('stays put when there is no store to write into', () {
    // LocalStore is never initialised under `flutter test` (path_provider is a
    // plugin channel), which is exactly the state a widget test mounting the hub
    // would be in. Warming here would spend the network on responses it has
    // nowhere to keep.
    expect(LocalStore.instance.isReady, isFalse,
        reason: 'precondition: the test binding has no initialised store');
    ConnectivityService.instance.online.value = true;

    CacheWarmer.instance.start(session);

    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  test('list prefetch is a no-op under the same guards', () {
    ConnectivityService.instance.online.value = true;
    CacheWarmer.instance.start(session);

    // Must not throw, must not start a pass — a list rendering is never a
    // reason to block or to surface an error.
    CacheWarmer.instance.prefetchForList(summaries);

    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  test('an empty list prefetches nothing', () {
    ConnectivityService.instance.online.value = true;
    CacheWarmer.instance.start(session);

    CacheWarmer.instance.prefetchForList(const []);

    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  test('stop() is safe before start, and idempotent', () {
    CacheWarmer.instance.stop();
    CacheWarmer.instance.stop();

    CacheWarmer.instance.start(session);
    CacheWarmer.instance.stop();
    CacheWarmer.instance.stop();

    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  test('start() twice does not double-register the connectivity listener',
      () async {
    ConnectivityService.instance.online.value = false;
    CacheWarmer.instance.start(session);
    CacheWarmer.instance.start(session);

    // Toggling the link must not throw (a double-registered listener would fire
    // twice and, after stop(), leave a stale one behind).
    ConnectivityService.instance.online.value = true;
    ConnectivityService.instance.online.value = false;

    CacheWarmer.instance.stop();
    ConnectivityService.instance.online.value = true;

    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  test('signing out stops the warmer reacting to reconnects', () {
    ConnectivityService.instance.online.value = false;
    CacheWarmer.instance.start(session);
    CacheWarmer.instance.stop();

    // A reconnect after sign-out must not resume warming the previous user's
    // jurisdiction.
    ConnectivityService.instance.online.value = true;

    expect(CacheWarmer.instance.isWarming, isFalse);
  });

  group('with a real on-device store', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('li_warmer_test');
      await LocalStore.instance.initUnder(tmp);
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {
        // A Windows AV/indexer lock must not fail the run.
      }
    });

    test('still stays put while offline once a store exists', () {
      ConnectivityService.instance.online.value = false;

      CacheWarmer.instance.start(session);
      CacheWarmer.instance.prefetchForList(summaries);

      expect(CacheWarmer.instance.isWarming, isFalse);
      expect(CacheWarmer.instance.lastPassAt, isNull);
    });
  });
}
