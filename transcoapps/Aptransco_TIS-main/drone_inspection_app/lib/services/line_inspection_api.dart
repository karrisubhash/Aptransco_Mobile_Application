import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;

import '../models/inspection_catalog.dart';
import '../models/li_asset.dart';
import '../models/li_export.dart';
import '../models/li_records.dart';
import 'api_service.dart' show ApiService;
import 'auth_store.dart';
import 'offline/connectivity_service.dart';
import 'offline/li_cache_keys.dart';
import 'offline/local_store.dart';

/// Thrown when the backend rejects the auth token (401). The app clears the
/// session and returns the user to the login screen.
class UnauthorizedException implements Exception {
  const UnauthorizedException();
  @override
  String toString() => 'Session expired — please sign in again.';
}

/// Raised when checkCred rejects the credentials at login.
class LoginFailedException implements Exception {
  const LoginFailedException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A read that can answer twice.
///
/// [cached] is the copy already on the device — available in a few milliseconds,
/// which is what lets a tab paint its content instead of a spinner. [fresh]
/// completes with the server's copy, or with **null** when there is nothing new
/// worth swapping in: the cached copy is still inside its freshness window, the
/// device is offline, or the request failed and [cached] is the better answer.
///
/// Screens await [cached] synchronously (via [value]) and then let [fresh]
/// update them when it lands. [latest] is the old network-first behaviour, for
/// the callers that must have the server's answer (the offline pre-download).
class CacheRead<T> {
  const CacheRead(this.cached, this.fresh, this._what);
  final T? cached;
  final Future<T?> fresh;
  final String _what;

  bool get hasCached => cached != null;

  /// The fastest usable answer: the cached copy if there is one, otherwise the
  /// server's. Throws only when neither can answer.
  Future<T> get value async => cached ?? await _require();

  /// The server's answer, falling back to the cached copy when the network
  /// could not provide one.
  Future<T> get latest async => (await fresh) ?? cached ?? await _require();

  Future<T> _require() async {
    final v = await fresh;
    if (v != null) return v;
    throw OfflineNoCacheException(_what);
  }
}

/// API client for the line-inspection platform (endpoints under the same
/// base URL as [ApiService], served by the `line_inspection` Django app over
/// the PostgreSQL `clear` schema).
///
/// Every read is **cache-through**: a successful response is written to the
/// on-device store, and if the backend is unreachable the last cached copy is
/// returned instead. That is what lets every list/detail/map screen keep
/// working offline.
///
/// Reads come in two shapes. The `read*` family is **cache-first** ([CacheRead]):
/// it hands back what is already on the device immediately and revalidates
/// behind it, so opening a tab costs a disk read rather than a round trip. The
/// `load*` family is network-first and is what the offline pre-download and the
/// inspection form use, where the server's copy is the point of the call.
///
/// Writes here are the raw transport used by the [SyncEngine]; screens go
/// through `OfflineActions` so their changes are queued durably.
class LineInspectionApi {
  static String get _base => ApiService.baseUrl;

  // ---- auth ----------------------------------------------------------------

  /// Auth header for authenticated calls, merged into every request.
  static Map<String, String> get _auth => AuthStore.instance.authHeaders();

  static Map<String, String> get _jsonHeaders =>
      {'Content-Type': 'application/json', ..._auth};

  /// Verify credentials via the backend (checkCred) and return the raw login
  /// profile incl. `token`. Throws [LoginFailedException] on bad credentials.
  ///
  /// [timeout] is shortened by the sign-in screen when the app already believes
  /// it is offline: an unreachable host normally fails in under a second, but a
  /// captive portal or a blackholing corporate network can swallow the request
  /// instead — and waiting the full window there would stall an inspector who
  /// could have been signed in from the device's own copy of their credentials.
  static Future<Map<String, dynamic>> login(
    String userId,
    String passwd, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final res = await http
        .post(Uri.parse('$_base/auth/login/'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'user_id': userId, 'passwd': passwd}))
        .timeout(timeout);
    if (res.statusCode == 200 || res.statusCode == 201) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    if (res.statusCode == 401) {
      String msg = 'Invalid credentials.';
      try {
        msg = (jsonDecode(res.body) as Map)['error']?.toString() ?? msg;
      } catch (_) {}
      throw LoginFailedException(msg);
    }
    throw LoginFailedException('Login failed (${res.statusCode}).');
  }

  /// Revoke the current token server-side (best effort — always clears locally).
  static Future<void> logout() async {
    try {
      await http
          .post(Uri.parse('$_base/auth/logout/'), headers: _auth)
          .timeout(const Duration(seconds: 12));
    } catch (_) {/* revoke is best-effort; local clear is what matters */}
  }

  /// True when the response is a 401 — surfaces as [UnauthorizedException].
  ///
  /// Also records the refusal on [AuthStore] so the app as a whole can say the
  /// session has expired. Every authenticated call funnels through here, so this
  /// is the one place that has to notice.
  static void _guard(http.BaseResponse res) {
    if (res.statusCode == 401) {
      AuthStore.instance.markSessionExpired();
      throw const UnauthorizedException();
    }
  }

  /// How long a read waits before giving up. Long enough for a slow field link,
  /// short enough that a backend which has gone away (blocked ngrok host, dead
  /// hotspot) falls back to the cached copy while the engineer is still looking
  /// at the screen.
  static const Duration _readTimeout = Duration(seconds: 15);

  /// GET [url] and return its body, or throw with [label] and the status code.
  /// Every read endpoint funnels through here so they share one timeout, one
  /// 401 handling and one error shape.
  static Future<String> _getBody(String url, String label,
      {Duration timeout = _readTimeout}) async {
    final res = await http.get(Uri.parse(url), headers: _auth).timeout(timeout);
    // A response of any kind is proof the backend is reachable — better proof
    // than the periodic probe, and free. Without this the app could sit behind
    // an "offline" banner while responses were arriving normally.
    ConnectivityService.instance.reportSuccess();
    _guard(res);
    if (res.statusCode != 200) {
      throw Exception('$label failed (${res.statusCode})');
    }
    return res.body;
  }

  /// The readable reason out of an error body, so a refusal reaches the user as
  /// something they can act on rather than a bare status code.
  ///
  /// Handles DRF's two shapes — `{"detail": "..."}` for permission/auth errors
  /// and `{"field": ["..."]}` for validation — and falls back to the raw body,
  /// truncated to stay inside a snackbar.
  static String _detail(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final detail = decoded['detail'];
        if (detail is String && detail.isNotEmpty) return detail;
        final parts = <String>[
          for (final v in decoded.values) v is List ? v.join(', ') : '$v',
        ].where((s) => s.isNotEmpty).toList();
        if (parts.isNotEmpty) return parts.join(' · ');
      }
    } catch (_) {
      // Not JSON — fall through to the raw body.
    }
    final s = body.trim();
    return s.length > 160 ? '${s.substring(0, 160)}…' : s;
  }

  /// Absolute URL for a photo reference returned by the API.
  ///
  /// The detail endpoint already sends **absolute** URLs (`absolute_photo_url`
  /// in `api/serializers.py` builds them with `build_absolute_uri('/media/…')`),
  /// so an absolute reference is returned untouched. Prefixing it again was
  /// producing `https://host/inspection/media/https://host/media/…`, which meant
  /// no server-side inspection photo ever loaded — the detail page showed the
  /// offline placeholder even with full signal, and the cache warmer spent every
  /// pass prefetching the same malformed URL.
  ///
  /// A bare storage path (an older backend, or a response cached before the API
  /// sent absolute URLs) is resolved against the base URL's **origin**: media is
  /// served from `/media/` at the host root, *not* underneath the API's own path
  /// prefix. Stripping only the trailing `/api` left the `/inspection` mount in
  /// place and pointed at a path that does not exist.
  static String mediaUrl(String path) {
    final ref = path.trim();
    if (ref.isEmpty) return ref;
    if (ref.startsWith('http://') || ref.startsWith('https://')) return ref;
    final rel = ref
        .replaceFirst(RegExp(r'^/+'), '')
        .replaceFirst(RegExp(r'^media/'), '');
    String origin;
    try {
      origin = Uri.parse(_base).origin;
    } catch (_) {
      // Not an absolute http(s) base (only reachable from a malformed override):
      // fall back to trimming the known API suffix.
      origin = _base.replaceAll(RegExp(r'/api/?$'), '');
    }
    return '$origin/media/$rel';
  }

  // ---- offline-aware read core --------------------------------------------

  /// How long a cached response counts as current enough to skip the network
  /// altogether. Sized for the field: within a minute of loading a screen,
  /// reopening it (a tab switch, a return from the inspection form, a sync
  /// notification) should cost nothing at all. Pull-to-refresh passes
  /// `force: true` and ignores this.
  static const Duration freshList = Duration(seconds: 45);

  /// Master data — the assigned lines and their towers — changes when an EE
  /// edits an assignment, not during a walk down a line, so it is held longer.
  static const Duration freshMaster = Duration(minutes: 10);

  /// GETs in flight, keyed by session token + cache key, so the same resource is
  /// fetched once no matter how many screens ask for it at the same moment. Home
  /// and History both want the dashboard the instant the hub opens; before this
  /// they each paid for their own copy of the most expensive query on the server.
  ///
  /// The token is part of the key so sharing can never cross a sign-in: a request
  /// started under one employee must not be handed to a screen that is now
  /// asking as somebody else.
  static final Map<String, Future<String>> _inFlight = {};

  static Future<String> _fetchOnce(String key, Future<String> Function() fetch) {
    final flightKey = '${AuthStore.instance.token ?? ''}#$key';
    final running = _inFlight[flightKey];
    if (running != null) return running;
    late final Future<String> f;
    f = fetch().whenComplete(() {
      if (_inFlight[flightKey] == f) _inFlight.remove(flightKey);
    });
    _inFlight[flightKey] = f;
    return f;
  }

  /// The one read path: hand back whatever is cached for [key] now, and a future
  /// that revalidates it against the server.
  ///
  /// [freshFor] skips the request entirely while the cached copy is younger than
  /// that; [force] ignores the window (pull-to-refresh); [allowNetwork] false
  /// makes it a pure disk read, which is how a screen paints its first frame
  /// without waiting on anything.
  static Future<CacheRead<T>> _read<T>(
    String key,
    Future<String> Function() fetch,
    T Function(String body) parse, {
    bool force = false,
    bool allowNetwork = true,
    Duration? freshFor,
    String what = 'this data',
  }) async {
    T? cached;
    final entry = await LocalStore.instance.getCacheEntry(key);
    if (entry != null) {
      try {
        cached = parse(entry.body);
      } catch (_) {
        cached = null; // corrupt, or written by an older app build — a miss
      }
    }
    final revalidate = shouldRevalidate(
      force: force,
      allowNetwork: allowNetwork,
      hasCached: cached != null,
      cachedAge: entry?.age,
      freshFor: freshFor,
    );
    return CacheRead<T>(
      cached,
      revalidate
          ? _revalidate(key, fetch, parse, cached, what)
          : Future<T?>.value(null),
      what,
    );
  }

  /// Whether a read should go to the network at all, given what is on disk.
  ///
  /// Its own function because this one decision is what turns a tab from "wait
  /// for a round trip" into "already on screen", and it is worth being able to
  /// test without a server:
  ///   * `allowNetwork: false` never goes out — the disk-only first pass
  ///   * `force: true` always goes out — pull-to-refresh, and after a save/sync
  ///   * otherwise a cached copy younger than [freshFor] is left alone
  @visibleForTesting
  static bool shouldRevalidate({
    required bool force,
    required bool allowNetwork,
    required bool hasCached,
    Duration? cachedAge,
    Duration? freshFor,
  }) {
    if (!allowNetwork) return false;
    if (force || !hasCached) return true;
    if (freshFor == null || cachedAge == null) return true;
    return cachedAge >= freshFor;
  }

  /// Fetches [key] and writes it through to the cache. Returns null — "keep what
  /// you are showing" — whenever the network cannot better [cached]; only throws
  /// when there is no cached copy to fall back on.
  static Future<T?> _revalidate<T>(
    String key,
    Future<String> Function() fetch,
    T Function(String body) parse,
    T? cached,
    String what,
  ) async {
    if (!ConnectivityService.instance.online.value) {
      // Believing we are offline is exactly when that belief stops being tested:
      // this early return is what keeps the request from being made, so nothing
      // fails, so nothing asks the service to look again. Nudge a probe here —
      // it runs in the background and costs this read nothing, but it means any
      // attempt to load data (a tab switch, a pull-to-refresh) also acts as a
      // request to re-verify, and a stale "offline" heals within seconds instead
      // of lasting until the app is backgrounded.
      ConnectivityService.instance.reportFailure();
      if (cached != null) return null;
      throw OfflineNoCacheException(what);
    }
    // Whose answer this is. A read can be in flight across a sign-out or a switch
    // of employee (the hub's tabs all refresh on mount), and writing its response
    // to the cache afterwards would put the previous employee's data straight back
    // into the store that AuthStore.save just purged.
    final asToken = AuthStore.instance.token;
    try {
      final body = await _fetchOnce(key, fetch);
      if (AuthStore.instance.token != asToken) return null;
      await LocalStore.instance.putCache(key, body);
      return parse(body);
    } catch (e) {
      // A transport failure means we may actually be offline — re-probe so the
      // UI flips to the offline banner. Either way, prefer showing saved data
      // over an error when we have it; only surface the error if we have none.
      if (_isNetworkError(e)) ConnectivityService.instance.reportFailure();
      if (cached != null) return null;
      rethrow;
    }
  }

  /// Network-first read, kept for the callers whose whole purpose is the
  /// server's copy (the offline pre-download, the inspection form's catalog).
  static Future<String> _readThrough(
    String key,
    Future<String> Function() fetch, {
    String what = 'this data',
  }) async {
    final read = await _read<String>(key, fetch, (b) => b, force: true, what: what);
    return read.latest;
  }

  static bool _isNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is http.ClientException ||
      e is HandshakeException;

  // ---- Catalog -------------------------------------------------------------

  /// Fetches the questionnaire catalog, caching it so the form still opens
  /// offline. Falls back to the last cached copy on a network error.
  static Future<InspectionCatalog> loadCatalog() async {
    final body = await _readThrough(
      LiCacheKeys.catalog,
      () => _getBody('$_base/catalog/', 'Catalog load',
          timeout: const Duration(seconds: 20)),
      what: 'the inspection form',
    );
    return InspectionCatalog.fromJson(
        jsonDecode(body) as Map<String, dynamic>);
  }

  /// The cached catalog if one was ever fetched, else null (no network hit).
  static Future<InspectionCatalog?> cachedCatalog() async {
    final cached = await LocalStore.instance.getCache(LiCacheKeys.catalog);
    if (cached == null) return null;
    try {
      return InspectionCatalog.fromJson(
          jsonDecode(cached) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  // ---- Lines & towers ------------------------------------------------------

  /// Every line assigned to the viewer — the map's and the pre-download's
  /// starting point, cache-first so Home can draw before the network answers.
  static Future<CacheRead<List<LiLine>>> readLines({
    bool force = false,
    bool allowNetwork = true,
  }) =>
      _read(
        LiCacheKeys.linesAll,
        () => _getBody('$_base/lines/', 'Line load'),
        _parseLines,
        force: force,
        allowNetwork: allowNetwork,
        freshFor: freshMaster,
        what: 'the line list',
      );

  /// Transmission lines whose name contains [query]. The full list (empty
  /// query) is cached and reused for offline search: when offline, or when a
  /// live search fails, the cached full list is filtered locally by [query].
  static Future<List<LiLine>> searchLines(String query) async {
    final q = query.trim();
    if (q.isEmpty) return (await readLines(force: true)).latest;

    Future<String> fetch() async {
      final uri = Uri.parse('$_base/lines/')
          .replace(queryParameters: {'search': q});
      return _getBody(uri.toString(), 'Line search');
    }

    if (ConnectivityService.instance.online.value) {
      try {
        return _parseLines(await fetch());
      } catch (e) {
        if (_isNetworkError(e)) ConnectivityService.instance.reportFailure();
        final cached = await LocalStore.instance.getCache(LiCacheKeys.linesAll);
        if (cached != null) return _filterLines(_parseLines(cached), q);
        rethrow;
      }
    }
    final cached = await LocalStore.instance.getCache(LiCacheKeys.linesAll);
    if (cached != null) return _filterLines(_parseLines(cached), q);
    throw const OfflineNoCacheException('the line list');
  }

  static List<LiLine> _parseLines(String body) => (jsonDecode(body) as List)
      .map((e) => LiLine.fromJson(e as Map<String, dynamic>))
      .toList();

  static List<LiLine> _filterLines(List<LiLine> lines, String q) {
    if (q.isEmpty) return lines;
    final lower = q.toLowerCase();
    return lines.where((l) => l.name.toLowerCase().contains(lower)).toList();
  }

  /// Towers on [lineId], ordered by tower number — cache-first.
  static Future<CacheRead<List<LiTower>>> readTowersForLine(
    int lineId, {
    bool force = false,
    bool allowNetwork = true,
  }) =>
      _read(
        LiCacheKeys.towers(lineId),
        () => _getBody('$_base/lines/$lineId/towers/', 'Tower load'),
        _parseTowers,
        force: force,
        allowNetwork: allowNetwork,
        freshFor: freshMaster,
        what: 'this line\'s towers',
      );

  /// Towers on [lineId], ordered by tower number.
  static Future<List<LiTower>> towersForLine(int lineId) async =>
      (await readTowersForLine(lineId, force: true)).latest;

  static List<LiTower> _parseTowers(String body) => (jsonDecode(body) as List)
      .map((e) => LiTower.fromJson(e as Map<String, dynamic>))
      .toList();

  // ---- Records / tickets / support / dashboard ----------------------------

  static String _q(Map<String, dynamic> params) {
    final p = <String, String>{};
    params.forEach((k, v) {
      if (v != null) p[k] = v.toString();
    });
    return p.isEmpty ? '' : '?${Uri(queryParameters: p).query}';
  }

  static Future<List<Subdivision>> loadSubdivisions() async {
    final body = await _readThrough(
      LiCacheKeys.subdivisions,
      () => _getBody('$_base/subdivisions/', 'Subdivisions'),
      what: 'subdivisions',
    );
    return (jsonDecode(body) as List)
        .map((e) => Subdivision.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Inspection summaries, newest first — cache-first. [inspector] narrows the
  /// list to one employee's own inspections: what the History tab lists, and what
  /// keeps the server's 500-row cap from being spent on a supervisor's whole
  /// subtree.
  static Future<CacheRead<List<InspectionSummary>>> readInspections({
    int? subdivision,
    int? line,
    int? tower,
    String? inspector,
    bool force = false,
    bool allowNetwork = true,
  }) =>
      _read(
        LiCacheKeys.inspections(
            subdivision: subdivision,
            line: line,
            tower: tower,
            inspector: inspector),
        () => _getBody(
            '$_base/line-inspections/list/'
            '${_q({'subdivision': subdivision, 'line': line, 'tower': tower, 'inspector': inspector})}',
            'Inspections'),
        _parseInspections,
        force: force,
        allowNetwork: allowNetwork,
        freshFor: freshList,
        what: 'inspections',
      );

  static Future<List<InspectionSummary>> loadInspections(
          {int? subdivision, int? line, int? tower, String? inspector}) async =>
      (await readInspections(
              subdivision: subdivision,
              line: line,
              tower: tower,
              inspector: inspector,
              force: true))
          .latest;

  static List<InspectionSummary> _parseInspections(String body) =>
      (jsonDecode(body) as List)
          .map((e) => InspectionSummary.fromJson(e as Map<String, dynamic>))
          .toList();

  static Future<InspectionDetail> loadInspectionDetail(int id) async {
    // Negative ids are locally-created inspections still in the outbox; they
    // only ever exist in the cache (written by OfflineActions).
    if (id < 0) {
      final cached =
          await LocalStore.instance.getCache(LiCacheKeys.inspectionDetail(id));
      if (cached != null) {
        return InspectionDetail.fromJson(
            jsonDecode(cached) as Map<String, dynamic>);
      }
      throw const OfflineNoCacheException('this inspection');
    }
    final body = await _readThrough(
      LiCacheKeys.inspectionDetail(id),
      () => _getBody('$_base/line-inspections/$id/', 'Detail'),
      what: 'this inspection',
    );
    return InspectionDetail.fromJson(
        jsonDecode(body) as Map<String, dynamic>);
  }

  /// The inspection behind [id], cache-first — a detail already opened once (or
  /// pre-downloaded) reopens without a round trip.
  static Future<CacheRead<InspectionDetail>> readInspectionDetail(
    int id, {
    bool force = false,
    bool allowNetwork = true,
  }) =>
      _read(
        LiCacheKeys.inspectionDetail(id),
        () => _getBody('$_base/line-inspections/$id/', 'Detail'),
        (b) => InspectionDetail.fromJson(jsonDecode(b) as Map<String, dynamic>),
        force: force,
        // A saved inspection never changes, so a cached copy is always current.
        allowNetwork: allowNetwork && id > 0,
        freshFor: const Duration(days: 365),
        what: 'this inspection',
      );

  /// Defect tickets in the viewer's scope — cache-first.
  static Future<CacheRead<List<TicketRecord>>> readTickets({
    String? status,
    int? subdivision,
    int? line,
    int? tower,
    bool force = false,
    bool allowNetwork = true,
  }) =>
      _read(
        LiCacheKeys.tickets(
            status: status, subdivision: subdivision, line: line, tower: tower),
        () => _getBody(
            '$_base/tickets/'
            '${_q({'status': status, 'subdivision': subdivision, 'line': line, 'tower': tower})}',
            'Tickets'),
        _parseTickets,
        force: force,
        allowNetwork: allowNetwork,
        freshFor: freshList,
        what: 'tickets',
      );

  static Future<List<TicketRecord>> loadTickets(
          {String? status, int? subdivision, int? line, int? tower}) async =>
      (await readTickets(
              status: status,
              subdivision: subdivision,
              line: line,
              tower: tower,
              force: true))
          .latest;

  static List<TicketRecord> _parseTickets(String body) =>
      (jsonDecode(body) as List)
          .map((e) => TicketRecord.fromJson(e as Map<String, dynamic>))
          .toList();

  static Future<TicketRecord> closeTicket(int id,
      {required String closedBy, required String note}) async {
    final res = await http
        .post(Uri.parse('$_base/tickets/$id/close/'),
            headers: _jsonHeaders,
            body: jsonEncode({'closed_by': closedBy, 'close_note': note}))
        .timeout(const Duration(seconds: 20));
    _guard(res);
    if (res.statusCode != 200) {
      // Carry the server's reason through. A refusal here is almost always the
      // jurisdiction check, and "Close failed (403)" told the user nothing they
      // could act on.
      throw Exception('Close failed (${res.statusCode}): ${_detail(res.body)}');
    }
    return TicketRecord.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  // ---- Report downloads ----------------------------------------------------

  /// Fetches [url] as raw bytes, for the report downloads. The read family above
  /// all parses JSON and caches the body as text; a spreadsheet is neither, so
  /// this is deliberately *not* cache-through — a report is generated for the
  /// moment it is asked for, and keeping a stale one on disk would be worse than
  /// having none.
  ///
  /// Shares [_guard] and the connectivity reporting with every other call, so a
  /// download that meets an expired session expires it the same way a list read
  /// would.
  static Future<ExportedReport> _getFile(String url, String label) async {
    final res = await http
        .get(Uri.parse(url), headers: _auth)
        .timeout(_exportTimeout);
    ConnectivityService.instance.reportSuccess();
    _guard(res);
    if (res.statusCode != 200) {
      // The body of a failed export is the server's JSON reason, not a file.
      throw Exception(
          '$label failed (${res.statusCode}): ${_detail(res.body)}');
    }
    return ExportedReport(
      bytes: res.bodyBytes,
      filename: _filenameFrom(res.headers['content-disposition']) ??
          'aptransco_report',
    );
  }

  /// Longer than [_readTimeout]: the server is rendering a spreadsheet or laying
  /// out a multi-page PDF over a division's whole backlog, not answering a
  /// cached list query.
  static const Duration _exportTimeout = Duration(seconds: 60);

  /// The filename out of a `Content-Disposition` header, or null.
  ///
  /// The server names every export (see `exports.Report.filename`), and honouring
  /// that is what keeps one naming scheme across the app and the web dashboard
  /// instead of the phone inventing its own.
  @visibleForTesting
  static String? filenameFromDisposition(String? header) =>
      _filenameFrom(header);

  static String? _filenameFrom(String? header) {
    if (header == null) return null;
    // Handles `filename="x.pdf"`, bare `filename=x.pdf`, and RFC 5987's
    // `filename*=UTF-8''x.pdf` — Django sends the quoted form, but a proxy in
    // front of it may rewrite the header.
    final star = RegExp(r"filename\*=UTF-8''([^;]+)", caseSensitive: false)
        .firstMatch(header);
    if (star != null) {
      final raw = star.group(1)!.trim();
      try {
        return _safeName(Uri.decodeComponent(raw));
      } catch (_) {
        return _safeName(raw);
      }
    }
    final plain = RegExp(r'filename="?([^";]+)"?', caseSensitive: false)
        .firstMatch(header);
    if (plain == null) return null;
    return _safeName(plain.group(1)!.trim());
  }

  /// Strips anything that could make a server-supplied name escape the directory
  /// it is about to be written into. The name arrives over the network, so it is
  /// never trusted as a path — only as a leaf filename.
  static String _safeName(String name) {
    final leaf = name.split(RegExp(r'[\\/]')).last.replaceAll('..', '');
    return leaf.isEmpty ? 'aptransco_report' : leaf;
  }

  /// The History tab's report: every inspection at this user's level, as the
  /// server renders it. Same filters as [readInspections], so a narrowed tab
  /// downloads a narrowed report.
  static Future<ExportedReport> exportInspections({
    required ExportFormat format,
    int? subdivision,
    int? line,
    int? tower,
    String? inspector,
  }) =>
      _getFile(
        '$_base/line-inspections/export/'
        '${_q({
              'format': format.wire,
              'subdivision': subdivision,
              'line': line,
              'tower': tower,
              'inspector': inspector,
            })}',
        'History export',
      );

  /// The Tickets tab's report, under the same status/scope filters as
  /// [readTickets].
  static Future<ExportedReport> exportTickets({
    required ExportFormat format,
    String? status,
    int? subdivision,
    int? line,
    int? tower,
  }) =>
      _getFile(
        '$_base/tickets/export/'
        '${_q({
              'format': format.wire,
              'status': status,
              'subdivision': subdivision,
              'line': line,
              'tower': tower,
            })}',
        'Tickets export',
      );

  /// Support requests in the viewer's scope — cache-first.
  static Future<CacheRead<List<SupportRequest>>> readSupportRequests({
    int? subdivision,
    bool force = false,
    bool allowNetwork = true,
  }) =>
      _read(
        LiCacheKeys.support(subdivision: subdivision),
        () => _getBody(
            '$_base/support-requests/${_q({'subdivision': subdivision})}',
            'Support load'),
        _parseSupport,
        force: force,
        allowNetwork: allowNetwork,
        freshFor: freshList,
        what: 'requests',
      );

  static Future<List<SupportRequest>> loadSupportRequests(
          {int? subdivision}) async =>
      (await readSupportRequests(subdivision: subdivision, force: true)).latest;

  static List<SupportRequest> _parseSupport(String body) =>
      (jsonDecode(body) as List)
          .map((e) => SupportRequest.fromJson(e as Map<String, dynamic>))
          .toList();

  static Future<SupportRequest> createSupportRequest({
    required String raisedBy,
    required String category,
    required String subject,
    required String text,
    int? subdivisionId,
  }) async {
    final res = await http
        .post(Uri.parse('$_base/support-requests/'),
            headers: _jsonHeaders,
            body: jsonEncode({
              'raised_by_employee_id': raisedBy,
              'category': category,
              'subject': subject,
              'text': text,
              'subdivision_id': subdivisionId,
            }))
        .timeout(const Duration(seconds: 20));
    _guard(res);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw Exception('Create failed (${res.statusCode})');
    }
    return SupportRequest.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  static Future<SupportRequest> resolveSupportRequest(int id,
      {required String resolvedBy, required String response}) async {
    final res = await http
        .post(Uri.parse('$_base/support-requests/$id/resolve/'),
            headers: _jsonHeaders,
            body: jsonEncode(
                {'resolved_by': resolvedBy, 'response': response}))
        .timeout(const Duration(seconds: 20));
    _guard(res);
    if (res.statusCode != 200) {
      throw Exception('Resolve failed (${res.statusCode})');
    }
    return SupportRequest.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  /// The KPI rollup behind Home's strip and History's coverage bar — cache-first,
  /// and the one read most worth serving from disk: it is the heaviest query on
  /// the server and two tabs ask for it at once.
  static Future<CacheRead<DashboardData>> readDashboard({
    int? subdivision,
    bool force = false,
    bool allowNetwork = true,
  }) =>
      _read(
        LiCacheKeys.dashboard(subdivision: subdivision),
        () => _getBody('$_base/dashboard/${_q({'subdivision': subdivision})}',
            'Dashboard', timeout: const Duration(seconds: 25)),
        (b) => DashboardData.fromJson(jsonDecode(b) as Map<String, dynamic>),
        force: force,
        allowNetwork: allowNetwork,
        freshFor: freshList,
        what: 'the dashboard',
      );

  static Future<DashboardData> loadDashboard({int? subdivision}) async =>
      (await readDashboard(subdivision: subdivision, force: true)).latest;

  // ---- Submit --------------------------------------------------------------

  /// Creates one inspection (raw transport used by the [SyncEngine]). [items] is
  /// the flat slot list the create endpoint expects; slots/entries that carry a
  /// photo reference it by a `photo_key`, and [photos] maps each such key to the
  /// file to upload. Sent as multipart so the photos ride along. Idempotent on
  /// the server via [clientId]. Returns the decoded response.
  static Future<Map<String, dynamic>> submitInspection({
    required int towerId,
    required String inspectorEmployeeId,
    required int catalogVersion,
    required String date, // ISO yyyy-MM-dd
    required String remarks,
    required String clientId,
    required List<Map<String, dynamic>> items,
    Map<String, File> photos = const {},
    // GPS proof of presence (Phase 4). Nulls when no fix was available.
    double? inspectorLat,
    double? inspectorLng,
    double? gpsAccuracyM,
    String? presenceFlag,
    String overrideReason = '',
  }) async {
    final uri = Uri.parse('$_base/line-inspections/');
    final request = http.MultipartRequest('POST', uri);
    request.headers.addAll(_auth);
    // The whole structured inspection travels as one JSON field; photos are
    // separate file parts keyed by the tokens embedded in `items`.
    request.fields['payload'] = jsonEncode({
      'tower_id': towerId,
      'inspector_employee_id': inspectorEmployeeId,
      'catalog_version': catalogVersion,
      'date': date,
      'remarks': remarks,
      'client_id': clientId,
      'items': items,
      'inspector_lat': inspectorLat,
      'inspector_lng': inspectorLng,
      'gps_accuracy_m': gpsAccuracyM,
      'presence_flag': presenceFlag,
      'override_reason': overrideReason,
    });
    for (final entry in photos.entries) {
      request.files.add(
          await http.MultipartFile.fromPath(entry.key, entry.value.path));
    }
    final streamed = await request
        .send()
        .timeout(Duration(seconds: 40 + 20 * photos.length));
    final res = await http.Response.fromStream(streamed);
    _guard(res);
    if (res.statusCode == 200 || res.statusCode == 201) {
      return jsonDecode(res.body) as Map<String, dynamic>;
    }
    throw Exception('Save failed (${res.statusCode}): ${res.body}');
  }
}
