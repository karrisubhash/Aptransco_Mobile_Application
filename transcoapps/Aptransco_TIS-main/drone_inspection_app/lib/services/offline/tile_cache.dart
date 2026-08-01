import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'local_store.dart';

/// A [TileProvider] that serves map tiles from an on-disk cache, falling back to
/// the network and saving what it downloads. Any area viewed while online is
/// therefore available offline. Nothing is pre-downloaded — the cache fills as
/// the inspector pans/zooms (auto-cache), keeping the map UI unchanged.
class CachedTileProvider extends TileProvider {
  CachedTileProvider({super.headers});

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _CachedTileImage(getTileUrl(coordinates, options), Map.of(headers));
}

class _CachedTileImage extends ImageProvider<_CachedTileImage> {
  const _CachedTileImage(this.url, this.headers);
  final String url;
  final Map<String, String> headers;

  @override
  Future<_CachedTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_CachedTileImage>(this);

  @override
  ImageStreamCompleter loadImage(
      _CachedTileImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await TileCache.instance.getTileBytes(url, headers);
    if (bytes == null || bytes.isEmpty) {
      // No cache and no network: let flutter_map show its empty tile.
      throw StateError('Tile unavailable offline: $url');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is _CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// Disk cache for map tiles with a rough LRU size cap.
class TileCache {
  TileCache._();
  static final TileCache instance = TileCache._();

  /// Soft cap on total cached tiles. Pruned back to 80% when exceeded.
  static const int _maxBytes = 160 * 1024 * 1024;

  final Map<String, Future<Uint8List?>> _inFlight = {};
  int _writesSincePrune = 0;

  Directory get _dir => LocalStore.instance.tilesDir;

  // Tiles the background warmer pulled down live in a subdirectory the browse
  // LRU never scans, so panning around can't evict the corridor coverage that
  // makes the map work offline. The reader checks pinned first, then the LRU
  // cache. Budgeted by [_maxPinnedBytes] — this is a managed cache, not a
  // permanent download.
  Directory get _pinnedDir => Directory(p.join(_dir.path, 'pinned'));

  /// Cap on the warmed tile set, evicted oldest-first past this point.
  static const int _maxPinnedBytes = 300 * 1024 * 1024;

  int _pinnedWritesSincePrune = 0;

  File _fileFor(String url) => File(p.join(_dir.path, '${_hash(url)}.tile'));
  File _pinnedFileFor(String url) => File(p.join(_pinnedDir.path, '${_hash(url)}.tile'));

  /// Bytes for [url] — from disk if cached (touched for LRU), else fetched and
  /// saved. Returns null when neither disk nor network can provide it.
  Future<Uint8List?> getTileBytes(String url, Map<String, String> headers) {
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final fut = _get(url, headers);
    _inFlight[url] = fut;
    return fut.whenComplete(() => _inFlight.remove(url));
  }

  Future<Uint8List?> _get(String url, Map<String, String> headers) async {
    if (!LocalStore.instance.isReady) return null;
    // Pinned region tiles first (never pruned).
    final pinned = _pinnedFileFor(url);
    try {
      if (await pinned.exists()) return await pinned.readAsBytes();
    } catch (_) {}
    final f = _fileFor(url);
    try {
      if (await f.exists()) {
        try {
          await f.setLastModified(DateTime.now()); // LRU touch
        } catch (_) {}
        return await f.readAsBytes();
      }
    } catch (_) {}
    // Cache miss → try the network. When truly offline this fails fast
    // (SocketException), so there's no long hang; the timeout only bounds a
    // slow/blocked link.
    try {
      final res = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 12));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        await _write(f, res.bodyBytes);
        return res.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  /// Whether [url] is already available on disk (pinned or LRU) — lets a region
  /// download skip tiles it already has.
  Future<bool> hasTile(String url) async {
    if (!LocalStore.instance.isReady) return false;
    try {
      if (await _pinnedFileFor(url).exists()) return true;
      if (await _fileFor(url).exists()) return true;
    } catch (_) {}
    return false;
  }

  /// Fetch and PIN one tile for offline use (region download). Pinned tiles are
  /// stored apart from the LRU cache so the prune never evicts them. Returns the
  /// bytes written, or null on failure. [force] re-downloads even if present.
  Future<int?> prefetchPinned(String url, Map<String, String> headers,
      {bool force = false}) async {
    if (!LocalStore.instance.isReady) return null;
    final pinned = _pinnedFileFor(url);
    try {
      if (!force && await pinned.exists()) return await pinned.length();
    } catch (_) {}
    try {
      await _pinnedDir.create(recursive: true);
      final res = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        final tmp = File('${pinned.path}.tmp');
        await tmp.writeAsBytes(res.bodyBytes, flush: true);
        await tmp.rename(pinned.path);
        if (++_pinnedWritesSincePrune >= 200) {
          _pinnedWritesSincePrune = 0;
          unawaited(_prunePinned());
        }
        return res.bodyBytes.length;
      }
    } catch (_) {}
    return null;
  }

  /// Evict the oldest warmed tiles once the set passes its budget, so a
  /// long-lived install settles at a bounded size rather than growing forever.
  Future<void> _prunePinned() async {
    try {
      if (!await _pinnedDir.exists()) return;
      final files = <File>[];
      var total = 0;
      await for (final e in _pinnedDir.list()) {
        if (e is File && e.path.endsWith('.tile')) {
          total += await e.length();
          files.add(e);
        }
      }
      if (total <= _maxPinnedBytes) return;
      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified));
      final target = (_maxPinnedBytes * 0.8).round();
      for (final f in files) {
        if (total <= target) break;
        try {
          total -= await f.length();
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Total bytes of the pinned region cache.
  Future<int> pinnedBytes() async {
    if (!LocalStore.instance.isReady) return 0;
    var total = 0;
    try {
      if (!await _pinnedDir.exists()) return 0;
      await for (final e in _pinnedDir.list()) {
        if (e is File && e.path.endsWith('.tile')) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// Delete the pinned region cache (free up space).
  Future<void> clearPinned() async {
    try {
      if (await _pinnedDir.exists()) await _pinnedDir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _write(File f, Uint8List bytes) async {
    try {
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(f.path);
      if (++_writesSincePrune >= 200) {
        _writesSincePrune = 0;
        unawaited(_prune());
      }
    } catch (_) {}
  }

  Future<void> _prune() async {
    try {
      final files = <File>[];
      var total = 0;
      await for (final e in _dir.list()) {
        if (e is File && e.path.endsWith('.tile')) {
          total += await e.length();
          files.add(e);
        }
      }
      if (total <= _maxBytes) return;
      files.sort((a, b) =>
          a.statSync().modified.compareTo(b.statSync().modified)); // oldest first
      final target = (_maxBytes * 0.8).round();
      for (final f in files) {
        if (total <= target) break;
        try {
          total -= await f.length();
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Cache file name for [s] (a tile URL). Two independent 32-bit hashes (FNV-1a
  /// and djb2) concatenated, for a 64-bit name space — see the same method on
  /// [PhotoCache]. A warmed jurisdiction holds tens of thousands of tiles, where
  /// a 32-bit name collided often enough to paint the wrong square of ground.
  static String _hash(String s) {
    var fnv = 0x811c9dc5;
    var djb = 5381;
    for (final c in s.codeUnits) {
      fnv = ((fnv ^ c) * 0x01000193) & 0xffffffff;
      djb = ((djb * 33) ^ c) & 0xffffffff;
    }
    return '${fnv.toRadixString(16).padLeft(8, '0')}'
        '${djb.toRadixString(16).padLeft(8, '0')}';
  }
}
