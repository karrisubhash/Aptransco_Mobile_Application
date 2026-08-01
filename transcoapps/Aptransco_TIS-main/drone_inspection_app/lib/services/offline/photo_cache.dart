import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../auth_store.dart';
import 'local_store.dart';

/// Disk cache for server-side inspection photos.
///
/// Photos were the last thing in the flow that still needed a signal: an
/// inspection's evidence lives at `/media/...` on the backend, so reopening a
/// past inspection offline showed broken-image placeholders where the online app
/// showed the photographs. `cached_network_image` kept only what had already
/// been *viewed*, and its default store evicts after 200 objects — a jurisdiction
/// has far more than that, so it could not be the offline answer either.
///
/// This mirrors [TileCache] deliberately: plain files, an LRU for what the user
/// browses and a never-pruned `pinned/` subdirectory for what the jurisdiction
/// download pulls in, so a deliberate download can't evict itself.
class PhotoCache {
  PhotoCache._();
  static final PhotoCache instance = PhotoCache._();

  /// Soft cap on the browse-driven half of the cache. Pruned back to 80% when
  /// exceeded. Photos are much larger than map tiles, so this is sized in the
  /// same spirit but holds far fewer objects.
  static const int _maxBytes = 200 * 1024 * 1024;

  final Map<String, Future<Uint8List?>> _inFlight = {};
  int _writesSincePrune = 0;

  Directory get _dir => LocalStore.instance.photosDir;

  /// Photos the background warmer pulled down. Kept apart from the browse cache
  /// so casual scrolling can't evict the set that makes the app work offline —
  /// but still budgeted ([_maxPinnedBytes]), because this is a cache the app
  /// manages, not a download the user owns.
  Directory get _pinnedDir => Directory(p.join(_dir.path, 'pinned'));

  /// Cap on the warmed set. Oldest-first eviction past this keeps a long-lived
  /// install from growing without bound.
  static const int _maxPinnedBytes = 350 * 1024 * 1024;

  int _pinnedWritesSincePrune = 0;

  File _fileFor(String url) => File(p.join(_dir.path, '${_hash(url)}.img'));
  File _pinnedFileFor(String url) =>
      File(p.join(_pinnedDir.path, '${_hash(url)}.img'));

  /// Bytes for [url] — from disk if cached (touched for LRU), else fetched and
  /// saved. Returns null when neither disk nor network can provide it.
  Future<Uint8List?> getBytes(String url) {
    final existing = _inFlight[url];
    if (existing != null) return existing;
    final fut = _get(url);
    _inFlight[url] = fut;
    return fut.whenComplete(() => _inFlight.remove(url));
  }

  Future<Uint8List?> _get(String url) async {
    if (!LocalStore.instance.isReady) return null;
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
    // Cache miss → network. Offline this fails fast (SocketException), so the
    // viewer falls straight through to its placeholder instead of hanging.
    try {
      final res = await http
          .get(Uri.parse(url), headers: AuthStore.instance.authHeaders())
          .timeout(const Duration(seconds: 20));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        await _write(f, res.bodyBytes);
        return res.bodyBytes;
      }
    } catch (_) {}
    return null;
  }

  /// Whether [url] is already on disk (pinned or LRU) — lets the jurisdiction
  /// download skip what it already holds and report honest progress.
  Future<bool> has(String url) async {
    if (!LocalStore.instance.isReady) return false;
    try {
      if (await _pinnedFileFor(url).exists()) return true;
      if (await _fileFor(url).exists()) return true;
    } catch (_) {}
    return false;
  }

  /// Fetch and PIN one photo for offline use. Returns the bytes written, or null
  /// on failure. A photo already pinned is not re-fetched unless [force].
  Future<int?> prefetchPinned(String url, {bool force = false}) async {
    if (!LocalStore.instance.isReady) return null;
    final pinned = _pinnedFileFor(url);
    try {
      if (!force && await pinned.exists()) return await pinned.length();
    } catch (_) {}
    try {
      await _pinnedDir.create(recursive: true);
      final res = await http
          .get(Uri.parse(url), headers: AuthStore.instance.authHeaders())
          .timeout(const Duration(seconds: 30));
      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        final tmp = File('${pinned.path}.tmp');
        await tmp.writeAsBytes(res.bodyBytes, flush: true);
        await tmp.rename(pinned.path);
        if (++_pinnedWritesSincePrune >= 50) {
          _pinnedWritesSincePrune = 0;
          unawaited(_prunePinned());
        }
        return res.bodyBytes.length;
      }
    } catch (_) {}
    return null;
  }

  /// Evict the oldest warmed photos once the set passes its budget. Oldest-first
  /// matches what the warmer refills: it walks newest inspections first, so an
  /// evicted old photo is the least likely to be wanted and the last to return.
  Future<void> _prunePinned() async {
    try {
      if (!await _pinnedDir.exists()) return;
      final files = <File>[];
      var total = 0;
      await for (final e in _pinnedDir.list()) {
        if (e is File && e.path.endsWith('.img')) {
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

  /// Total bytes of the pinned photo set, for the storage readout.
  Future<int> pinnedBytes() async {
    if (!LocalStore.instance.isReady) return 0;
    var total = 0;
    try {
      if (!await _pinnedDir.exists()) return 0;
      await for (final e in _pinnedDir.list()) {
        if (e is File && e.path.endsWith('.img')) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  /// Delete the pinned photo set (free up space).
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
      if (++_writesSincePrune >= 50) {
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
        if (e is File && e.path.endsWith('.img')) {
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

  /// Cache file name for [s] (a media URL).
  ///
  /// Two independent 32-bit hashes (FNV-1a and djb2) concatenated, so the name
  /// space is 64-bit. A single 32-bit hash was not enough here: by the birthday
  /// bound a jurisdiction of ~10k photos carries a ~1% chance that *some* pair
  /// collides, and a collision is silent and wrong in the worst way — one
  /// inspection's evidence photo served in place of another's, in a record that
  /// exists to be an audit trail. At 64 bits the same set is ~1 in 10^11.
  ///
  /// Changing the scheme orphans files written by earlier builds. That is safe:
  /// they are simply never read again, and both prune passes are size-budgeted
  /// and oldest-first, so they are reclaimed in the normal course of things.
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

/// An [ImageProvider] that serves an inspection photo through [PhotoCache], so
/// the same widget renders it whether or not there is a signal.
class CachedPhotoImage extends ImageProvider<CachedPhotoImage> {
  const CachedPhotoImage(this.url);
  final String url;

  @override
  Future<CachedPhotoImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<CachedPhotoImage>(this);

  @override
  ImageStreamCompleter loadImage(
      CachedPhotoImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await PhotoCache.instance.getBytes(url);
    if (bytes == null || bytes.isEmpty) {
      // Neither disk nor network — the thumbnail shows its offline placeholder.
      throw StateError('Photo unavailable offline: $url');
    }
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is CachedPhotoImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
