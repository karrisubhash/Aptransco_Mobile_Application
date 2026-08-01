import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/services/line_inspection_api.dart';
import 'package:drone_inspection_app/services/offline/local_store.dart';

/// The cache-first read layer: what every tab now paints from.
///
/// [LineInspectionApi.shouldRevalidate] is the decision that makes a tab open
/// instantly instead of waiting for a round trip, and [CacheRead] is how a screen
/// gets the cached copy now and the server's when it lands. Both are covered here
/// without a server.
void main() {
  group('shouldRevalidate', () {
    bool decide({
      bool force = false,
      bool allowNetwork = true,
      bool hasCached = true,
      Duration? cachedAge,
      Duration? freshFor = const Duration(seconds: 45),
    }) =>
        LineInspectionApi.shouldRevalidate(
          force: force,
          allowNetwork: allowNetwork,
          hasCached: hasCached,
          cachedAge: cachedAge,
          freshFor: freshFor,
        );

    test('the disk-only pass never goes to the network', () {
      expect(decide(allowNetwork: false, hasCached: false), isFalse);
      expect(decide(allowNetwork: false, force: true), isFalse);
    });

    test('nothing cached always goes to the network', () {
      expect(decide(hasCached: false, cachedAge: null), isTrue);
    });

    test('a copy inside the freshness window is left alone', () {
      // Reopening a tab, or a reload triggered while the engineer is still on
      // the same screen, must cost no request at all.
      expect(decide(cachedAge: const Duration(seconds: 5)), isFalse);
      expect(decide(cachedAge: const Duration(seconds: 44)), isFalse);
    });

    test('once the window has passed it revalidates', () {
      expect(decide(cachedAge: const Duration(seconds: 45)), isTrue);
      expect(decide(cachedAge: const Duration(minutes: 10)), isTrue);
    });

    test('force ignores the window — pull-to-refresh, and after a sync', () {
      expect(decide(force: true, cachedAge: Duration.zero), isTrue);
    });

    test('with no window configured every read revalidates', () {
      expect(decide(freshFor: null, cachedAge: Duration.zero), isTrue);
    });
  });

  group('CacheRead', () {
    test('value answers from the cache without waiting for the server', () async {
      // A `fresh` that never completes stands in for a slow network: `value` must
      // still return, because that is the whole point of painting from disk.
      final read = CacheRead<String>('on disk', Completer<String?>().future, 'x');
      expect(await read.value, 'on disk');
      expect(read.hasCached, isTrue);
    });

    test('value falls through to the server when nothing is cached', () async {
      final read = CacheRead<String>(null, Future.value('from server'), 'x');
      expect(await read.value, 'from server');
      expect(read.hasCached, isFalse);
    });

    test('latest prefers the server copy', () async {
      final read = CacheRead<String>('on disk', Future.value('from server'), 'x');
      expect(await read.latest, 'from server');
    });

    test('latest keeps the cached copy when the network brought nothing',
        () async {
      // null is the read layer's "nothing newer" — a failed refresh, an offline
      // device, or a cached copy still inside its window.
      final read = CacheRead<String>('on disk', Future.value(null), 'x');
      expect(await read.latest, 'on disk');
    });

    test('with neither, it says what could not be loaded', () async {
      final read = CacheRead<String>(null, Future.value(null), 'tickets');
      await expectLater(
        read.value,
        throwsA(isA<OfflineNoCacheException>().having(
            (e) => e.toString(), 'message', contains('tickets'))),
      );
    });
  });

  group('CacheEntry', () {
    test('age is measured from when the response was stored', () {
      final entry = CacheEntry(
          '{}', DateTime.now().subtract(const Duration(seconds: 30)));
      expect(entry.age.inSeconds, closeTo(30, 1));
    });
  });
}
