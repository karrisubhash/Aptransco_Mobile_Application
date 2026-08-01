import 'package:flutter/material.dart';

import '../services/auth_store.dart';
import '../services/offline/connectivity_service.dart';
import '../services/offline/outbox.dart';
import '../services/offline/sync_engine.dart';
import '../utils/li_style.dart';

/// A slim status strip that tells the inspector, at a glance, whether they're
/// offline and how many changes are still waiting to upload. Tapping it opens a
/// details sheet with a manual "Sync now" and the queued items. It hides itself
/// entirely when online and fully synced, so it's invisible in the normal case.
class SyncStatusBar extends StatelessWidget {
  const SyncStatusBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.online,
      builder: (context, isOnline, _) => ValueListenableBuilder<bool>(
        // An expired token is the third input to the banner: without it a
        // refused session showed up as an ordinary "N changes to upload" that
        // never went down.
        valueListenable: AuthStore.instance.sessionExpired,
        builder: (context, expired, _) => ValueListenableBuilder<SyncStatus>(
          valueListenable: SyncEngine.instance.status,
          builder: (context, s, _) {
            final v = _view(isOnline, s, expired);
            if (v == null) return const SizedBox.shrink();
            return Material(
              color: v.bg,
              child: InkWell(
                onTap: () => _openDetails(context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: kSpaceLg, vertical: 8),
                  child: Row(
                    children: [
                      if (v.spinner)
                        SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: v.fg),
                        )
                      else
                        Icon(v.icon, size: 16, color: v.fg),
                      const SizedBox(width: kSpaceSm),
                      Expanded(
                        child: Text(v.text,
                            style: TextStyle(
                                fontSize: 12.5,
                                color: v.fg,
                                fontWeight: FontWeight.w600)),
                      ),
                      if (v.action != null) ...[
                        Text(v.action!,
                            style: TextStyle(
                                fontSize: 12,
                                color: v.fg,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(width: 2),
                        Icon(Icons.chevron_right, size: 16, color: v.fg),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  _BannerView? _view(bool isOnline, SyncStatus s, bool sessionExpired) {
    const amberBg = Color(0xFFFFF4E5), amberFg = Color(0xFF9A5B00);
    const redBg = Color(0xFFFDEDED), redFg = Color(0xFFB3261E);
    if (s.isBusy) {
      return _BannerView(
        bg: kBlue100,
        fg: kBrandPrimary,
        icon: Icons.sync,
        spinner: true,
        text: 'Syncing ${s.pending} change${s.pending == 1 ? '' : 's'}…',
      );
    }
    if (!isOnline) {
      return _BannerView(
        bg: amberBg,
        fg: amberFg,
        icon: Icons.cloud_off_outlined,
        text: s.pending > 0
            ? 'Offline — ${s.pending} change${s.pending == 1 ? '' : 's'} waiting to sync'
            : 'Offline — showing saved data',
        action: s.pending > 0 ? 'Details' : null,
      );
    }
    // Reachable on every long-lived install: mobile tokens last 30 days. Nothing
    // used to say so — reads quietly fell back to cached data and the queue sat
    // still — so the one thing that fixes it (signing in again) was the one thing
    // the inspector had no reason to try. Ranked above the queue states because
    // it is *why* they are stuck.
    if (sessionExpired) {
      return _BannerView(
        bg: redBg,
        fg: redFg,
        icon: Icons.lock_clock,
        text: s.pending > 0
            ? 'Session expired — sign out and back in to upload ${s.pending} '
                'change${s.pending == 1 ? '' : 's'}'
            : 'Session expired — sign out and back in to sync',
      );
    }
    if (s.failed > 0) {
      return _BannerView(
        bg: redBg,
        fg: redFg,
        icon: Icons.error_outline,
        text:
            "${s.failed} change${s.failed == 1 ? '' : 's'} didn't sync${s.pending > 0 ? ' · ${s.pending} pending' : ''}",
        action: 'Retry',
      );
    }
    if (s.pending > 0) {
      return _BannerView(
        bg: kBlue100,
        fg: kBrandPrimary,
        icon: Icons.cloud_upload_outlined,
        text: '${s.pending} change${s.pending == 1 ? '' : 's'} to upload',
        action: 'Sync now',
      );
    }
    return null; // online and everything synced → nothing to show
  }

  void _openDetails(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => const SyncDetailsSheet(),
    );
  }
}

class _BannerView {
  _BannerView({
    required this.bg,
    required this.fg,
    required this.icon,
    required this.text,
    this.spinner = false,
    this.action,
  });
  final Color bg;
  final Color fg;
  final IconData icon;
  final String text;
  final bool spinner;
  final String? action;
}

/// The sheet behind the status strip: the queued changes plus a manual
/// "Sync now".
///
/// Named (rather than private) and injectable purely so a test can drive the
/// post-sync refresh: the real [syncNow] reaches for connectivity, the network
/// and a retry timer, and the real [loadQueue] does file I/O that never
/// completes under a widget test's fake clock. Neither is what this sheet does.
/// Not part of the app's surface — Home reaches it via [SyncStatusBar].
@visibleForTesting
class SyncDetailsSheet extends StatefulWidget {
  const SyncDetailsSheet({
    super.key,
    this.loadQueue,
    this.syncNow,
    this.retryFailed,
    this.discardOp,
  });

  /// Source of the queued changes. Defaults to the real outbox.
  final Future<List<OutboxOp>> Function()? loadQueue;

  /// The drain to run when "Sync now" is tapped. Defaults to the real engine.
  final Future<void> Function()? syncNow;

  /// Un-parks every failed change and drains. Defaults to the real engine.
  final Future<void> Function()? retryFailed;

  /// Removes a permanently-failed change. Defaults to the real engine.
  final Future<void> Function(OutboxOp)? discardOp;

  @override
  State<SyncDetailsSheet> createState() => _SyncDetailsSheetState();
}

class _SyncDetailsSheetState extends State<SyncDetailsSheet> {
  late Future<List<OutboxOp>> _future;

  Future<List<OutboxOp>> _load() =>
      (widget.loadQueue ?? OutboxStore.instance.list)();

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  // Block body, not `=> setState(() => _future = _load())`: an arrow closure
  // returns the assigned value, so that form hands setState a Future and trips
  // its "callback argument returned a Future" assertion.
  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _syncNow() async {
    await (widget.syncNow ?? SyncEngine.instance.syncNow)();
    if (mounted) _reload();
  }

  /// Revives the parked changes and drains. What the banner's "Retry" has always
  /// promised — before [SyncEngine.retryFailed] existed there was no way to
  /// deliver it.
  Future<void> _retryFailed() async {
    await (widget.retryFailed ??
        () async => SyncEngine.instance.retryFailed())();
    if (mounted) _reload();
  }

  /// Discards a parked change, confirming first — this destroys field work that
  /// the server has refused, and it cannot be recovered.
  Future<void> _discard(OutboxOp op) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this change?'),
        content: Text(
          '"${op.label}" was refused by the server and will not be retried. '
          'Discarding removes it from this device for good.',
          style: const TextStyle(fontSize: 13, color: kInkSoft),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB3261E)),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await (widget.discardOp ?? SyncEngine.instance.discard)(op);
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.sync, color: kBrandPrimary),
                const SizedBox(width: kSpaceSm),
                const Expanded(
                  child: Text('Sync',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700)),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: ConnectivityService.instance.online,
                  builder: (_, online, _) => Text(
                    online ? 'Online' : 'Offline',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700,
                        color: online
                            ? kCritColor['ok']
                            : const Color(0xFF9A5B00)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: kSpaceMd),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: FutureBuilder<List<OutboxOp>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final ops = snap.data ?? const [];
                  if (ops.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle,
                              color: kCritColor['ok'], size: 20),
                          const SizedBox(width: kSpaceSm),
                          const Text('All changes are synced.'),
                        ],
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: ops.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => _opTile(ops[i]),
                  );
                },
              ),
            ),
            const SizedBox(height: kSpaceMd),
            // Driven by the queue actually on screen rather than the global
            // status, so the button always matches the rows above it.
            FutureBuilder<List<OutboxOp>>(
              future: _future,
              builder: (context, snap) {
                final hasParked =
                    (snap.data ?? const []).any((o) => o.failed);
                return ValueListenableBuilder<SyncStatus>(
                  valueListenable: SyncEngine.instance.status,
                  builder: (_, s, _) => FilledButton.icon(
                    onPressed:
                        s.isBusy ? null : (hasParked ? _retryFailed : _syncNow),
                    icon: s.isBusy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.sync),
                    label: Text(s.isBusy
                        ? 'Syncing…'
                        : hasParked
                            ? 'Retry failed changes'
                            : 'Sync now'),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _opTile(OutboxOp op) {
    final failed = op.failed;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        failed ? Icons.error_outline : Icons.cloud_upload_outlined,
        color: failed ? const Color(0xFFB3261E) : kBrandPrimary,
      ),
      title: Text(op.label, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        failed
            ? "Couldn't sync${op.lastError != null ? ' · ${op.lastError}' : ''}"
            : op.attempts > 0
                ? 'Waiting to retry (${op.attempts})'
                : 'Waiting to upload',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 12,
            color: failed ? const Color(0xFFB3261E) : kInkFaint),
      ),
      // Only parked ops get this: anything still pending will retry on its own,
      // and offering to delete it invites throwing away work that would sync.
      trailing: failed
          ? IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              color: kInkFaint,
              tooltip: 'Discard',
              onPressed: () => _discard(op),
            )
          : null,
    );
  }
}
