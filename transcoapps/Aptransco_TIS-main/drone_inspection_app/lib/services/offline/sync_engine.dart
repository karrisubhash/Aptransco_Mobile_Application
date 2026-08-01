import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../line_inspection_api.dart';
import 'connectivity_service.dart';
import 'outbox.dart';

enum SyncPhase { idle, syncing, offline }

/// A snapshot of the sync subsystem, published to the UI.
@immutable
class SyncStatus {
  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.pending = 0,
    this.failed = 0,
    this.lastSyncedAt,
    this.lastError,
  });

  final SyncPhase phase;

  /// Changes still waiting to upload (not counting permanently-failed ones).
  final int pending;

  /// Changes the server keeps rejecting; kept for visibility, no longer retried.
  final int failed;

  final DateTime? lastSyncedAt;
  final String? lastError;

  bool get isBusy => phase == SyncPhase.syncing;
  bool get hasWork => pending > 0 || failed > 0;

  SyncStatus copyWith({
    SyncPhase? phase,
    int? pending,
    int? failed,
    DateTime? lastSyncedAt,
    String? lastError,
  }) =>
      SyncStatus(
        phase: phase ?? this.phase,
        pending: pending ?? this.pending,
        failed: failed ?? this.failed,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        lastError: lastError ?? this.lastError,
      );
}

/// Drains the offline [OutboxStore] to the backend whenever it is reachable.
///
/// Ops are sent in FIFO order and are individually idempotent on the server
/// (inspections via `client_id`; ticket-close / support-resolve are naturally
/// idempotent; support-create is de-duplicated server-side), so a retry after a
/// lost response never creates a duplicate. Transport failures stop the pass and
/// wait for connectivity; genuine server rejections are retried a bounded number
/// of times, then parked as "failed" so one bad record can't wedge the queue.
class SyncEngine {
  SyncEngine._();
  static final SyncEngine instance = SyncEngine._();

  static const int _maxAttempts = 8;

  final ValueNotifier<SyncStatus> status = ValueNotifier(const SyncStatus());

  /// Bumped every time an op successfully syncs, so open screens can refresh
  /// themselves against the now-authoritative server data.
  final ValueNotifier<int> dataRevision = ValueNotifier(0);

  bool _syncing = false;
  bool _started = false;
  bool _rerunRequested = false;
  Timer? _retryTimer;

  /// Begin listening for connectivity and attempt an initial drain.
  void start() {
    if (_started) return;
    _started = true;
    ConnectivityService.instance.online.addListener(_onOnlineChanged);
    unawaited(_refreshStatus());
    kick();
  }

  void _onOnlineChanged() {
    if (ConnectivityService.instance.online.value) {
      kick();
    } else {
      unawaited(_refreshStatus());
    }
  }

  /// Called when the app returns to the foreground.
  void onResume() {
    ConnectivityService.instance.refresh();
    kick();
  }

  /// Fire-and-forget drain. If one is already running, request a follow-up pass
  /// so changes enqueued mid-drain sync promptly instead of waiting for a timer.
  void kick() {
    if (_syncing) {
      _rerunRequested = true;
    } else {
      unawaited(_drain());
    }
  }

  /// Await a full drain — used right after saving an inspection while online so
  /// the caller knows whether it committed. Re-probes connectivity first.
  Future<void> syncNow() async {
    await ConnectivityService.instance.refresh();
    await _drain();
  }

  /// Put every parked change back in the queue and drain.
  ///
  /// [_drain] skips `failed` ops and nothing else ever clears the flag, so once a
  /// change was parked it could never be sent again — not by the retry timer, not
  /// by "Sync now", not by the banner's own "Retry". That is wrong whenever the
  /// refusal was situational (a jurisdiction gap since granted, a server fix
  /// since deployed): the record is still on the device and still valid. Clearing
  /// the attempt count as well gives them a full fresh set of tries.
  ///
  /// Returns the number of changes revived.
  Future<int> retryFailed() async {
    final revived = await unparkFailed();
    await syncNow();
    return revived;
  }

  /// Clears the parked flag (and the spent attempt count) on every failed change
  /// so the next drain picks them up, without draining here. Split out from
  /// [retryFailed] so the revival is verifiable on its own, with no network.
  ///
  /// Returns the number of changes revived.
  Future<int> unparkFailed() async {
    final ops = await OutboxStore.instance.list();
    var revived = 0;
    for (final op in ops) {
      if (!op.failed) continue;
      op.failed = false;
      op.attempts = 0;
      op.lastError = null;
      await OutboxStore.instance.update(op);
      revived++;
    }
    if (revived > 0) await _refreshStatus();
    return revived;
  }

  /// Drop a change the server keeps refusing, discarding its staged photos.
  ///
  /// [_drain] skips parked ops forever, so without a way to remove one the queue
  /// — and the "didn't sync" banner over every screen — can never clear. Losing
  /// the record is the point here, so callers must confirm with the inspector
  /// first.
  Future<void> discard(OutboxOp op) async {
    await OutboxStore.instance.remove(op);
    await _refreshStatus();
  }

  Future<void> _drain() async {
    if (_syncing) {
      _rerunRequested = true;
      return;
    }
    if (!ConnectivityService.instance.online.value) {
      await _refreshStatus();
      return;
    }
    _syncing = true;
    _rerunRequested = false;
    _retryTimer?.cancel();
    await _refreshStatus();

    var networkBroke = false;
    var authRefused = false;
    try {
      final ops = await OutboxStore.instance.list();
      for (final op in ops) {
        if (op.failed) continue;
        if (!ConnectivityService.instance.online.value) break;
        try {
          await _execute(op);
          await OutboxStore.instance.remove(op);
          dataRevision.value++;
          status.value = status.value.copyWith(lastSyncedAt: DateTime.now());
        } catch (e) {
          if (_isNetworkError(e)) {
            networkBroke = true;
            ConnectivityService.instance.reportFailure();
            break;
          }
          if (e is UnauthorizedException) {
            // The token is dead, not the record. Spending an attempt here would
            // charge real field work for an authentication problem: every
            // remaining op fails identically, so one expired token (they last 30
            // days, so this happens to every install) walked the whole queue
            // through its 8 attempts and parked genuine inspections as
            // "didn't sync" — recoverable only by the inspector finding Retry.
            // Stop the pass instead and leave the queue exactly as it was; a
            // fresh sign-in kicks it again.
            authRefused = true;
            break;
          }
          op.attempts++;
          op.lastError = _short(e);
          if (op.attempts >= _maxAttempts) op.failed = true;
          await OutboxStore.instance.update(op);
        }
      }
    } finally {
      _syncing = false;
      await _refreshStatus();
      if (_rerunRequested && ConnectivityService.instance.online.value) {
        _rerunRequested = false;
        unawaited(_drain());
      } else if (!networkBroke && !authRefused) {
        // No retry timer while the token is refused: it would re-probe every 30 s
        // for as long as the app is open and never make progress.
        _maybeScheduleRetry();
      }
    }
  }

  Future<void> _execute(OutboxOp op) async {
    switch (op.type) {
      case OpType.inspection:
        final photos = <String, File>{
          for (final e in op.media.entries) e.key: File(e.value),
        };
        final items = ((op.payload['items'] as List?) ?? const [])
            .map((e) => (e as Map).cast<String, dynamic>())
            .toList();
        await LineInspectionApi.submitInspection(
          towerId: op.payload['tower_id'] as int,
          inspectorEmployeeId:
              op.payload['inspector_employee_id'] as String? ?? 'unknown',
          catalogVersion: op.payload['catalog_version'] as int? ?? 0,
          date: op.payload['date'] as String,
          remarks: op.payload['remarks'] as String? ?? '',
          clientId: op.id,
          items: items,
          photos: photos,
          inspectorLat: (op.payload['inspector_lat'] as num?)?.toDouble(),
          inspectorLng: (op.payload['inspector_lng'] as num?)?.toDouble(),
          gpsAccuracyM: (op.payload['gps_accuracy_m'] as num?)?.toDouble(),
          presenceFlag: op.payload['presence_flag'] as String?,
          overrideReason: op.payload['override_reason'] as String? ?? '',
        );
        break;
      case OpType.ticketClose:
        await LineInspectionApi.closeTicket(
          op.payload['ticket_id'] as int,
          closedBy: op.payload['closed_by'] as String? ?? 'unknown',
          note: op.payload['close_note'] as String? ?? '',
        );
        break;
      case OpType.supportCreate:
        await LineInspectionApi.createSupportRequest(
          raisedBy: op.payload['raised_by'] as String? ?? 'unknown',
          category: op.payload['category'] as String? ?? '',
          subject: op.payload['subject'] as String? ?? '',
          text: op.payload['text'] as String? ?? '',
          subdivisionId: op.payload['subdivision_id'] as int?,
        );
        break;
      case OpType.supportResolve:
        await LineInspectionApi.resolveSupportRequest(
          op.payload['support_id'] as int,
          resolvedBy: op.payload['resolved_by'] as String? ?? 'unknown',
          response: op.payload['response'] as String? ?? '',
        );
        break;
      default:
        // Unknown op type from a newer/older build — drop it rather than wedge.
        return;
    }
  }

  void _maybeScheduleRetry() {
    if (status.value.pending > 0 &&
        ConnectivityService.instance.online.value) {
      _retryTimer?.cancel();
      _retryTimer = Timer(const Duration(seconds: 30), kick);
    }
  }

  Future<void> _refreshStatus() async {
    final ops = await OutboxStore.instance.list();
    final pending = ops.where((o) => !o.failed).length;
    final failed = ops.where((o) => o.failed).length;
    final SyncPhase phase = _syncing
        ? SyncPhase.syncing
        : (ConnectivityService.instance.online.value
            ? SyncPhase.idle
            : SyncPhase.offline);
    final lastError = ops
        .where((o) => o.lastError != null)
        .fold<String?>(null, (prev, o) => o.lastError);
    status.value = status.value.copyWith(
      phase: phase,
      pending: pending,
      failed: failed,
      lastError: lastError,
    );
  }

  static bool _isNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is http.ClientException ||
      e is HandshakeException;

  static String _short(Object e) {
    final s = e.toString();
    return s.length > 200 ? '${s.substring(0, 200)}…' : s;
  }
}
