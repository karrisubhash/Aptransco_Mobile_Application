import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A cached response and when it was stored.
///
/// Both come out of one file read: the read layer needs the body *and* its age
/// on every cache-first read (the age decides whether the network is worth
/// hitting at all), and fetching them separately meant decoding the same JSON
/// wrapper twice per screen.
class CacheEntry {
  const CacheEntry(this.body, this.savedAt);
  final String body;
  final DateTime savedAt;

  Duration get age => DateTime.now().difference(savedAt);
}

/// Thrown by an offline-aware read when the device is offline and nothing has
/// ever been cached for that request. Callers surface it as a friendly
/// "connect once to load this" message rather than a raw error.
class OfflineNoCacheException implements Exception {
  const OfflineNoCacheException([this.what = 'this data']);
  final String what;
  @override
  String toString() =>
      "You're offline and $what hasn't been saved on this device yet. "
      'Connect to the internet once to load it.';
}

/// The app's durable on-device store — the foundation of offline support.
///
/// It owns four directories under the app's private support folder:
///  * `cache/`  — write-through copies of API responses (JSON), so every list
///    and detail screen still loads with no signal.
///  * `outbox/` — the queue of changes made offline, one file per change (see
///    [outboxDir]); durable so a crash never loses field work.
///  * `media/`  — photos staged for a queued inspection, copied out of the
///    OS picker cache (which the system may evict) so they survive until synced.
///  * `tiles/`  — cached map tiles, so a viewed area renders offline.
///  * `photos/` — server-side inspection photos pulled down for offline viewing,
///    so reopening a past inspection with no signal shows its evidence rather
///    than broken-image placeholders.
///
/// Everything is plain files: no native database, so it builds unchanged on
/// every platform the app already targets. Writes are atomic (temp file +
/// rename) so a kill mid-write can never leave a half-written record.
class LocalStore {
  LocalStore._();
  static final LocalStore instance = LocalStore._();

  late Directory _root;
  late Directory cacheDir;
  late Directory outboxDir;
  late Directory mediaDir;
  late Directory tilesDir;
  late Directory photosDir;

  bool _ready = false;
  bool get isReady => _ready;

  /// Resolve and create the store directories. Call once from `main()` before
  /// anything reads or writes. Safe to call more than once.
  Future<void> init() async {
    if (_ready) return;
    await _openUnder(await getApplicationSupportDirectory());
  }

  /// Re-point the store at [base], replacing any directories already open.
  ///
  /// Resolving the real base goes through `path_provider`, a plugin channel that
  /// isn't there under `flutter test`. This lets a test drive the genuine
  /// file-backed queue in a temp dir instead of mocking it away. Note the real
  /// futures only complete outside the widget tester's fake clock — use it from
  /// a plain `test()`, not `testWidgets`.
  @visibleForTesting
  Future<void> initUnder(Directory base) => _openUnder(base);

  Future<void> _openUnder(Directory base) async {
    _root = Directory(p.join(base.path, 'offline'));
    cacheDir = Directory(p.join(_root.path, 'cache'));
    outboxDir = Directory(p.join(_root.path, 'outbox'));
    mediaDir = Directory(p.join(_root.path, 'media'));
    tilesDir = Directory(p.join(_root.path, 'tiles'));
    photosDir = Directory(p.join(_root.path, 'photos'));
    for (final d in [_root, cacheDir, outboxDir, mediaDir, tilesDir, photosDir]) {
      if (!await d.exists()) await d.create(recursive: true);
    }
    _ready = true;
  }

  // ---- response cache ------------------------------------------------------

  File _cacheFile(String key) => File(p.join(cacheDir.path, '${_safe(key)}.json'));

  /// Store a raw API response [body] under [key], stamped with the time so the
  /// UI can show "updated N min ago".
  Future<void> putCache(String key, String body) async {
    if (!_ready) return;
    final wrapper = jsonEncode({
      't': DateTime.now().millisecondsSinceEpoch,
      'b': body,
    });
    await _atomicWrite(_cacheFile(key), wrapper);
  }

  /// The cached response body for [key], or null if nothing is cached.
  Future<String?> getCache(String key) async =>
      (await getCacheEntry(key))?.body;

  /// The cached response for [key] with its timestamp, or null if nothing is
  /// cached. One file read for both — see [CacheEntry].
  Future<CacheEntry?> getCacheEntry(String key) async {
    if (!_ready) return null;
    final f = _cacheFile(key);
    try {
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final body = m['b'] as String?;
      if (body == null) return null;
      final t = m['t'] as int?;
      return CacheEntry(
        body,
        t == null
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : DateTime.fromMillisecondsSinceEpoch(t),
      );
    } on FileSystemException {
      return null; // not cached yet
    } catch (_) {
      return null; // corrupt entry — treat as a miss
    }
  }

  /// When [key] was last cached, or null if never.
  Future<DateTime?> cacheTime(String key) async =>
      (await getCacheEntry(key))?.savedAt;

  Future<void> removeCache(String key) async {
    if (!_ready) return;
    final f = _cacheFile(key);
    if (await f.exists()) {
      try {
        await f.delete();
      } catch (_) {}
    }
  }

  /// Rewrite every cached response whose key starts with [prefix], applying
  /// [transform] to each cached body in place (filenames are preserved). Used to
  /// fan an optimistic edit across all cache variants of one resource — e.g.
  /// marking a ticket closed in every filtered ticket list after a queued close.
  /// [transform] receives the cached body and returns the new body (return it
  /// unchanged to leave that entry alone).
  Future<void> patchCachesWithPrefix(
      String prefix, String Function(String body) transform) async {
    if (!_ready) return;
    final safePrefix = _safe(prefix);
    try {
      await for (final e in cacheDir.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        if (!p.basename(e.path).startsWith(safePrefix)) continue;
        try {
          final m = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
          final body = m['b'] as String?;
          if (body == null) continue;
          final next = transform(body);
          if (identical(next, body) || next == body) continue;
          m['b'] = next;
          m['t'] = DateTime.now().millisecondsSinceEpoch;
          await _atomicWrite(e, jsonEncode(m));
        } catch (_) {
          // skip a corrupt or unexpected entry
        }
      }
    } catch (_) {}
  }

  // ---- signing out / switching employee ------------------------------------

  /// Drop everything on disk that belonged to the employee who was signed in:
  /// the API response cache and the offline photo cache.
  ///
  /// Cache keys are per-resource, not per-employee (`li_lines_all`,
  /// `li_dash_x`, `li_towers_<id>`, …), because for most of this app's life one
  /// device meant one engineer. They are still the right keys — a second
  /// employee's data simply must not be sitting in them, so a sign-out or a
  /// switch of employee empties the store rather than namespacing it.
  ///
  /// Deliberately does **not** touch `outbox/` or the `media/` its photos are
  /// staged in: those hold field work that never reached the server, and losing
  /// an inspection someone walked a line to capture is far worse than the
  /// staleness this fixes. The outbox is scoped by owner instead (see
  /// [OutboxOp.ownerId]) so another employee's queued work is never uploaded
  /// under this session's token. `tiles/` is left alone too — public base-map
  /// imagery says nothing about a jurisdiction, and re-fetching it would cost
  /// the next user a blank map for no gain.
  Future<void> purgeUserData() async {
    if (!_ready) return;
    await _emptyDir(cacheDir);
    await _emptyDir(photosDir);
  }

  /// Delete a directory's contents, keeping the directory itself (the store's
  /// handles stay valid, so nothing has to re-[init]). One stubborn file — a
  /// Windows AV lock, an open read — must not abort the rest of the purge.
  Future<void> _emptyDir(Directory d) async {
    try {
      if (!await d.exists()) return;
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ---- media staging -------------------------------------------------------

  /// Copy [src] (a photo from the OS picker's cache) into the durable media
  /// folder and return the new path. The queued inspection references this copy
  /// so the photo survives even if the picker cache is cleared before sync.
  Future<String> stageMedia(File src, String name) async {
    final dest = File(p.join(mediaDir.path, name));
    await src.copy(dest.path);
    return dest.path;
  }

  Future<void> deleteMedia(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  // ---- misc ----------------------------------------------------------------

  Future<void> _atomicWrite(File dest, String contents) async {
    final tmp = File('${dest.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(dest.path); // atomic on the same volume
  }

  /// A filesystem-safe file name for a cache key. The keys used by the app (see
  /// `li_cache_keys.dart`) are built only from `[A-Za-z0-9_]`, so this is an
  /// identity mapping for them — which keeps names stable and prefix-matchable
  /// (used by [patchCachesWithPrefix]). Any stray character is replaced so an
  /// unexpected key can never produce an invalid path.
  static String _safe(String key) {
    final cleaned = key.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }
}
