import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/services/offline/connectivity_service.dart';

/// The reported bug: joined to Wi-Fi, but the app sits behind an "offline"
/// banner until you background it or toggle Wi-Fi by hand.
///
/// It was a self-latching state machine. One failed probe on a healthy link set
/// `online = false`; the read layer then skips the network entirely while that
/// is false, so no request was made, so nothing failed, so nothing asked the
/// service to look again — and the link never changed, so no platform event
/// arrived either. Nothing could clear it.
///
/// The fix is asymmetric by design, and these lock that asymmetry in:
///  * going offline takes repeated evidence (hysteresis),
///  * coming back takes one success,
///  * and while offline it must *always* have a recheck armed, because that
///    timer is the only thing that can break the cycle unaided.
void main() {
  final svc = ConnectivityService.instance;

  setUp(() => svc.resetForTest(onlineValue: true));
  tearDown(() => svc.resetForTest(onlineValue: true));

  /// Drive the machine with a known link state and backend reachability.
  void given({required bool link, required bool reachable}) {
    svc.linkProbe = () async => link;
    svc.reachabilityProbe = () async => reachable;
  }

  group('going offline is slow — one bad probe is noise', () {
    test('a single failed probe on a live link does NOT go offline', () async {
      given(link: true, reachable: false);

      await svc.refresh();

      expect(svc.online.value, isTrue,
          reason: 'a slow link or cold backend must not tear down the session');
      expect(svc.failureCount, 1);
    });

    test('two consecutive failures do go offline', () async {
      given(link: true, reachable: false);

      await svc.refresh();
      await svc.refresh();

      expect(svc.online.value, isFalse);
      expect(svc.failureCount, greaterThanOrEqualTo(2));
    });

    test('a success between failures resets the count', () async {
      given(link: true, reachable: false);
      await svc.refresh();
      expect(svc.failureCount, 1);

      given(link: true, reachable: true);
      await svc.refresh();
      expect(svc.failureCount, 0);

      // The next single failure starts from scratch, so it must not flip.
      given(link: true, reachable: false);
      await svc.refresh();

      expect(svc.online.value, isTrue);
    });

    test('no link at all is conclusive — offline immediately', () async {
      given(link: false, reachable: false);

      await svc.refresh();

      expect(svc.online.value, isFalse,
          reason: 'no radio is not ambiguous, so no hysteresis is warranted');
    });
  });

  group('coming back is instant', () {
    test('one successful probe restores a stuck-offline app', () async {
      given(link: true, reachable: false);
      await svc.refresh();
      await svc.refresh();
      expect(svc.online.value, isFalse);

      given(link: true, reachable: true);
      await svc.refresh();

      expect(svc.online.value, isTrue);
      expect(svc.failureCount, 0);
    });

    test('reportSuccess flips it online without waiting for a probe', () async {
      given(link: true, reachable: false);
      await svc.refresh();
      await svc.refresh();
      expect(svc.online.value, isFalse);

      // Any real response proves reachability — better evidence than the probe,
      // and the app makes real requests constantly.
      svc.reportSuccess();

      expect(svc.online.value, isTrue);
      expect(svc.failureCount, 0);
      expect(svc.hasPendingRecheck, isFalse,
          reason: 'once proven online there is nothing left to recheck');
    });
  });

  group('it never stops looking — the actual latch fix', () {
    test('a recheck is armed after going offline on a live link', () async {
      given(link: true, reachable: false);

      await svc.refresh();
      await svc.refresh();

      expect(svc.online.value, isFalse);
      expect(svc.hasPendingRecheck, isTrue,
          reason: 'without this the app can never notice the network returned');
    });

    test('a recheck is armed even with no link', () async {
      given(link: false, reachable: false);

      await svc.refresh();

      expect(svc.hasPendingRecheck, isTrue,
          reason: 'a link can return without a reliable platform event');
    });

    test('a recheck is armed after an inconclusive probe', () async {
      // The platform channel throwing is the normal case in a test binding, and
      // in the field it means "could not tell" — which must still be retried.
      svc.linkProbe = () async => throw Exception('platform channel missing');
      svc.reachabilityProbe = () async => false;

      await svc.refresh();

      expect(svc.hasPendingRecheck, isTrue);
    });

    test('going online disarms the recheck', () async {
      given(link: true, reachable: false);
      await svc.refresh();
      await svc.refresh();
      expect(svc.hasPendingRecheck, isTrue);

      given(link: true, reachable: true);
      await svc.refresh();

      expect(svc.hasPendingRecheck, isFalse);
    });
  });

  group('concurrent probes', () {
    test('callers share one in-flight probe and all see the real result',
        () async {
      var probes = 0;
      svc.linkProbe = () async => true;
      svc.reachabilityProbe = () async {
        probes++;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return true;
      };

      // The old `_probing` bool made overlapping callers return early on the
      // stale value, so `syncNow()` could act on a state that was about to
      // change under it.
      final results =
          await Future.wait([svc.refresh(), svc.refresh(), svc.refresh()]);

      expect(probes, 1, reason: 'one round trip, not three');
      expect(results, everyElement(isTrue),
          reason: 'every caller must get the real answer, not a stale one');
    });
  });
}
