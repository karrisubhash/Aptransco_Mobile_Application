import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../../models/li_session.dart';
import '../../models/li_asset.dart';
import '../../models/li_records.dart';
import '../../services/line_inspection_api.dart';
import '../../services/location_service.dart';
import '../../services/offline/connectivity_service.dart';
import '../../services/offline/outbox.dart';
import '../../services/offline/sync_engine.dart';
import '../../services/offline/tile_cache.dart';
import '../../utils/li_style.dart';
import '../../utils/line_geometry.dart';
import '../../widgets/inspect_launcher.dart';
import '../../widgets/map_dots.dart';
import '../../widgets/map_overlays.dart';

/// Home: the field engineer's whole workflow, so there is no separate Inspect
/// tab. It maps the user's assigned lines — towers coloured by their inspection
/// state ([TowerState]: grey not inspected, orange inspected but still queued in
/// the offline outbox, green inspected and on the server) — and streams the
/// device's location. Towers inside the presence radius are ringed, so the map
/// itself says which is inspectable without an override.
///
/// How it opens depends on the cadre, because the two jobs are different (see
/// [LiSession.opensAtNearestTower]). A field engineer (AEE, EE) works at one
/// structure, so Home opens **at the assigned tower nearest to them**, at working
/// zoom; seeing the rest of the line is a deliberate zoom out. A supervisor
/// (DEE, SE) or admin works across lines, so Home opens on the **fitted overview
/// of everything in scope** and never jumps to a single tower. Either way the
/// camera is placed once and then left alone — there is no tower list competing
/// with the map.
///
/// Tapping a tower opens its details with its live distance; Inspect there runs
/// the presence gate ([launchInspection]) and opens the form. Everything works
/// offline once the jurisdiction has been downloaded — GPS needs no signal.
///
/// Until the first load lands the tab shows the plain branded loading state and
/// no map at all: an empty basemap dimmed behind a spinner looked like a broken
/// map. Afterwards it reloads on the same pull-down gesture as Tickets and
/// History, bound to the KPI bar across the top — see [_pullBandHeight].
class HomeTab extends StatefulWidget {
  const HomeTab({super.key, required this.session});
  final LiSession session;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

/// Below this zoom the map shows line corridors only, with no tower pins.
///
/// Chosen from the geometry rather than by eye. Towers on a transmission line
/// sit roughly 350 m apart, and at this latitude a tile pixel covers
/// `156543 · cos(lat) / 2^zoom` metres — so the on-screen gap between two
/// neighbouring towers is about 9 px at zoom 12, 5 px at zoom 11, and 2 px at
/// zoom 10. The pin drawn for each is 6 px at that end of [TowerPin]'s ramp.
///
/// Once the gap is smaller than the pin, the pins stop being individual markers:
/// they overlap into a dotted smear along the corridor, which is exactly what
/// the corridor polyline already draws — only worse, because it costs a marker
/// per tower and invites taps on a target the user cannot actually aim at. Zoom
/// 12 is where the two stop competing.
const double kTowerPinMinZoom = 12;

/// Whether individual tower pins are worth drawing at [zoom].
///
/// Top-level and pure so the threshold can be tested without building a map —
/// the same treatment [ticketsForTriage] and `groupHistoryByDay` get.
bool showTowerPinsAt(double zoom) => zoom >= kTowerPinMinZoom;

/// One load's worth of map data, gathered in a single wave.
class _MapData {
  const _MapData({
    required this.towers,
    required this.corridors,
    required this.worst,
    required this.awaitingSync,
    required this.dash,
  });

  final List<LiTower> towers;
  final List<LineCorridor> corridors;
  final Map<int, String> worst;
  final Set<int> awaitingSync;
  final DashboardData? dash;
}

class _HomeTabState extends State<HomeTab>
    with TickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  final MapController _map = MapController();
  final CachedTileProvider _tiles = CachedTileProvider();

  // Home holds the map, the tile cache and the GPS stream, so it is kept alive
  // when another tab is on screen: coming back is instant and lands on the same
  // camera the engineer left, rather than re-fitting and re-fetching tiles.
  @override
  bool get wantKeepAlive => true;

  static const _street = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const _satellite =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
  bool _sat = false;

  /// Zoom Home opens at on the nearest tower: close enough to tell adjacent
  /// towers apart and to judge the 50 m presence radius by eye. Zooming out to
  /// see the rest of the line is left to the engineer.
  static const double _nearestTowerZoom = 17;

  /// Where the camera starts before any fix or fit — the whole state.
  static const double _overviewZoom = 7;

  /// The zoom range both tile sets actually serve. Set on [MapOptions] so it
  /// binds gestures as well as programmatic moves.
  static const double _minZoom = 3;
  static const double _maxZoom = 19;

  /// Smallest zoom change worth rebuilding the markers for. The pin ramp is
  /// continuous, so quantising it this coarsely is imperceptible but keeps a
  /// pinch from rebuilding every tower on every frame.
  static const double _zoomRebuildStep = 0.2;

  List<LiTower> _towers = const [];

  /// Worst recorded criticality per tower — the tower sheet's severity chip. The
  /// pins no longer read from this; see [_stateFor].
  Map<int, String> _worst = const {};

  /// Towers with an inspection still sitting in the offline outbox, read from the
  /// queue itself rather than from the cached summaries.
  ///
  /// The queue is the only honest answer to "has this left the phone?": a cached
  /// summary is optimistic (`OfflineActions` writes one the moment Save is
  /// pressed) and an online read overwrites the whole cached list with the
  /// server's, which would drop a row whose upload is still queued or parked as
  /// failed.
  Set<int> _awaitingSync = const {};

  DashboardData? _dash;
  bool _loading = true;
  String? _error;

  /// Height of the pull-to-refresh band along the top of the map.
  ///
  /// A [RefreshIndicator] needs a scrollable to hear overscroll from, and on this
  /// tab that cannot be the map: a vertical drag on a map pans it, which is the
  /// whole point of a map. So the gesture is bound to a band across the top with
  /// the KPI bar inside it — the bar *is* the handle you pull down, and the map
  /// below keeps every one of its own gestures.
  ///
  /// This is the band the *arc* needs, not the part that takes the drag: a
  /// [RefreshIndicator] draws the arc inside a clipping [Stack] of its own, so the
  /// box has to be tall enough to hold the arc at its resting
  /// [_pullDisplacement]. Only [_pullHandleHeight] of it absorbs pointers.
  static const double _pullBandHeight = 124;

  /// The part of the band that takes the drag — the KPI bar and a little slack
  /// around it. Everything below this is empty and hit-transparent, so the map
  /// keeps it: pan, zoom and tapping a tower all still work there.
  static const double _pullHandleHeight = 70;

  /// Where the arc comes to rest while refreshing: just below the handle, so it
  /// clears the KPI bar instead of sitting across the figures. (A large system
  /// font scale grows the bar into it; the arc is transient, so it overlaps rather
  /// than being given room that would cost the map another 20 px permanently.)
  static const double _pullDisplacement = 70;

  /// The arc's own box, at [RefreshProgressIndicator]'s default size. Named only
  /// so the relationship between the three can be asserted in [initState]: raise
  /// the displacement past the band and the arc is clipped away silently, since a
  /// clipped spinner does not look wrong — it simply never appears.
  static const double _pullArcSize = 49;

  // Live position, streamed for the whole session: it picks the tower Home opens
  // at, rings the ones in presence range and feeds the gate. GPS works with no
  // mobile data, so this keeps working offline.
  StreamSubscription<Position>? _posSub;
  LatLng? _me;
  double? _accuracy;
  String? _gpsError;

  bool _mapReady = false;
  List<LatLng>? _pending;
  // Drives tower pin size. Tracked in state (not read straight off the camera)
  // so a zoom change rebuilds the markers.
  double _zoom = _overviewZoom;
  // The camera is placed once — on the nearest tower if there is a fix, else
  // fitted to all assigned lines. Later reloads (a sync, or a return from the
  // inspection form) must not yank it away from where the engineer left it.
  bool _fitted = false;
  bool _cameraPlaced = false;

  /// Whether Home opens on the single tower nearest the user, rather than on the
  /// fitted overview of everything in scope.
  ///
  /// AEE and EE walk to a structure and get the nearest tower at working zoom;
  /// DEE, SE and admins supervise whole lines and get the overview. The rule and
  /// the reasoning live on the session, where they can be tested without a map —
  /// see [LiSession.opensAtNearestTower].
  bool get _opensAtNearestTower => widget.session.opensAtNearestTower;

  /// The corridor polylines, held as a already-built widget rather than as data.
  ///
  /// This is deliberate and load-bearing for performance: flutter_map's polyline
  /// layer throws away its projection and simplification caches in
  /// `didUpdateWidget`, which fires whenever the parent rebuilds. Handing Flutter
  /// the *identical* widget object short-circuits that, so a corridor is
  /// projected once per load instead of on every GPS fix and every zoom step.
  Widget? _corridorLayer;

  /// Tower ids currently inside the presence radius, so the marker builder can
  /// answer "ring this one?" with a set lookup.
  ///
  /// Previously each build ran a haversine per tower; with a fix arriving every
  /// 5 m of walking and a supervisor holding thousands of towers, that was an
  /// O(towers) trigonometry sweep per frame. Recomputed only when the engineer
  /// has actually moved [_inRangeRecomputeM], which makes the ring at most that
  /// stale — acceptable because it is a hint, and [launchInspection] re-measures
  /// the real distance when Inspect is actually pressed.
  Set<int> _inRange = const {};
  LatLng? _inRangeFrom;
  static const double _inRangeRecomputeM = 10;

  /// The map's bearing, in degrees, fed from `onMapEvent`.
  ///
  /// `MapController.rotate` does not fire `onPositionChanged`, so the compass
  /// cannot be driven from [_onCameraMoved] — a pure rotation would leave the
  /// needle frozen.
  double _bearing = 0;

  /// The tower whose sheet is open, drawn with a halo so the map does not lose
  /// the pin the engineer just tapped.
  int? _selectedId;

  /// Runs the eased camera moves. Only the short, user-initiated moves are
  /// animated ([_locate], [_zoomBy]); the opening placement stays an instant cut
  /// because it can span a whole jurisdiction, and flying that would be a long
  /// distraction rather than a nicety.
  AnimationController? _fly;
  bool _flying = false;

  @override
  void initState() {
    super.initState();
    assert(_pullDisplacement + _pullArcSize <= _pullBandHeight,
        'the refresh arc would be clipped by the pull band');
    assert(_pullHandleHeight <= _pullBandHeight,
        'the pull handle cannot be taller than the band holding it');
    SyncEngine.instance.dataRevision.addListener(_reload);
    _load();
    _startGps();
  }

  @override
  void dispose() {
    SyncEngine.instance.dataRevision.removeListener(_reload);
    _posSub?.cancel();
    _fly?.dispose();
    _map.dispose();
    super.dispose();
  }

  /// A sync landed, so the server now holds something this map does not — go
  /// past the read layer's freshness window and take the authoritative copy.
  Future<void> _reload() async {
    if (mounted) _load(force: true);
  }

  /// Guards against an older load's results landing on top of a newer one's.
  int _loadGen = 0;

  /// Fills the map, in two passes.
  ///
  /// The first pass reads only what is already on the device, so the map draws in
  /// milliseconds — this is what the engineer actually waits for. The second goes
  /// to the server for everything at once and swaps in whatever came back newer;
  /// when nothing did (a tab switch, a return from the form) it costs no requests
  /// at all and the screen never flickers.
  ///
  /// [force] ignores the freshness window — used after a save or a sync, when the
  /// server is known to have moved on.
  ///
  /// Returns null when the load succeeded, or the failure to report when it did
  /// not. A drawn map is kept on failure (see below), so the message is the only
  /// way [_refresh] can tell the engineer their press did not land.
  Future<String?> _load({bool force = false}) async {
    final gen = ++_loadGen;
    if (_towers.isEmpty) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final onDevice = await _gather(force: false, allowNetwork: false);
      if (gen != _loadGen || !mounted) return null;
      if (onDevice != null) _apply(onDevice);

      final fromServer = await _gather(force: force, allowNetwork: true);
      if (gen != _loadGen || !mounted) return null;
      // null means the network had nothing newer than what is already up.
      if (fromServer != null) _apply(fromServer);
      if (_loading || _error != null) {
        setState(() {
          _loading = false;
          _error = null;
        });
      }
      return null;
    } catch (e) {
      if (gen != _loadGen || !mounted) return null;
      setState(() {
        _loading = false;
        // A failed refresh must not take away a map that is already drawn: it
        // still works offline, and GPS needs no signal. Only speak up when there
        // is nothing to show.
        if (_towers.isEmpty) _error = '$e';
      });
      return '$e';
    }
  }

  /// What the pull-down gesture runs. The arc keeps spinning until this returns,
  /// so it is awaited rather than fired off.
  ///
  /// Forced, because pulling is a request for the server's answer, not for
  /// whatever still sits inside the read layer's freshness window — the same
  /// meaning the pull has on Tickets and History. A failure is surfaced here:
  /// with a map already drawn [_load] keeps it standing and sets no error, so
  /// nothing else would tell the engineer the refresh did not land.
  Future<void> _refresh() async {
    final failure = await _load(force: true);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (failure != null) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not refresh: $failure')),
      );
      return;
    }
    // Nothing failed, but nothing was fetched either: offline, the read layer
    // quietly keeps the cached copy rather than erroring. Left unsaid, the press
    // would look like it did nothing at all.
    if (!ConnectivityService.instance.online.value) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Offline — showing your saved copy')),
      );
    }
  }

  /// One wave of reads: every assigned line's towers and inspection summaries,
  /// the KPI rollup and the offline outbox, all in flight together.
  ///
  /// These used to be four waves, each waiting on the one before it — the lines,
  /// then the towers, then the summaries, then the dashboard — so opening Home
  /// cost four round trips end to end instead of one.
  ///
  /// Returns null when there is nothing worth applying: on the disk pass, when
  /// nothing has been cached yet; on the network pass, when every read came back
  /// unchanged.
  Future<_MapData?> _gather({
    required bool force,
    required bool allowNetwork,
  }) async {
    var gotFresh = false;

    /// The best answer for one read, preferring the server's when it brought one.
    /// A single line failing (not cached offline, or refused) must not cost the
    /// whole map, so a failure here is null rather than an exception.
    Future<T?> best<T>(Future<CacheRead<T>> read) async {
      try {
        final r = await read;
        if (!allowNetwork) return r.cached;
        final fresh = await r.fresh;
        if (fresh == null) return r.cached;
        gotFresh = true;
        return fresh;
      } catch (_) {
        return null;
      }
    }

    // The line list is not optional — without it there is no map, and its
    // failure is the one the engineer needs to read (e.g. offline, never synced).
    final linesRead =
        await LineInspectionApi.readLines(force: force, allowNetwork: allowNetwork);
    List<LiLine>? lines;
    if (allowNetwork) {
      final fresh = await linesRead.fresh;
      if (fresh != null) {
        gotFresh = true;
        lines = fresh;
      } else {
        lines = linesRead.cached;
      }
    } else {
      lines = linesRead.cached;
    }
    if (lines == null) return null;

    final towerReads = [
      for (final l in lines)
        best(LineInspectionApi.readTowersForLine(l.id,
            force: force, allowNetwork: allowNetwork)),
    ];
    final inspReads = [
      for (final l in lines)
        best(LineInspectionApi.readInspections(line: l.id,
            force: force, allowNetwork: allowNetwork)),
    ];
    final dashRead = best(LineInspectionApi.readDashboard(
        force: force, allowNetwork: allowNetwork));
    // Always local, so it is never a reason to consider the pass fruitful.
    final awaitingRead = _awaitingSyncTowerIds();

    final towerLists = [
      for (final t in await Future.wait(towerReads)) t ?? const <LiTower>[],
    ];
    final inspLists = await Future.wait(inspReads);
    final dash = await dashRead;
    final awaiting = await awaitingRead;

    if (allowNetwork && !gotFresh) return null;

    final worst = <int, String>{};
    for (final list in inspLists) {
      for (final s in list ?? const <InspectionSummary>[]) {
        worst[s.towerId] = s.worst;
      }
    }
    return _MapData(
      towers: [for (final list in towerLists) ...list],
      // Keep the per-line grouping this fetch already produced. Flattening it
      // away was the only reason the map could not draw the lines themselves —
      // the server returns each line's towers in schedule order, which is
      // exactly what a corridor is chained from.
      corridors: buildCorridors([
        for (var i = 0; i < lines.length; i++)
          (line: lines[i], towers: towerLists[i]),
      ]),
      worst: worst,
      awaitingSync: awaiting,
      dash: dash,
    );
  }

  /// Towers with an inspection still sitting in the offline outbox. Cheap — a
  /// directory of small JSON files, and empty in the common case. Failed ops
  /// count as waiting too: parked is still "not on the server".
  Future<Set<int>> _awaitingSyncTowerIds() async {
    final ids = <int>{};
    for (final op in await OutboxStore.instance.list()) {
      if (op.type != OpType.inspection) continue;
      final id = op.payload['tower_id'];
      if (id is int) ids.add(id);
    }
    return ids;
  }

  void _apply(_MapData data) {
    setState(() {
      _towers = data.towers;
      _worst = data.worst;
      _awaitingSync = data.awaitingSync;
      // A failed rollup must not blank out KPIs that are already on screen.
      _dash = data.dash ?? _dash;
      // Built once per load, then handed to Flutter unchanged on every
      // subsequent build — see [_corridorLayer].
      _corridorLayer = _buildCorridorLayer(data.corridors);
      _loading = false;
    });
    // The tower set just changed, so the cached in-range answer is stale.
    final fix = _me;
    if (fix != null) {
      _inRangeFrom = null;
      _refreshInRange(fix);
    }
    // Place the camera now the towers are in: on the nearest one if a fix has
    // already arrived (it may have beaten this load, and a stationary device
    // emits no further fix to retry on), otherwise fit the assigned lines
    // until one does. Both no-op once the camera has been placed.
    final me = _me;
    if (me != null) _enterAtNearestTower(me);
    _fit();
  }

  /// The corridor strokes for [corridors], or null when no line qualified.
  ///
  /// Each corridor is drawn twice: a translucent dark casing, then the
  /// voltage-coloured core on top. flutter_map punches the core out of the
  /// casing, so this gives every line its own contrast instead of depending on
  /// the basemap — a thin saturated stroke is invisible over bright satellite
  /// imagery otherwise.
  Widget? _buildCorridorLayer(List<LineCorridor> corridors) {
    if (corridors.isEmpty) return null;
    return PolylineLayer(
      polylines: [
        for (final c in corridors)
          Polyline(
            points: c.points,
            color: voltageColor(c.voltage),
            strokeWidth: voltageStroke(c.voltage),
            borderColor: kCorridorCasing.withValues(alpha: kCorridorCasingAlpha),
            borderStrokeWidth: kCorridorCasingWidth,
          ),
      ],
    );
  }

  /// Recomputes [_inRange] if the engineer has moved far enough for the answer to
  /// have changed. A cheap latitude/longitude box rejects the vast majority of
  /// towers before any trigonometry runs.
  void _refreshInRange(LatLng here) {
    final from = _inRangeFrom;
    if (from != null &&
        LocationService.distanceTo(from, here.latitude, here.longitude) <
            _inRangeRecomputeM) {
      return;
    }
    // Pad the box by the recompute step so a tower cannot slip in between
    // refreshes. ~111 km per degree of latitude.
    final pad = (kPresenceRadiusM + _inRangeRecomputeM) / 111000;
    final lngPad = pad / math.max(0.01, math.cos(here.latitude * math.pi / 180));
    final next = <int>{};
    for (final t in _towers) {
      final lat = t.latitude;
      final lng = t.longitude;
      if (lat == null || lng == null) continue;
      if ((lat - here.latitude).abs() > pad) continue;
      if ((lng - here.longitude).abs() > lngPad) continue;
      if (LocationService.distanceTo(here, lat, lng) <= kPresenceRadiusM) {
        next.add(t.id);
      }
    }
    _inRangeFrom = here;
    final changed =
        next.length != _inRange.length || !next.containsAll(_inRange);
    if (changed) {
      _inRange = next;
      if (mounted) setState(() {});
    }
  }

  /// Eases the camera to [target]/[zoom]. Used only for the short moves the
  /// engineer asks for; see [_fly].
  ///
  /// [_flying] suppresses the pin-resizing rebuild in [_onCameraMoved] for the
  /// duration, so a 250 ms ease costs one marker rebuild at the end rather than
  /// one per frame.
  void _flyTo(LatLng target, double zoom) {
    if (!_mapReady) return;
    final cam = _map.camera;
    final fromLat = cam.center.latitude;
    final fromLng = cam.center.longitude;
    final fromZoom = cam.zoom;
    _fly?.dispose();
    _flying = true;
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
    );
    _fly = ctrl;
    final curve = CurvedAnimation(parent: ctrl, curve: Curves.easeOutCubic);
    void tick() {
      if (!mounted || !_mapReady) return;
      final t = curve.value;
      _map.move(
        LatLng(fromLat + (target.latitude - fromLat) * t,
            fromLng + (target.longitude - fromLng) * t),
        fromZoom + (zoom - fromZoom) * t,
      );
    }

    curve.addListener(tick);
    ctrl.addStatusListener((s) {
      if (s != AnimationStatus.completed && s != AnimationStatus.dismissed) return;
      _flying = false;
      if (mounted) _onCameraMoved(_map.camera, false);
    });
    ctrl.forward();
  }

  /// Fits everything in scope — the lines themselves, corridors and all. This is
  /// the opening view for DEE, SE and admins, who work across whole lines; for an
  /// AEE or EE it is only the fallback, held until (or unless) a fix lets Home
  /// open on the nearest tower.
  void _fit() {
    if (_fitted || _cameraPlaced) return;
    final pts = <LatLng>[
      for (final t in _towers)
        if (t.latitude != null && t.longitude != null)
          LatLng(t.latitude!, t.longitude!),
    ];
    if (pts.isEmpty) return;
    _fitted = true;
    _pending = pts;
    _applyCamera();
  }

  void _applyCamera() {
    if (!_mapReady || _pending == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_mapReady) return;
      final pts = _pending;
      if (pts == null) return;
      _pending = null;
      if (pts.length == 1) {
        _map.move(pts.first, 14);
      } else {
        _map.fitCamera(CameraFit.coordinates(
            coordinates: pts, padding: const EdgeInsets.all(56)));
      }
    });
  }

  /// Starts (or restarts, after a failure) the live position stream that decides
  /// which tower Home opens at. A failure is not fatal: the map falls back to the
  /// fitted overview, and inspecting falls to the audited no-fix override.
  Future<void> _startGps() async {
    await _posSub?.cancel();
    _posSub = null;
    try {
      await LocationService.ensureReady();
      _onFix(await LocationService.currentFix());
      _posSub = LocationService.positionStream().listen(
        _onFix,
        onError: (e) {
          if (mounted) setState(() => _gpsError = '$e');
        },
      );
    } on LocationUnavailable catch (e) {
      if (mounted) setState(() => _gpsError = e.message);
    } catch (e) {
      if (mounted) setState(() => _gpsError = '$e');
    }
  }

  void _onFix(Position p) {
    if (!mounted) return;
    final here = LatLng(p.latitude, p.longitude);
    setState(() {
      _me = here;
      _accuracy = p.accuracy;
      _gpsError = null;
    });
    _refreshInRange(here);
    if (!_cameraPlaced) _enterAtNearestTower(here);
  }

  /// Opens Home on the assigned tower nearest the engineer, at working zoom —
  /// the structure they are standing at, not a jurisdiction-wide overview. Only
  /// the first fix places the camera; after that panning and zooming are theirs.
  ///
  /// Retries on each fix until it succeeds, so a fix that arrives before the
  /// towers have loaded (or before the map is ready) is not lost.
  ///
  /// A no-op for anyone who is not a field engineer (see [_opensAtNearestTower]),
  /// which leaves [_fit]'s overview standing. Every caller routes through here,
  /// so this is the single place the role decides the framing.
  void _enterAtNearestTower(LatLng here) {
    if (!_opensAtNearestTower || !_mapReady) return;
    LiTower? nearest;
    double? best;
    for (final t in _towers) {
      if (t.latitude == null || t.longitude == null) continue;
      final d = LocationService.distanceTo(here, t.latitude!, t.longitude!);
      if (best == null || d < best) {
        best = d;
        nearest = t;
      }
    }
    if (nearest == null) return; // towers not in yet — a later fix retries
    _cameraPlaced = true;
    // Drop any fit still queued by [_fit]: otherwise its post-frame callback
    // would pull the camera straight back out to the whole-jurisdiction view.
    _pending = null;
    final target = LatLng(nearest.latitude!, nearest.longitude!);
    // Deferred for the same reason [_applyCamera] defers: this can be reached
    // from onMapReady, mid-layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _mapReady) _map.move(target, _nearestTowerZoom);
    });
  }

  /// Metres up close (where the presence gate matters), kilometres beyond that.
  String _dist(double m) => m < 1000
      ? '${m.round()} m'
      : '${(m / 1000).toStringAsFixed(m < 10000 ? 1 : 0)} km';

  /// Recentre on the engineer. With a fix in hand this is instant; otherwise it
  /// retries GPS and surfaces why it failed.
  Future<void> _locate() async {
    var here = _me;
    if (here == null) {
      await _startGps();
      if (!mounted) return;
      here = _me;
      if (here == null) {
        final why = _gpsError ?? 'Could not get a GPS fix.';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(why)));
        return;
      }
    }
    _cameraPlaced = true;
    if (_mapReady) {
      final z = _map.camera.zoom;
      _flyTo(here, z < 16 ? 16 : z);
    }
  }

  /// What the map paints [towerId] as: not inspected, inspected but still queued
  /// on this phone, or inspected and on the server.
  ///
  /// Queued wins over inspected on purpose. A tower carrying last cycle's synced
  /// record *and* today's queued one is orange, because the colour answers "is
  /// what I just did safely upstream?" — the newest record is the one at risk.
  TowerState _stateFor(int towerId) {
    if (_awaitingSync.contains(towerId)) return TowerState.awaitingSync;
    final worst = _worst[towerId];
    return worst == null || worst == 'none'
        ? TowerState.notInspected
        : TowerState.inspected;
  }

  /// The sheet's one-line status: what is on record for this tower, and whether
  /// it has left the phone. Says in words what the pin says in colour.
  String _statusNote(int towerId, String? worst) {
    final crit = (worst == null || worst == 'none') ? null : worst;
    if (_awaitingSync.contains(towerId)) {
      return crit == null
          ? 'Inspected on this phone — waiting to sync.'
          : 'Inspected (${critLabel(crit)}) — saved on this phone and waiting '
              'to sync.';
    }
    if (crit == null) {
      return 'Not yet inspected. Tap Inspect while you are at the tower to '
          'record one.';
    }
    return 'Latest inspection: ${critLabel(crit)}.';
  }

  /// Tower details, with Inspect as the primary action. The sheet pops with
  /// 'inspect' rather than launching from inside its builder, so the form is
  /// pushed onto the tab's navigator once the sheet is gone.
  Future<void> _showTower(LiTower t) async {
    final worst = _worst[t.id];
    final me = _me;
    final double? distance = (me != null && t.latitude != null && t.longitude != null)
        ? LocationService.distanceTo(me, t.latitude!, t.longitude!)
        : null;
    final inRange = distance != null && distance <= kPresenceRadiusM;
    // Halo the pin for as long as its sheet is up, so the engineer does not lose
    // which tower they tapped — the sheet can cover the pin itself.
    setState(() => _selectedId = t.id);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text('Tower ${t.towerNumber}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              critChip(worst ?? 'none'),
            ]),
            const SizedBox(height: 10),
            _row(Icons.category_outlined, t.towerType.isEmpty ? '—' : t.towerType),
            _row(Icons.timeline, t.lineName),
            if (t.voltage.isNotEmpty) _row(Icons.bolt_outlined, t.voltage),
            if (t.subdivisionName.isNotEmpty) _row(Icons.map_outlined, t.subdivisionName),
            if (distance != null)
              _row(
                inRange ? Icons.check_circle_outline : Icons.social_distance,
                inRange
                    ? '${_dist(distance)} away — in range'
                    : '${_dist(distance)} away',
                color: inRange ? kCritColor['ok'] : null,
              ),
            if (t.latitude != null && t.longitude != null)
              _row(Icons.place_outlined,
                  '${t.latitude!.toStringAsFixed(5)}, ${t.longitude!.toStringAsFixed(5)}'),
            // Why the pin is orange. Its own row, in the state's own colour, so
            // the sheet and the map agree at a glance.
            if (_stateFor(t.id) == TowerState.awaitingSync)
              _row(Icons.cloud_upload_outlined, 'Waiting to sync',
                  color: kTowerStateColor[TowerState.awaitingSync]),
            const SizedBox(height: 12),
            Text(
              _statusNote(t.id, worst),
              style: const TextStyle(fontSize: 12.5, color: kInkSoft),
            ),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, 'inspect'),
                  icon: const Icon(Icons.assignment_turned_in_outlined, size: 18),
                  label: const Text('Inspect'),
                ),
              ),
            ]),
          ],
        ),
      ),
    );
    if (mounted) setState(() => _selectedId = null);
    if (action != 'inspect' || !mounted) return;
    // Hand over the streamed fix so the gate judges presence on the same reading
    // the list just showed — re-acquiring could disagree with it. If there is no
    // fix yet, the launcher takes a one-shot one.
    final opened = await launchInspection(
      context,
      tower: t,
      inspectorEmployeeId: widget.session.employeeId,
      fix: me,
      accuracyM: _accuracy,
    );
    // Refresh so a tower just inspected takes its new colour — orange while the
    // record is still queued, green once the sync lands (the [SyncEngine]
    // dataRevision listener reloads again then). Forced: a save that committed
    // has already replaced the optimistic row, so the cached copy is behind.
    if (opened && mounted) _load(force: true);
  }

  Widget _row(IconData i, String t, {Color? color}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(i, size: 18, color: color ?? kBlue),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t,
                style: color == null
                    ? null
                    : TextStyle(color: color, fontWeight: FontWeight.w600)),
          ),
        ]),
      );

  /// Keeps [_zoom] in step with the camera so the tower pins resize as the map
  /// pulls back.
  ///
  /// flutter_map can fire this during layout (including for the initial camera),
  /// so the rebuild is deferred a frame rather than calling setState inline.
  void _onCameraMoved(MapCamera camera, bool hasGesture) {
    // An eased move steps the camera every frame; resizing pins along the way
    // would rebuild every marker ~60 times for one 260 ms gesture. [_flyTo]
    // fires this once when it lands instead.
    if (_flying) return;
    final z = camera.zoom;
    if ((z - _zoom).abs() < _zoomRebuildStep) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (z - _zoom).abs() < _zoomRebuildStep) return;
      setState(() => _zoom = z);
    });
  }

  /// Tracks the map's bearing for the compass. Rotation does not go through
  /// `onPositionChanged`, so it has to be caught here.
  void _onMapEvent(MapEvent e) {
    final deg = e.camera.rotation;
    if ((deg - _bearing).abs() < 0.5) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (e.camera.rotation - _bearing).abs() < 0.5) return;
      setState(() => _bearing = e.camera.rotation);
    });
  }

  /// Step the camera a whole zoom level, keeping the centre. [MapOptions.minZoom]
  /// and [maxZoom] do the clamping now, for gestures and this alike.
  void _zoomBy(double delta) {
    if (!_mapReady) return;
    final cam = _map.camera;
    _flyTo(cam.center, cam.zoom + delta);
  }

  /// Fly to an absolute zoom, holding the centre.
  ///
  /// Separate from [_zoomBy] because the state's [_zoom] trails the camera by up
  /// to [_zoomRebuildStep], so a caller aiming at a specific zoom cannot get
  /// there by adding a delta computed from it.
  void _zoomTo(double target) {
    if (!_mapReady) return;
    final cam = _map.camera;
    _flyTo(cam.center, target);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep-alive registration

    // Before anything has loaded there is no map worth showing, so the tab does
    // not build one: the basemap tiles alone are a grey-and-white smear of the
    // whole state, and dimming that behind a spinner read as a broken map rather
    // than as work in progress. The first load — and a first load that failed —
    // each own the whole tab on the app's own surface, exactly as they do on
    // Tickets and History. Later refreshes still happen quietly under the map.
    if (_towers.isEmpty && (_loading || _error != null)) {
      // The map is not in the tree, so the controller is attached to nothing and
      // reading its camera would throw. Everything that drives the camera waits
      // for the next `onMapReady`, which then places it from scratch. Only
      // reachable with no towers, so there is no framing worth preserving.
      _mapReady = false;
      _pending = null;
      _fitted = false;
      _cameraPlaced = false;
      return ColoredBox(
        color: kSurface,
        child: _loading
            ? liLoading(message: 'Loading your lines…')
            : liErrorState(
                _error!,
                title: 'Could not load your area',
                // Forced, like the retry on the other tabs: the load that just
                // failed is the reason to ask the server again.
                onRetry: () => _load(force: true),
              ),
      );
    }

    final mappable = [
      for (final t in _towers)
        if (t.latitude != null && t.longitude != null) t,
    ];
    final me = _me;
    // Pulled back far enough and the pins overlap into a smear the corridor
    // polyline already draws better — so past that point the line carries the
    // map alone. See [kTowerPinMinZoom]. Built as an early exit rather than a
    // hidden layer: at jurisdiction zoom a supervisor can hold thousands of
    // towers, and the markers this skips are the expensive part of the build.
    final showTowers = showTowerPinsAt(_zoom);
    // Pin geometry is the same for every tower at a given zoom, so it is
    // computed once per build rather than per marker.
    final box = TowerPin.boxFor(_zoom);
    final selectedBox = TowerPin.boxFor(_zoom, selected: true);
    final markers = <Marker>[
      if (showTowers)
        for (final t in mappable)
          Marker(
            point: LatLng(t.latitude!, t.longitude!),
            width: _selectedId == t.id ? selectedBox.width : box.width,
            height: _selectedId == t.id ? selectedBox.height : box.height,
            child: TowerPin(
              zoom: _zoom,
              color: towerStateColor(_stateFor(t.id)),
              // Ringed = within the presence radius, so it opens the form with
              // no override. The map says this instead of a separate list.
              // Answered from a precomputed set — see [_inRange].
              ring: _inRange.contains(t.id),
              selected: _selectedId == t.id,
              onTap: () => _showTower(t),
            ),
          ),
    ];

    return Stack(children: [
      Positioned.fill(
        child: FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCenter: const LatLng(16.5, 80.6),
            initialZoom: _overviewZoom,
            // One clamp for everything — pinch, double-tap, the zoom buttons and
            // programmatic moves all go through it, so the map can no longer be
            // pinched past the range either tile set actually serves.
            minZoom: _minZoom,
            maxZoom: _maxZoom,
            interactionOptions: const InteractionOptions(
              // Rotation is on, but it has to win a race against pinch-zoom
              // first. Without this every two-finger zoom also skewed the map a
              // few degrees, silently and with no way back.
              enableMultiFingerGestureRace: true,
            ),
            onMapReady: () {
              _mapReady = true;
              _applyCamera();
              // A fix may have landed before the map was ready to move.
              if (me != null && !_cameraPlaced) _enterAtNearestTower(me);
            },
            onPositionChanged: _onCameraMoved,
            onMapEvent: _onMapEvent,
          ),
          children: [
            TileLayer(
              key: ValueKey(_sat),
              urlTemplate: _sat ? _satellite : _street,
              userAgentPackageName: 'com.aptransco.data_collection',
              tileProvider: _tiles,
            ),
            // The line corridors, under the pins so a tower is never obscured by
            // its own line. Identical widget instance across rebuilds — see
            // [_corridorLayer].
            ?_corridorLayer,
            // What "in range" actually means on the ground, and how much the fix
            // can be trusted. Under the markers so the dots stay readable.
            if (me != null)
              CircleLayer(circles: [
                CircleMarker(
                  point: me,
                  radius: kPresenceRadiusM,
                  useRadiusInMeter: true,
                  color: kBrandAccent.withValues(alpha: 0.10),
                  borderColor: kBrandAccent.withValues(alpha: 0.55),
                  borderStrokeWidth: 1.5,
                ),
                // Only when the fix is too coarse to trust the presence gate —
                // at typical accuracy this ring would sit inside the presence
                // circle and read as one smudge.
                if ((_accuracy ?? 0) > kPresenceRadiusM)
                  CircleMarker(
                    point: me,
                    radius: _accuracy!,
                    useRadiusInMeter: true,
                    color: kCritColor['major']!.withValues(alpha: 0.07),
                    borderColor: kCritColor['major']!.withValues(alpha: 0.45),
                    borderStrokeWidth: 1,
                  ),
              ]),
            MarkerLayer(markers: markers),
            // Reads the camera itself, so panning rebuilds these labels rather
            // than the whole tab. Its own threshold is well above
            // [kTowerPinMinZoom], so labels are already gone by the time the
            // pins go — but it is gated here too so a label can never outlive
            // the dot it points at.
            if (showTowers) TowerLabelLayer(towers: mappable),
            Scalebar(
              alignment: Alignment.bottomRight,
              // No plate behind it, so it has to be inked for the basemap
              // underneath or it disappears.
              lineColor: _sat ? Colors.white : kInk,
              textStyle: TextStyle(
                color: _sat ? Colors.white : kInk,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
              padding: const EdgeInsets.only(right: 12, bottom: 26),
            ),
            if (me != null)
              MarkerLayer(markers: [
                Marker(
                    point: me,
                    width: 22,
                    height: 22,
                    child: const MyLocationDot()),
              ]),
          ],
        ),
      ),
      // Towers are hidden at this zoom, so say so. Without it a corridor with no
      // pins on it reads as missing data — which this tab has a full-screen
      // empty state for, and the two must not be confused for one another.
      if (!showTowers && mappable.isNotEmpty && !_loading && _error == null)
        Positioned(
          left: 0,
          right: 0,
          bottom: kSpaceLg,
          child: Center(child: _zoomHint()),
        ),
      // Nothing to show: no assigned lines, or towers without coordinates. Sits
      // under the controls so the map controls stay reachable.
      if (!_loading && _error == null && mappable.isEmpty)
        Positioned.fill(
          child: Container(
            color: kCardBg.withValues(alpha: 0.94),
            child: liEmptyState(
              Icons.timeline,
              _towers.isEmpty
                  ? 'No lines assigned to you yet'
                  : 'Your towers have no recorded coordinates',
              subtitle: _towers.isEmpty
                  ? 'Once lines in your jurisdiction are assigned, their towers '
                      'appear here — tap one to inspect it.'
                  : 'Ask your subdivision office to add tower coordinates so they '
                      'can be mapped and inspected.',
            ),
          ),
        ),
      // The KPI strip — towers assigned, inspected, remaining and open tickets —
      // and, wrapped around it, the pull-to-refresh: drag the bar down and the
      // Material arc drops out from under it and spins until the load lands,
      // exactly as a pull does on Tickets and History. Only this band is bound to
      // the gesture (see [_pullBandHeight]); the map below it pans, zooms and taps
      // as before.
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        height: _pullBandHeight,
        child: RefreshIndicator(
          onRefresh: _refresh,
          displacement: _pullDisplacement,
          color: kBrandPrimary,
          backgroundColor: kCardBg,
          child: Column(children: [
            SizedBox(
              height: _pullHandleHeight,
              child: ListView(
                // The bar is shorter than its slice, so there is nothing to
                // scroll — and without this the strip would not take a drag at
                // all, which is what the indicator listens to.
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
                children: [_kpiStrip()],
              ),
            ),
            // The rest of the band exists only so the arc has room to rest in it.
            // Empty, so it hit-tests to nothing and the pointers fall through to
            // the map underneath — see [_pullHandleHeight].
            const Expanded(child: SizedBox.shrink()),
          ]),
        ),
      ),
      // Map controls — layer toggle, a joined zoom pair, then locate — held at
      // the right edge and centred vertically, within thumb reach either way.
      Positioned(
        right: 12,
        top: 0,
        bottom: 0,
        child: Center(child: _mapControls()),
      ),
      // What the colours mean. Bottom-left is the only corner left: the KPI strip
      // owns the top, the controls the right edge, and the scale bar and
      // attribution the bottom-right.
      const Positioned(left: 10, bottom: 10, child: MapLegend()),
      // Required by both tile sources, and previously shown for neither.
      Positioned(right: 12, bottom: 8, child: MapAttribution(satellite: _sat)),
      // GPS trouble matters here: without a fix, inspecting falls to the audited
      // override. The control column is centred, so this clears it at the top.
      if (_gpsError != null)
        Positioned(left: 10, right: 10, top: 66, child: _gpsBanner(_gpsError!)),
      // The first load never reaches this Stack — it is handled above, before the
      // map is built. Everything from here on happens with the map up: a pull
      // reports itself in its own arc, and a failed one leaves the map standing
      // (it still works offline) and says so in a message instead.
    ]);
  }

  /// A floating notice that the fix is missing, with a retry. Sits on the map
  /// like the other overlays rather than as a full-width strip.
  Widget _gpsBanner(String msg) => Container(
        padding: const EdgeInsets.fromLTRB(kSpaceMd, kSpaceSm, kSpaceSm, kSpaceSm),
        decoration: BoxDecoration(
          color: kCardBg,
          borderRadius: BorderRadius.circular(kRadiusMd),
          border: Border.all(color: kCritColor['major']!.withValues(alpha: 0.45)),
          boxShadow: kShadowFloating,
        ),
        child: Row(children: [
          Icon(Icons.gps_off, size: 18, color: kCritColor['major']),
          const SizedBox(width: kSpaceSm),
          Expanded(
            child: Text(msg,
                style: const TextStyle(fontSize: 11.5, color: kInk, height: 1.3)),
          ),
          TextButton(
            onPressed: _startGps,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: kSpaceSm),
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Retry'),
          ),
        ]),
      );

  Widget _kpiStrip() {
    final d = _dash;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: kCardBg,
        borderRadius: BorderRadius.circular(kRadiusMd),
        border: Border.all(color: kOutline),
        boxShadow: kShadowFloating,
      ),
      child: Row(children: [
        Expanded(child: _kpi('Towers', '${d?.towerTotal ?? _towers.length}')),
        _sep(),
        Expanded(child: _kpi('Inspected', d == null ? '—' : '${d.inspected}')),
        _sep(),
        Expanded(child: _kpi('Remaining',
            d == null ? '—' : '${(d.towerTotal - d.inspected).clamp(0, d.towerTotal)}')),
        _sep(),
        Expanded(child: _kpi('Tickets', d == null ? '—' : '${d.openTotal}')),
      ]),
    );
  }

  Widget _sep() => Container(width: 1, height: 26, color: kOutline);

  Widget _kpi(String label, String value) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: kInk)),
          Text(label, style: const TextStyle(fontSize: 10.5, color: kInkSoft)),
        ],
      );

  /// The map's own controls as three floating cards: the layer toggle, zoom in
  /// and out joined in one card (they are one control, two directions), then
  /// locate set apart below.
  ///
  /// Reloading is deliberately not among them: it is the pull-down gesture on the
  /// KPI bar, the same one the other tabs use.
  Widget _mapControls() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ctrlCard([
            _ctrlButton(_sat ? Icons.map_outlined : Icons.layers_rounded,
                _sat ? 'Standard map' : 'Satellite', () => setState(() => _sat = !_sat)),
          ]),
          const SizedBox(height: kSpaceMd),
          _ctrlCard([
            _ctrlButton(Icons.add, 'Zoom in', () => _zoomBy(1)),
            Container(width: _ctrlSize - 16, height: 1, color: kOutline),
            _ctrlButton(Icons.remove, 'Zoom out', () => _zoomBy(-1)),
          ]),
          const SizedBox(height: kSpaceLg),
          _ctrlCard([
            _ctrlButton(Icons.my_location_rounded, 'My location', _locate,
                color: kBrandAccent),
          ]),
          // Absent until the map is actually skewed, so it costs nothing in the
          // common north-up case.
          MapCompass(
            bearing: _bearing,
            size: _ctrlSize,
            onReset: () {
              if (_mapReady) _map.rotate(0);
            },
          ),
        ],
      );

  /// A quiet pill telling the user the towers are hidden rather than absent, and
  /// what to do about it. Tapping it is the fix as well as the explanation —
  /// this is the one moment the map knows exactly where the user wants to go.
  Widget _zoomHint() => Material(
        color: kCardBg.withValues(alpha: 0.94),
        elevation: 3,
        shadowColor: kBrandPrimaryDark.withValues(alpha: 0.30),
        clipBehavior: Clip.antiAlias,
        shape: const StadiumBorder(),
        child: InkWell(
          // A full step past the threshold, not onto it: at exactly
          // [kTowerPinMinZoom] the pins are 9 px specks, and landing the user on
          // the very edge of the band would make the tap feel like it barely
          // worked.
          onTap: () => _zoomTo(kTowerPinMinZoom + 1),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: kSpaceLg, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.zoom_in_rounded, size: 16, color: kBrandAccent),
                SizedBox(width: 6),
                Text(
                  'Zoom in to see towers',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: kInkSoft),
                ),
              ],
            ),
          ),
        ),
      );

  static const double _ctrlSize = 46;

  /// A floating white control card. Takes a list so a card can hold a stack of
  /// buttons (zoom) as easily as one.
  Widget _ctrlCard(List<Widget> children) => Material(
        color: kCardBg,
        elevation: 3,
        shadowColor: kBrandPrimaryDark.withValues(alpha: 0.30),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusSm),
          side: const BorderSide(color: kOutline),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: children),
      );

  Widget _ctrlButton(IconData icon, String tip, VoidCallback onTap, {Color? color}) =>
      Tooltip(
        message: tip,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: _ctrlSize,
            height: _ctrlSize,
            child: Icon(icon, size: 22, color: color ?? kBrandPrimary),
          ),
        ),
      );
}
