import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../models/inspection_catalog.dart';
import '../../models/li_asset.dart';
import '../line_inspection_api.dart';
import 'connectivity_service.dart';
import 'li_cache_keys.dart';
import 'local_store.dart';
import 'outbox.dart';
import 'sync_engine.dart';

/// Result of saving an inspection offline-first.
class SaveInspectionResult {
  const SaveInspectionResult({required this.synced, required this.ticketsRaised});

  /// True if it uploaded to the server before this call returned; false means it
  /// is safely queued and will upload automatically on reconnect.
  final bool synced;
  final int ticketsRaised;
}

/// Result of a lighter mutation (ticket close, support create/resolve).
class QueueResult {
  const QueueResult(this.queued);

  /// True if the change went to the offline queue; false if it committed live.
  final bool queued;
}

/// The write side of offline-first: every change is captured durably and made
/// to appear immediately (optimistic cache), whether or not there is a signal.
///
/// Inspections are always queued first (so a crash right after "Save" never
/// loses field work) and, if online, synced before returning. Ticket/support
/// changes are attempted live when online and fall back to the queue on a
/// transport failure. All optimistic edits are eventually overwritten by
/// authoritative server data on the next successful read/sync.
class OfflineActions {
  // ---- inspections ---------------------------------------------------------

  static Future<SaveInspectionResult> saveInspection({
    required LiTower tower,
    required String inspectorEmployeeId,
    required int catalogVersion,
    required String date,
    required String remarks,
    required String clientId,
    required List<Map<String, dynamic>> items,
    required Map<String, File> photos,
    required InspectionCatalog catalog,
    required String worst,
    required int defectCount,
    double? inspectorLat,
    double? inspectorLng,
    double? gpsAccuracyM,
    String presenceFlag = 'in_range',
    String overrideReason = '',
  }) async {
    // 1. Copy photos out of the picker cache into durable storage.
    final media = <String, String>{};
    for (final entry in photos.entries) {
      final name = '${clientId}_${entry.key}${_ext(entry.value.path)}';
      media[entry.key] = await LocalStore.instance.stageMedia(entry.value, name);
    }

    // 2. Queue the change (client_id doubles as the server idempotency key).
    final payload = <String, dynamic>{
      'tower_id': tower.id,
      'inspector_employee_id': inspectorEmployeeId,
      'catalog_version': catalogVersion,
      'date': date,
      'remarks': remarks,
      'items': items,
      // GPS proof of presence — flows through to submitInspection on sync.
      'inspector_lat': inspectorLat,
      'inspector_lng': inspectorLng,
      'gps_accuracy_m': gpsAccuracyM,
      'presence_flag': presenceFlag,
      'override_reason': overrideReason,
      // Metadata for labels + optimistic display; ignored by the create view.
      'tower_number': tower.towerNumber,
      'tower_type': tower.towerType,
      'line_name': tower.lineName,
      'line_id': tower.lineId,
      'worst': worst,
      'defect_count': defectCount,
    };
    final op = await OutboxStore.instance
        .enqueue(OpType.inspection, payload, media: media, id: clientId);
    final negId = -op.createdAt; // stable negative id for the optimistic rows

    // 3. Show it right away in History + Map, even with no signal.
    await _insertOptimisticSummary(
        tower, inspectorEmployeeId, date, worst, defectCount, negId);
    await _cacheSyntheticDetail(tower, inspectorEmployeeId, date, remarks, worst,
        catalogVersion, items, media, catalog, negId);

    // 4. If online, drain now so the caller knows if it committed.
    var synced = false;
    if (ConnectivityService.instance.online.value) {
      await SyncEngine.instance.syncNow();
      final remaining = await OutboxStore.instance.list();
      synced = !remaining.any((o) => o.id == clientId);
      if (synced) {
        // Authoritative data replaces the cache on the next read; drop the
        // optimistic rows so an offline read can't show a duplicate. This must
        // clear every key the insert wrote — including the line-less case, which
        // used to be skipped here and left the row behind for good.
        await _removeOptimisticSummary(
            tower.lineId, inspectorEmployeeId, negId);
        await LocalStore.instance
            .removeCache(LiCacheKeys.inspectionDetail(negId));
      }
    } else {
      SyncEngine.instance.kick();
    }
    return SaveInspectionResult(synced: synced, ticketsRaised: defectCount);
  }

  /// The cache keys an optimistic row belongs in, so a save with no signal shows
  /// up everywhere the same save would have shown up online:
  ///  * the per-line list the Home map and line views read;
  ///  * the **unscoped** list the History tab reads;
  ///  * the inspector-scoped list, for the callers that still narrow by employee.
  ///
  /// The unscoped key is the load-bearing one. History deliberately stopped
  /// narrowing to `?inspector=<me>` (a supervisor captures nothing themselves, so
  /// the scoped list left them looking at an empty tab — see `inspections_tab`),
  /// but this write was never moved with it. The result was an inspection saved
  /// offline that appeared on the map and nowhere in History until it synced.
  /// [lineId] is null for a tower with no line context: the per-line key is then
  /// simply omitted, rather than the row being dropped altogether — History and
  /// the inspector's own list still have somewhere to hold it.
  static List<String> _summaryKeys(int? lineId, String inspector) => [
        if (lineId != null) LiCacheKeys.inspections(line: lineId),
        LiCacheKeys.inspections(),
        LiCacheKeys.inspections(inspector: inspector),
      ];

  static Future<void> _insertOptimisticSummary(LiTower tower, String inspector,
      String date, String worst, int defectCount, int negId) async {
    final lineId = tower.lineId;
    final now = DateTime.now().toIso8601String();
    final summary = {
      'id': negId,
      'tower_id': tower.id,
      'tower_number': tower.towerNumber,
      'tower_type': tower.towerType,
      'line_name': tower.lineName,
      'date': date,
      'inspector_employee_id': inspector,
      'worst_criticality': worst,
      'defect_count': defectCount,
      'saved_at': now,
      'created_at': now,
      '_pending': true,
    };
    for (final key in _summaryKeys(lineId, inspector)) {
      final list = _decodeList(await LocalStore.instance.getCache(key));
      list.removeWhere((e) => e is Map && e['id'] == negId);
      list.insert(0, summary);
      await LocalStore.instance.putCache(key, jsonEncode(list));
    }
  }

  static Future<void> _removeOptimisticSummary(
      int? lineId, String inspector, int negId) async {
    for (final key in _summaryKeys(lineId, inspector)) {
      final body = await LocalStore.instance.getCache(key);
      if (body == null) continue;
      final list = _decodeList(body)
        ..removeWhere((e) => e is Map && e['id'] == negId);
      await LocalStore.instance.putCache(key, jsonEncode(list));
    }
  }

  static Future<void> _cacheSyntheticDetail(
    LiTower tower,
    String inspector,
    String date,
    String remarks,
    String worst,
    int catalogVersion,
    List<Map<String, dynamic>> items,
    Map<String, String> media,
    InspectionCatalog catalog,
    int negId,
  ) async {
    final itemById = {for (final it in catalog.allItems) it.id: it};
    var synthSeq = -1;
    final itemResults = <Map<String, dynamic>>[];
    for (final item in items) {
      final itemId = item['item_id'];
      final it = itemById[itemId];
      final entries = <Map<String, dynamic>>[];
      for (final e in (item['entries'] as List? ?? const [])) {
        final m = (e as Map).cast<String, dynamic>();
        final def = it?.defectById(m['defect_id'] as int? ?? -1);
        entries.add({
          'id': synthSeq--,
          'defect_id': m['defect_id'],
          'defect_key': def?.key ?? '',
          'defect_label': def?.label ?? '',
          'answers': m['answers'] ?? const {},
          'criticality': m['criticality'] ?? 'minor',
          'suggested_criticality':
              m['suggested_criticality'] ?? m['criticality'] ?? 'minor',
          'note': m['note'] ?? '',
          'photo': _localRef(m['photo_key'] as String?, media),
        });
      }
      itemResults.add({
        'id': synthSeq--,
        'item_id': itemId,
        'item_key': it?.key ?? '',
        'item_label': it?.label ?? '',
        'sno': it?.sno ?? 0,
        'group_key': it?.groupKey ?? '',
        'position': item['position'] ?? '',
        'status': item['status'] ?? 'normal',
        'meta': item['meta'] ?? const {},
        'photo': _localRef(item['photo_key'] as String?, media),
        'entries': entries,
      });
    }
    final now = DateTime.now().toIso8601String();
    final detail = {
      'id': negId,
      'tower_id': tower.id,
      'tower_number': tower.towerNumber,
      'tower_type': tower.towerType,
      'line_name': tower.lineName,
      'date': date,
      'inspector_employee_id': inspector,
      'catalog_version': catalogVersion,
      'remarks': remarks,
      'worst_criticality': worst,
      'saved_at': now,
      'created_at': now,
      'item_results': itemResults,
    };
    await LocalStore.instance
        .putCache(LiCacheKeys.inspectionDetail(negId), jsonEncode(detail));
  }

  // ---- tickets -------------------------------------------------------------

  static Future<QueueResult> closeTicket({
    required int ticketId,
    required String closedBy,
    required String note,
  }) async {
    if (ConnectivityService.instance.online.value) {
      try {
        await LineInspectionApi.closeTicket(ticketId,
            closedBy: closedBy, note: note);
        await _patchTicketClosed(ticketId, closedBy, note);
        SyncEngine.instance.kick();
        return const QueueResult(false);
      } catch (e) {
        if (!_isNetworkError(e)) rethrow; // real server rejection — surface it
      }
    }
    await OutboxStore.instance.enqueue(OpType.ticketClose, {
      'ticket_id': ticketId,
      'closed_by': closedBy,
      'close_note': note,
    });
    await _patchTicketClosed(ticketId, closedBy, note);
    SyncEngine.instance.kick();
    return const QueueResult(true);
  }

  static Future<void> _patchTicketClosed(
      int ticketId, String closedBy, String note) async {
    await LocalStore.instance
        .patchCachesWithPrefix(LiCacheKeys.ticketsPrefix, (body) {
      try {
        final list = jsonDecode(body) as List;
        var changed = false;
        for (final t in list) {
          if (t is Map && t['id'] == ticketId) {
            t['status'] = 'closed';
            t['closed_by_employee_id'] = closedBy;
            t['close_note'] = note;
            changed = true;
          }
        }
        return changed ? jsonEncode(list) : body;
      } catch (_) {
        return body;
      }
    });
  }

  // ---- support -------------------------------------------------------------

  static Future<QueueResult> createSupport({
    required String raisedBy,
    required String category,
    required String subject,
    required String text,
    int? subdivisionId,
    String subdivisionName = '',
    int? scopeSubdivisionId,
  }) async {
    if (ConnectivityService.instance.online.value) {
      try {
        await LineInspectionApi.createSupportRequest(
          raisedBy: raisedBy,
          category: category,
          subject: subject,
          text: text,
          subdivisionId: subdivisionId,
        );
        SyncEngine.instance.kick();
        return const QueueResult(false); // caller reloads → authoritative list
      } catch (e) {
        if (!_isNetworkError(e)) rethrow;
      }
    }
    await OutboxStore.instance.enqueue(OpType.supportCreate, {
      'raised_by': raisedBy,
      'category': category,
      'subject': subject,
      'text': text,
      'subdivision_id': subdivisionId,
    });
    await _prependSyntheticSupport(
        raisedBy, category, subject, text, subdivisionId, subdivisionName,
        scopeSubdivisionId ?? subdivisionId);
    SyncEngine.instance.kick();
    return const QueueResult(true);
  }

  static Future<void> _prependSyntheticSupport(
    String raisedBy,
    String category,
    String subject,
    String text,
    int? subdivisionId,
    String subdivisionName,
    int? scopeSubdivisionId,
  ) async {
    final synthetic = {
      'id': -DateTime.now().millisecondsSinceEpoch,
      'raised_by_employee_id': raisedBy,
      'category': category,
      'subject': subject,
      'text': text,
      'status': 'open',
      'created_at': DateTime.now().toIso8601String(),
      'response': '',
      'resolved_by_employee_id': '',
      'resolved_at': null,
      'subdivision_id': subdivisionId,
      'subdivision_name': subdivisionName,
      '_pending': true,
    };
    // Upsert into the exact key the Support tab reads, creating it if needed so
    // the request is visible offline even if the list was never loaded online.
    final key = LiCacheKeys.support(subdivision: scopeSubdivisionId);
    final list = _decodeList(await LocalStore.instance.getCache(key))
      ..insert(0, synthetic);
    await LocalStore.instance.putCache(key, jsonEncode(list));
  }

  static Future<QueueResult> resolveSupport({
    required int supportId,
    required String resolvedBy,
    required String response,
  }) async {
    if (ConnectivityService.instance.online.value) {
      try {
        await LineInspectionApi.resolveSupportRequest(supportId,
            resolvedBy: resolvedBy, response: response);
        await _patchSupportResolved(supportId, resolvedBy, response);
        SyncEngine.instance.kick();
        return const QueueResult(false);
      } catch (e) {
        if (!_isNetworkError(e)) rethrow;
      }
    }
    await OutboxStore.instance.enqueue(OpType.supportResolve, {
      'support_id': supportId,
      'resolved_by': resolvedBy,
      'response': response,
    });
    await _patchSupportResolved(supportId, resolvedBy, response);
    SyncEngine.instance.kick();
    return const QueueResult(true);
  }

  static Future<void> _patchSupportResolved(
      int supportId, String resolvedBy, String response) async {
    await LocalStore.instance
        .patchCachesWithPrefix(LiCacheKeys.supportPrefix, (body) {
      try {
        final list = jsonDecode(body) as List;
        var changed = false;
        for (final r in list) {
          if (r is Map && r['id'] == supportId) {
            r['status'] = 'resolved';
            r['resolved_by_employee_id'] = resolvedBy;
            r['response'] = response;
            changed = true;
          }
        }
        return changed ? jsonEncode(list) : body;
      } catch (_) {
        return body;
      }
    });
  }

  // ---- helpers -------------------------------------------------------------

  static List<dynamic> _decodeList(String? body) {
    if (body == null) return <dynamic>[];
    try {
      final v = jsonDecode(body);
      return v is List ? v : <dynamic>[];
    } catch (_) {
      return <dynamic>[];
    }
  }

  /// Encode a staged photo as a `local://<path>` reference so the detail viewer
  /// can render it from disk before the inspection syncs.
  static String? _localRef(String? key, Map<String, String> media) {
    if (key == null) return null;
    final path = media[key];
    return path == null ? null : 'local://$path';
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    if (i < 0) return '.jpg';
    final e = path.substring(i).toLowerCase();
    return e.length <= 5 ? e : '.jpg';
  }

  static bool _isNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is http.ClientException ||
      e is HandshakeException;
}
