import 'dart:async';
import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../api_service.dart';

/// Tracks whether the app can actually reach the backend right now.
///
/// A phone can be joined to Wi-Fi yet have no route to the server (the exact
/// situation on the corporate network, where the ngrok host is DNS-sinkholed or
/// TLS-intercepted). So link-layer connectivity alone is not enough: when a link
/// is present we confirm with a cheap `GET /ping/` before declaring "online".
///
/// Getting that wrong in either direction is expensive, so the state machine is
/// deliberately asymmetric:
///
///  * **Going offline is slow.** One failed probe is not evidence — a slow field
///    link, a DNS blip or a cold backend all produce it. It takes
///    [_failuresBeforeOffline] consecutive failures to abandon a working
///    session, which stops the banner flapping over a healthy connection.
///  * **Coming back is instant.** A single successful probe — or any successful
///    request anywhere in the app, via [reportSuccess] — restores it at once.
///  * **It always keeps looking.** While offline, a backoff timer re-probes on
///    its own.
///
/// That last part is the one that matters most, and it is what was missing. The
/// service used to re-probe only on a *connectivity change* or an explicit
/// [refresh], and the read layer skips the network entirely while `online` is
/// false. So a single bad probe on an otherwise healthy Wi-Fi network latched
/// the whole app offline: no requests were made, so nothing failed, so nothing
/// asked it to look again — and the link never changed, so no event arrived
/// either. It stayed stuck until the app was backgrounded or Wi-Fi toggled by
/// hand. The recheck timer breaks that cycle.
class ConnectivityService {
  ConnectivityService._();
  static final ConnectivityService instance = ConnectivityService._();

  /// Whether the backend is reachable. Starts optimistically `true` so the very
  /// first screen tries the network; the first probe corrects it within seconds.
  final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  /// How long one reachability probe may take. Generous, because the cost of
  /// being wrong (dropping a working session to "offline") is far higher than
  /// the cost of waiting: a field link on 2 bars can take several seconds to
  /// answer, and the old 6s ceiling was tight enough to fail on a healthy one.
  static const Duration _probeTimeout = Duration(seconds: 10);

  /// Consecutive failed probes required to move an *online* session to offline.
  /// One failure is noise; two in a row is a signal.
  static const int _failuresBeforeOffline = 2;

  /// Backoff for the self-recheck while we believe we are offline. Starts quick
  /// so a brief blip recovers almost immediately, then eases off so a genuinely
  /// signal-less day in the field is not a stream of doomed requests.
  static const List<Duration> _recheckBackoff = [
    Duration(seconds: 3),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  /// The probe in flight, so concurrent callers share one round trip *and* — the
  /// part the old `_probing` bool got wrong — every caller awaits the real
  /// result instead of returning early on a stale value.
  Future<bool>? _probe;

  Timer? _recheck;
  int _failures = 0;
  int _recheckStep = 0;
  bool _disposed = false;

  Future<void> init() async {
    _disposed = false;
    _sub = _connectivity.onConnectivityChanged.listen(_onChange);
    // Kick off the first evaluation without blocking app start-up.
    unawaited(refresh());
  }

  void _onChange(List<ConnectivityResult> results) {
    // A link change is fresh evidence either way, so start the backoff over
    // rather than inheriting a long delay from the previous state.
    _recheckStep = 0;
    final hasLink = results.any((r) => r != ConnectivityResult.none);
    if (!hasLink) {
      _failures = _failuresBeforeOffline; // no link is conclusive
      _set(false);
      _scheduleRecheck();
    } else {
      unawaited(refresh());
    }
  }

  /// Re-check reachability now, returning the resulting state. Called on
  /// connectivity changes, on app resume, whenever a request unexpectedly fails,
  /// and by the self-recheck timer.
  ///
  /// Concurrent calls share the one in-flight probe.
  Future<bool> refresh() {
    if (_disposed) return Future<bool>.value(online.value);
    final running = _probe;
    if (running != null) return running;
    late final Future<bool> f;
    f = _evaluate().whenComplete(() {
      if (identical(_probe, f)) _probe = null;
    });
    _probe = f;
    return f;
  }

  /// Report that a request just succeeded. Proof of reachability, so it clears
  /// the failure count and restores `online` immediately.
  ///
  /// This is the cheap half of staying honest: the app makes real requests all
  /// the time, and every one that comes back is better evidence than any probe.
  /// Previously only *failures* were reported, so the service could sit offline
  /// while responses were arriving.
  void reportSuccess() {
    if (_disposed) return;
    _failures = 0;
    _cancelRecheck();
    _set(true);
  }

  /// Report a failure observed by a normal request as evidence we may be
  /// offline. Cheap to call; it just schedules a re-probe.
  void reportFailure() => unawaited(refresh());

  /// Test seams for the two things this state machine depends on that a unit
  /// test cannot provide: the platform's link status and a live backend. The
  /// asymmetry between going offline and coming back is the part that broke in
  /// the field, so it is worth being able to drive it deterministically.
  @visibleForTesting
  Future<bool> Function()? linkProbe;
  @visibleForTesting
  Future<bool> Function()? reachabilityProbe;

  Future<bool> _hasLink() async {
    final override = linkProbe;
    if (override != null) return override();
    final results = await _connectivity.checkConnectivity();
    return results.any((r) => r != ConnectivityResult.none);
  }

  Future<bool> _evaluate() async {
    try {
      final hasLink = await _hasLink();
      if (!hasLink) {
        _failures = _failuresBeforeOffline;
        _set(false);
        // Still poll: a link can come back without a reliable platform event.
        _scheduleRecheck();
        return false;
      }
      if (await _reachable()) {
        _failures = 0;
        _cancelRecheck();
        _set(true);
        return true;
      }
      _failures++;
      // Hysteresis: one bad probe on a live link is not enough to tear down a
      // working session. Keep the current state and look again shortly.
      if (_failures >= _failuresBeforeOffline) _set(false);
      _scheduleRecheck();
      return online.value;
    } catch (_) {
      // Couldn't tell — leave the last known value, but keep looking.
      _scheduleRecheck();
      return online.value;
    }
  }

  Future<bool> _reachable() async {
    final override = reachabilityProbe;
    if (override != null) return override();
    final base = ApiService.baseUrl;
    try {
      final res =
          await http.get(Uri.parse('$base/ping/')).timeout(_probeTimeout);
      // Any HTTP response — even 404 from an older backend without /ping/ —
      // proves the server is reachable. A 5xx means we reached the tunnel but
      // the app behind it is down, which is not usable, so it counts as offline.
      return res.statusCode < 500;
    } catch (_) {
      return false;
    }
  }

  /// Keep probing on our own while we believe we are offline.
  ///
  /// Without this the service is only ever nudged by a link-change event or a
  /// failing request — and while `online` is false the read layer makes no
  /// requests at all, so neither happens. See the class doc.
  void _scheduleRecheck() {
    if (_disposed) return;
    _recheck?.cancel();
    final delay =
        _recheckBackoff[math.min(_recheckStep, _recheckBackoff.length - 1)];
    _recheckStep++;
    _recheck = Timer(delay, () {
      if (!_disposed) unawaited(refresh());
    });
  }

  void _cancelRecheck() {
    _recheck?.cancel();
    _recheck = null;
    _recheckStep = 0;
  }

  void _set(bool value) {
    if (online.value != value) online.value = value;
  }

  /// Test seam: drop all timers/subscriptions and reset the state machine so one
  /// test's backoff can't leak into the next.
  @visibleForTesting
  void resetForTest({bool onlineValue = true}) {
    _cancelRecheck();
    _probe = null;
    _failures = 0;
    linkProbe = null;
    reachabilityProbe = null;
    online.value = onlineValue;
  }

  /// Consecutive failed probes recorded so far — the hysteresis counter.
  @visibleForTesting
  int get failureCount => _failures;

  /// Whether a self-recheck is armed. While offline this must be true, or the
  /// app can never notice that the network came back on its own.
  @visibleForTesting
  bool get hasPendingRecheck => _recheck?.isActive ?? false;

  void dispose() {
    _disposed = true;
    _cancelRecheck();
    _sub?.cancel();
    _sub = null;
  }
}
