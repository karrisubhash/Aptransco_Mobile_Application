import 'dart:async';
import 'dart:math' as math;

import '../../models/li_asset.dart';
import '../../models/li_records.dart';
import '../../models/li_session.dart';
import '../line_inspection_api.dart';
import 'connectivity_service.dart';
import 'local_store.dart';
import 'photo_cache.dart';
import 'tile_cache.dart';

/// Keeps the device quietly stocked with whatever the app would need if the
/// signal disappeared — with no button, no progress bar and no storage settings.
///
/// This is the feed-app model rather than the map-app model. Instagram never
/// asks you to download your feed: it renders whatever is already on disk the
/// instant you open it, revalidates behind that, and spends idle network time
/// pulling down the posts and images you are *about* to reach. Storage is a
/// cache with a budget, not a download the user owns and has to manage.
///
/// So the warmer:
///  * runs only on its own triggers — app start, reconnect, resume, after a sync
///    and on an idle timer — never because the user asked;
///  * is **incremental**: every pass fetches only what is missing or stale and
///    stops at a per-pass budget, so it is a trickle rather than a burst;
///  * is **silent**: a failure is simply less cache, never an error the user
///    sees, and never a reason to retry aggressively;
///  * **yields**: it paces itself between requests so foreground reads (the tab
///    the user is actually looking at) always win the connection.
///
/// The read layer does the real work — every `read*` call writes its response
/// through to the same cache key the screen reads — so warming is just making
/// those calls early, on purpose, at a polite pace.
class CacheWarmer {
  CacheWarmer._();
  static final CacheWarmer instance = CacheWarmer._();

  /// Pause between warm requests. Long enough that the warmer never competes
  /// with the screen in front of the user, short enough to finish a jurisdiction
  /// over a few minutes of ordinary use.
  static const Duration _pace = Duration(milliseconds: 150);

  /// How long a completed pass is left alone before the idle timer runs another.
  static const Duration _idlePeriod = Duration(minutes: 10);

  /// Inspection details (and their photos) pulled per pass. Bounded so a large
  /// jurisdiction fills in over several passes instead of one long stall.
  static const int _detailsPerPass = 40;

  /// Newest inspections considered for offline detail+photo warming at all.
  /// Beyond this, an engineer is looking at history they will have signal for.
  static const int _detailHorizon = 300;

  /// Map tiles fetched per pass. The corridor set is large, so it is filled in
  /// a slice at a time across passes — the map is already usable from whatever
  /// the user has panned over, and this closes the gaps in the background.
  static const int _tilesPerPass = 300;

  /// Zoom band worth pre-warming: corridor overview through working detail.
  static const int _minZoom = 12;
  static const int _maxZoom = 16;

  LiSession? _session;
  bool _started = false;
  bool _running = false;
  bool _rerun = false;
  Timer? _idleTimer;
  DateTime? _lastPassAt;

  /// True while a pass is in flight — exposed for tests, not for the UI. The
  /// whole point is that the user never learns this is happening.
  bool get isWarming => _running;

  /// Begin warming for [session]. Idempotent; a second call just updates the
  /// session (e.g. after the jurisdiction picker changes scope).
  void start(LiSession session) {
    _session = session;
    if (!_started) {
      _started = true;
      ConnectivityService.instance.online.addListener(_onOnlineChanged);
    }
    kick();
  }

  /// Stop warming and forget the session — called on sign-out so a warm pass
  /// can't keep pulling the previous user's jurisdiction.
  void stop() {
    _session = null;
    _rerun = false;
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_started) {
      ConnectivityService.instance.online.removeListener(_onOnlineChanged);
      _started = false;
    }
  }

  void _onOnlineChanged() {
    // Coming back into coverage is the single best moment to top up.
    if (ConnectivityService.instance.online.value) kick();
  }

  /// Called when the app returns to the foreground.
  void onResume() => kick();

  /// Fire-and-forget warm pass. Never awaited by the UI.
  void kick() {
    if (!_ok) return;
    if (_running) {
      _rerun = true;
      return;
    }
    unawaited(_pass());
  }

  /// Prefetch the photos behind [summaries] — called by a list as it loads, so
  /// opening one of those rows is instant and survives losing signal.
  ///
  /// This is the scroll-ahead half of the model: the list itself carries no
  /// photo reference (see [InspectionSummary]), so reaching the media means
  /// reading each detail first. Both steps are cache-first, so rows already
  /// warmed cost nothing.
  void prefetchForList(List<InspectionSummary> summaries, {int limit = 24}) {
    if (!_ok) return;
    final ids = [
      for (final s in summaries)
        if (s.id > 0) s.id,
    ].take(limit).toList();
    if (ids.isEmpty) return;
    unawaited(_warmDetails(ids));
  }

  // ---- the pass ------------------------------------------------------------

  Future<void> _pass() async {
    _running = true;
    _rerun = false;
    try {
      await _warmRecords();
      if (!_ok) return;
      final lines = await _warmMasterData();
      if (!_ok) return;
      await _warmRecentDetails();
      if (!_ok) return;
      await _warmCorridorTiles(lines);
      _lastPassAt = DateTime.now();
    } catch (_) {
      // Warming is best-effort by definition; a failure just means the next
      // trigger tries again.
    } finally {
      _running = false;
      if (_rerun && _ok) {
        _rerun = false;
        unawaited(_pass());
      } else {
        _scheduleIdlePass();
      }
    }
  }

  /// Whether it is still worth continuing: a session, a usable link, and
  /// somewhere to put what we fetch.
  ///
  /// The store check is not paranoia — without it the warmer would happily spend
  /// the network on responses it has nowhere to write, and would start firing
  /// real requests inside any widget test that mounts the hub.
  bool get _ok =>
      _session != null &&
      LocalStore.instance.isReady &&
      ConnectivityService.instance.online.value;

  /// One warm step: run [fetch], swallow anything it throws, then pace.
  Future<void> _step(Future<void> Function() fetch) async {
    if (!_ok) return;
    try {
      await fetch();
    } catch (_) {
      // Less cache, never an error.
    }
    await Future<void>.delayed(_pace);
  }

  /// The lists every non-map tab reads. Each entry is the same call the tab
  /// makes, so it lands on the cache key that tab will look in — going through
  /// the identical call is what stops the two from drifting apart.
  Future<void> _warmRecords() async {
    final sub = _session?.scopeSubdivisionId;
    final me = _session?.employeeId;
    await _step(() => LineInspectionApi.loadInspections()); // History
    await _step(() => LineInspectionApi.loadDashboard()); // KPI strip + coverage
    await _step(() =>
        LineInspectionApi.loadTickets(status: 'open', subdivision: sub));
    await _step(() =>
        LineInspectionApi.loadTickets(status: 'closed', subdivision: sub));
    await _step(() => LineInspectionApi.loadTickets(subdivision: sub));
    await _step(() => LineInspectionApi.loadSupportRequests(subdivision: sub));
    await _step(() => LineInspectionApi.loadSubdivisions());
    await _step(() => LineInspectionApi.loadCatalog()); // the form opens offline
    if (sub != null) {
      await _step(() => LineInspectionApi.loadDashboard(subdivision: sub));
    }
    if (me != null && me.isNotEmpty) {
      await _step(() => LineInspectionApi.loadInspections(inspector: me));
    }
  }

  /// Assigned lines and, for each, its towers and inspection colours — what the
  /// Home map draws and what near-me ranking reads with no signal. Returns the
  /// tower coordinates gathered, for the tile pass.
  Future<List<List<double>>> _warmMasterData() async {
    final points = <List<double>>[];
    List<LiLine> lines;
    try {
      lines = await LineInspectionApi.searchLines('');
    } catch (_) {
      return points;
    }
    for (final line in lines) {
      if (!_ok) break;
      await _step(() async {
        final towers = await LineInspectionApi.towersForLine(line.id);
        for (final t in towers) {
          if (t.latitude != null && t.longitude != null) {
            points.add([t.latitude!, t.longitude!]);
          }
        }
      });
      await _step(() => LineInspectionApi.loadInspections(line: line.id));
    }
    return points;
  }

  /// The newest inspections' full records and photos, so tapping a recent row
  /// offline shows the same page it shows online — evidence included.
  Future<void> _warmRecentDetails() async {
    List<InspectionSummary> summaries;
    try {
      summaries = await LineInspectionApi.loadInspections();
    } catch (_) {
      return;
    }
    // Server-side ids only: a negative id is a local, not-yet-synced inspection
    // whose photos are already staged on disk.
    final ids = [
      for (final s in summaries.take(_detailHorizon))
        if (s.id > 0) s.id,
    ];
    await _warmDetails(ids, budget: _detailsPerPass);
  }

  /// Warm [ids]' details and photos, skipping what is already on disk, and
  /// stopping after [budget] *newly fetched* details so a pass stays a trickle.
  Future<void> _warmDetails(List<int> ids, {int? budget}) async {
    var fetched = 0;
    for (final id in ids) {
      if (!_ok) return;
      if (budget != null && fetched >= budget) return;
      InspectionDetail detail;
      try {
        // Cache-first: a saved inspection never changes, so one already on disk
        // costs a file read and no round trip. That is what keeps repeat passes
        // cheap — they fetch only what is genuinely new.
        final read = await LineInspectionApi.readInspectionDetail(id);
        final wasCached = read.hasCached;
        detail = await read.value;
        if (!wasCached) {
          fetched++;
          await Future<void>.delayed(_pace);
        }
      } catch (_) {
        continue;
      }
      for (final ref in _photoRefs(detail)) {
        if (!_ok) return;
        final url = LineInspectionApi.mediaUrl(ref);
        if (await PhotoCache.instance.has(url)) continue;
        await PhotoCache.instance.prefetchPinned(url);
        await Future<void>.delayed(_pace);
      }
    }
  }

  /// Every server-side photo path in an inspection: the per-item photos and the
  /// per-defect-entry ones. `local://` refs are already on disk.
  static Iterable<String> _photoRefs(InspectionDetail detail) sync* {
    for (final item in detail.itemResults) {
      final p = item.photo;
      if (p != null && p.isNotEmpty && !p.startsWith('local://')) yield p;
      for (final e in item.entries) {
        final ep = e.photo;
        if (ep != null && ep.isNotEmpty && !ep.startsWith('local://')) yield ep;
      }
    }
  }

  /// Fill in base-map tiles over the assigned corridors, a slice per pass.
  ///
  /// The map already caches whatever the engineer pans across; this closes the
  /// gaps they haven't looked at yet. Both layers are warmed, because the map's
  /// satellite toggle has to work offline too — a control that works online and
  /// shows blank squares offline is exactly the kind of gap this class exists to
  /// remove.
  Future<void> _warmCorridorTiles(List<List<double>> points) async {
    if (points.isEmpty) return;
    final bbox = _bboxOf(points);
    var fetched = 0;
    for (var z = _minZoom; z <= _maxZoom; z++) {
      final x0 = _lonToX(bbox[1], z), x1 = _lonToX(bbox[3], z);
      final y0 = _latToY(bbox[2], z), y1 = _latToY(bbox[0], z);
      for (var x = math.min(x0, x1); x <= math.max(x0, x1); x++) {
        for (var y = math.min(y0, y1); y <= math.max(y0, y1); y++) {
          for (final template in const [_streetTiles, _satelliteTiles]) {
            if (!_ok || fetched >= _tilesPerPass) return;
            final url = template
                .replaceFirst('{z}', '$z')
                .replaceFirst('{x}', '$x')
                .replaceFirst('{y}', '$y');
            if (await TileCache.instance.hasTile(url)) continue;
            await TileCache.instance.prefetchPinned(url, _tileHeaders);
            fetched++;
            await Future<void>.delayed(_pace);
          }
        }
      }
    }
  }

  static const String _streetTiles =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String _satelliteTiles =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  static const Map<String, String> _tileHeaders = {
    'User-Agent': 'com.aptransco.data_collection',
  };

  void _scheduleIdlePass() {
    _idleTimer?.cancel();
    if (_session == null) return;
    _idleTimer = Timer(_idlePeriod, kick);
  }

  /// When the last full pass completed — exposed for tests/diagnostics.
  DateTime? get lastPassAt => _lastPassAt;

  // ---- bbox + slippy-tile math --------------------------------------------

  /// [minLat, minLng, maxLat, maxLng] with a small margin.
  static List<double> _bboxOf(List<List<double>> pts) {
    var minLat = 90.0, maxLat = -90.0, minLng = 180.0, maxLng = -180.0;
    for (final p in pts) {
      minLat = math.min(minLat, p[0]);
      maxLat = math.max(maxLat, p[0]);
      minLng = math.min(minLng, p[1]);
      maxLng = math.max(maxLng, p[1]);
    }
    const m = 0.01; // ~1 km margin so the corridor edges aren't clipped
    return [minLat - m, minLng - m, maxLat + m, maxLng + m];
  }

  static int _lonToX(double lon, int z) =>
      ((lon + 180.0) / 360.0 * (1 << z)).floor();

  static int _latToY(double lat, int z) {
    final r = lat * math.pi / 180.0;
    return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z))
        .floor();
  }
}
