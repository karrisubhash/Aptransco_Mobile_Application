import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../utils/uuid.dart';
import '../auth_store.dart';
import 'local_store.dart';

/// The kinds of change the app can make while offline. Each maps to one backend
/// call in the [SyncEngine].
class OpType {
  static const inspection = 'inspection';
  static const ticketClose = 'ticket_close';
  static const supportCreate = 'support_create';
  static const supportResolve = 'support_resolve';
}

/// One queued change, persisted as a single JSON file in the outbox.
class OutboxOp {
  OutboxOp({
    required this.id,
    required this.seq,
    required this.type,
    required this.payload,
    this.media = const {},
    required this.createdAt,
    this.owner,
    this.attempts = 0,
    this.lastError,
    this.failed = false,
  });

  /// Unique id (also the inspection's idempotency `client_id` when applicable).
  final String id;

  /// Monotonic sequence for FIFO ordering.
  final int seq;

  /// One of [OpType].
  final String type;

  /// The JSON body to send.
  final Map<String, dynamic> payload;

  /// For inspections: multipart photo key -> staged file path on disk.
  final Map<String, String> media;

  final int createdAt;

  /// Employee id of whoever queued this change, stamped at [OutboxStore.enqueue]
  /// time. Null only for ops written by a build from before this field existed.
  final String? owner;

  /// The best available owner: the stamp, else the employee id the payload
  /// already carries for its op type.
  ///
  /// The fallback is what stops an in-place upgrade from stranding queued work:
  /// every op `OfflineActions` writes names its author in the payload
  /// (`inspector_employee_id` / `closed_by` / `raised_by` / `resolved_by`), so a
  /// change queued by the previous build still resolves to the right person.
  String? get ownerId {
    final stamped = owner;
    if (stamped != null && stamped.isNotEmpty) return stamped;
    for (final k in const [
      'inspector_employee_id',
      'closed_by',
      'raised_by',
      'resolved_by',
    ]) {
      final v = payload[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  /// How many sync attempts have been made. Used for backoff and to give up on
  /// a "poison" op the server keeps rejecting.
  int attempts;

  /// Human-readable last failure, shown in the sync details sheet.
  String? lastError;

  /// True once the op has exhausted its attempts against a server that keeps
  /// rejecting it — it is kept for visibility but no longer retried.
  bool failed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'seq': seq,
        'type': type,
        'payload': payload,
        'media': media,
        'createdAt': createdAt,
        'owner': owner,
        'attempts': attempts,
        'lastError': lastError,
        'failed': failed,
      };

  factory OutboxOp.fromJson(Map<String, dynamic> j) => OutboxOp(
        id: j['id'] as String,
        seq: j['seq'] as int? ?? 0,
        type: j['type'] as String,
        payload: (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        media: (j['media'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ??
            const {},
        createdAt: j['createdAt'] as int? ?? 0,
        owner: j['owner'] as String?,
        attempts: j['attempts'] as int? ?? 0,
        lastError: j['lastError'] as String?,
        failed: j['failed'] as bool? ?? false,
      );

  /// A short label for the sync UI.
  String get label {
    switch (type) {
      case OpType.inspection:
        return 'Inspection · Tower ${payload['tower_number'] ?? payload['tower_id'] ?? ''}';
      case OpType.ticketClose:
        return 'Close ticket #${payload['ticket_id'] ?? ''}';
      case OpType.supportCreate:
        return 'Support: ${payload['subject'] ?? ''}';
      case OpType.supportResolve:
        return 'Resolve request #${payload['support_id'] ?? ''}';
      default:
        return type;
    }
  }
}

/// The durable queue of offline changes. Each op is its own file so a crash
/// mid-write can damage at most one op, never the whole queue, and files sort
/// lexically into FIFO order.
///
/// The queue is the one thing a sign-out must **not** throw away, so instead
/// every op knows whose it is and [list] hands out only the signed-in
/// employee's. Without that, an inspection queued offline by one engineer would
/// be drained under the next employee's token — and the server credits the
/// inspection to the token holder ([`_create_inspection(request.user.employee_id,
/// …)`]), so one person's fieldwork would be recorded against another. Whatever
/// does not belong to this session simply waits, untouched and un-retried, until
/// its author signs back in.
class OutboxStore {
  OutboxStore._();
  static final OutboxStore instance = OutboxStore._();

  int _nextSeq = 0;

  Directory get _dir => LocalStore.instance.outboxDir;

  /// Seed the sequence counter from any ops left over from a previous run.
  ///
  /// Scans every file, not just the signed-in employee's: sequences are the
  /// FIFO order of the whole directory, and skipping another employee's ops here
  /// would hand out seqs that are already on disk and overwrite their work.
  Future<void> init() async {
    var maxSeq = -1;
    try {
      await for (final e in _dir.list()) {
        if (e is File && e.path.endsWith('.json')) {
          final op = await _read(e);
          if (op != null && op.seq > maxSeq) maxSeq = op.seq;
        }
      }
    } catch (_) {}
    _nextSeq = maxSeq + 1;
  }

  File _fileFor(OutboxOp op) => File(
      p.join(_dir.path, '${op.seq.toString().padLeft(12, '0')}_${op.id}.json'));

  Future<OutboxOp?> _read(File f) async {
    try {
      return OutboxOp.fromJson(
          jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(OutboxOp op) async {
    final dest = _fileFor(op);
    final tmp = File('${dest.path}.tmp');
    await tmp.writeAsString(jsonEncode(op.toJson()), flush: true);
    await tmp.rename(dest.path);
  }

  /// Add a change to the queue. Pass an explicit [id] for inspections so it
  /// doubles as the idempotency key across retries; otherwise one is generated.
  Future<OutboxOp> enqueue(
    String type,
    Map<String, dynamic> payload, {
    Map<String, String> media = const {},
    String? id,
  }) async {
    final op = OutboxOp(
      id: id ?? generateUuidV4(),
      seq: _nextSeq++,
      type: type,
      payload: payload,
      media: media,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      owner: AuthStore.instance.session?.employeeId,
    );
    await _write(op);
    return op;
  }

  /// The signed-in employee's queued ops, in FIFO order.
  ///
  /// This is the default because everything downstream — the drain, the pending
  /// badge, the "waiting to sync" rings on the map — should only ever be about
  /// the person holding the phone. Filtering here rather than at each caller
  /// means a new caller is safe by default instead of by remembering.
  Future<List<OutboxOp>> list() async =>
      (await listAll()).where(_isMine).toList();

  /// Every queued op regardless of owner. For diagnostics and storage readouts;
  /// use [list] for anything that syncs or is shown as this user's work.
  Future<List<OutboxOp>> listAll() async {
    final ops = <OutboxOp>[];
    try {
      await for (final e in _dir.list()) {
        if (e is File && e.path.endsWith('.json')) {
          final op = await _read(e);
          if (op != null) ops.add(op);
        }
      }
    } catch (_) {}
    ops.sort((a, b) => a.seq.compareTo(b.seq));
    return ops;
  }

  /// Whether [op] belongs to the employee signed in right now.
  ///
  /// An op with no recoverable owner at all is treated as this session's. That
  /// is a deliberate trade: `OfflineActions` always names its author, so the
  /// only way to get here is a hand-built op, and stranding a real inspection
  /// forever is worse than the residual risk on a device where nobody was
  /// identifiable in the first place.
  bool _isMine(OutboxOp op) {
    final owner = op.ownerId;
    if (owner == null) return true;
    return owner == AuthStore.instance.session?.employeeId;
  }

  Future<void> update(OutboxOp op) => _write(op);

  /// Remove a synced op and its staged photos.
  Future<void> remove(OutboxOp op) async {
    final f = _fileFor(op);
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    for (final path in op.media.values) {
      await LocalStore.instance.deleteMedia(path);
    }
  }

  Future<int> count() async => (await list()).length;

  /// Count of ops still waiting (not permanently failed).
  Future<int> pendingCount() async =>
      (await list()).where((o) => !o.failed).length;
}
