import 'package:flutter/material.dart';
import '../../models/li_export.dart';
import '../../models/li_session.dart';
import '../../models/li_records.dart';
import '../../services/li_export.dart';
import '../../services/line_inspection_api.dart';
import '../../services/offline/offline_actions.dart';
import '../../services/offline/sync_engine.dart';
import '../../utils/li_format.dart';
import '../../utils/li_style.dart';
import '../../widgets/li_export_button.dart';

/// Available status filters: label + the value passed to the API
/// (null = every ticket regardless of status).
const List<(String?, String)> _statusFilters = [
  ('open', 'Open'),
  ('closed', 'Closed'),
  (null, 'All'),
];

/// Tickets in the order a backlog is actually worked: worst severity first, and
/// newest first within a severity.
///
/// The server orders by `-raised_at` alone, which buries a critical defect under
/// any number of more recent minor ones — on a phone that means scrolling to find
/// the thing that matters. Pure and top-level so the ordering can be tested
/// without building the tab.
List<TicketRecord> ticketsForTriage(List<TicketRecord> tickets) {
  return [...tickets]..sort((a, b) {
    final bySeverity = (kCritOrder[b.criticality] ?? 0)
        .compareTo(kCritOrder[a.criticality] ?? 0);
    if (bySeverity != 0) return bySeverity;
    return b.raisedAt.compareTo(a.raisedAt); // ISO-8601 sorts as time
  });
}

/// Defect-tickets tab: filter by open/closed/all, review each raised defect,
/// and close open tickets with a closure note.
///
/// Scope is the server's, and it follows the reporting hierarchy: `GET /tickets/`
/// is built on `viewing.oversight_towers`, so an AEE sees defects on their own
/// towers and a DEE/EE/SE sees every tower assigned to anyone beneath them.
/// Everyone sees the defects at their level — the tab does not narrow that
/// further. Each card names its raiser so a supervisor can tell their own
/// inspections from their team's.
class TicketsTab extends StatefulWidget {
  const TicketsTab({super.key, required this.session});
  final LiSession session;

  @override
  State<TicketsTab> createState() => _TicketsTabState();
}

class _TicketsTabState extends State<TicketsTab>
    with AutomaticKeepAliveClientMixin {
  // Kept alive while another tab is on screen, so coming back shows the backlog
  // the engineer was reading — at the same scroll position — instead of
  // rebuilding the tab from scratch and loading it again.
  @override
  bool get wantKeepAlive => true;

  String? _statusFilter = 'open';
  bool _loading = true;
  String? _error;
  List<TicketRecord> _tickets = const [];

  @override
  void initState() {
    super.initState();
    _load();
    // Refresh when a queued change (e.g. an offline ticket close) syncs, so the
    // list reflects the now-authoritative server state.
    SyncEngine.instance.dataRevision.addListener(_onSynced);
  }

  @override
  void dispose() {
    SyncEngine.instance.dataRevision.removeListener(_onSynced);
    super.dispose();
  }

  /// A sync landed, so the server holds the authoritative version of whatever was
  /// queued — go past the read layer's freshness window for it.
  void _onSynced() {
    if (mounted) _load(force: true);
  }

  /// Guards against an older load (or a previous filter's) landing last.
  int _loadGen = 0;

  /// Loads the backlog, cache-first: whatever is already on the device is shown
  /// straight away and the server's copy replaces it when it lands. Only a filter
  /// with nothing cached still shows a spinner.
  ///
  /// [force] ignores the read layer's freshness window (pull-to-refresh, and
  /// after a sync). [switching] means the status filter just changed, so the
  /// tickets on screen belong to the old one and must not be left standing.
  Future<void> _load({bool force = false, bool switching = false}) async {
    final gen = ++_loadGen;
    final status = _statusFilter;
    try {
      final read = await LineInspectionApi.readTickets(
        status: status,
        subdivision: widget.session.scopeSubdivisionId,
        force: force,
      );
      if (gen != _loadGen || !mounted) return;
      final cached = read.cached;
      if (cached != null) {
        _show(cached);
      } else if (switching || _tickets.isEmpty) {
        setState(() {
          _tickets = const [];
          _loading = true;
          _error = null;
        });
      }
      final fresh = await read.fresh;
      if (gen != _loadGen || !mounted) return;
      if (fresh != null) _show(fresh);
      if (_loading) setState(() => _loading = false);
    } catch (e) {
      if (gen != _loadGen || !mounted) return;
      setState(() {
        _loading = false;
        // A failed refresh must not throw away a backlog that is already
        // readable — it stays usable offline. Only speak up with nothing to show.
        _error = _tickets.isEmpty ? e.toString() : null;
      });
    }
  }

  /// Everything the server returned, unfiltered. `GET /tickets/` is already
  /// scoped by level — `viewing.oversight_towers` is the reporting-hierarchy
  /// widened scope, so a leaf AEE gets their own towers and a DEE/EE/SE gets
  /// every tower assigned to anyone beneath them.
  ///
  /// This used to narrow further, client-side, to tickets whose
  /// `raised_by_employee_id` matched the signed-in user. That hid a supervisor's
  /// whole jurisdiction from them: tickets are stamped with whoever *submitted
  /// the inspection*, and supervisors do not capture inspections — their
  /// subordinates do. So the tab was permanently empty for every DEE, EE, SE and
  /// admin, while Home's KPI strip counted the same tickets and showed a non-zero
  /// "Open". Defects are visible to everyone at their own level; nothing is
  /// hidden.
  void _show(List<TicketRecord> tickets) {
    setState(() {
      _tickets = ticketsForTriage(tickets);
      _loading = false;
      _error = null;
    });
  }

  void _selectFilter(String? value) {
    if (_statusFilter == value) return;
    setState(() => _statusFilter = value);
    _load(switching: true);
  }

  Future<void> _closeTicket(TicketRecord t) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ClosureNoteDialog(ticket: t),
    );
    if (note == null) return; // cancelled
    final finalNote = note.isEmpty ? 'Attended and rectified' : note;
    try {
      final r = await OfflineActions.closeTicket(
        ticketId: t.id,
        closedBy: widget.session.employeeId,
        note: finalNote,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(r.queued
                ? 'Ticket closed offline — will sync when online'
                : 'Ticket closed')),
      );
      // A close that committed online has changed the server's answer; a queued
      // one has already been patched into the cache, so this reads it back.
      await _load(force: !r.queued);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to close ticket: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    return Column(
      children: [
        _buildFilterRow(),
        Expanded(child: _buildBody()),
      ],
    );
  }

  /// Downloads the backlog the tab is currently showing — the same status and
  /// subdivision filters go to the export endpoint, so the file matches the
  /// screen rather than being a second, wider answer.
  Future<ExportedReport> _export(ExportFormat format) => LiExport.shareTickets(
        format: format,
        status: _statusFilter,
        subdivision: widget.session.scopeSubdivisionId,
      );

  Widget _buildFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          // The chips scroll rather than overflow. Three of them beside a
          // labelled Download button is wider than a small phone once the
          // system font scale is turned up, and the button must stay reachable.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final f in _statusFilters)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(f.$2),
                        selected: _statusFilter == f.$1,
                        onSelected: (_) => _selectFilter(f.$1),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Sits at the end of the filter row rather than in the shell's app
          // bar: the app bar is shared by all four tabs, and this exports what
          // the filters to its left have selected.
          LiExportButton(
            title: 'defect tickets',
            rowCount: _tickets.isEmpty ? null : _tickets.length,
            runner: _export,
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return liLoading(message: 'Loading tickets…');
    }
    if (_error != null) {
      return liErrorState(_error!,
          title: 'Could not load tickets', onRetry: () => _load(force: true));
    }
    return RefreshIndicator(
      // An explicit pull is a request for the server's copy, not the cached one.
      onRefresh: () => _load(force: true),
      child: _tickets.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 80),
                liEmptyState(
                  Icons.confirmation_number_outlined,
                  _statusFilter == 'open'
                      ? 'No open tickets'
                      : _statusFilter == 'closed'
                          ? 'No closed tickets'
                          : 'No tickets yet',
                  subtitle: 'Defects raised on any tower in your jurisdiction '
                      'appear here — yours and those of anyone reporting to you.',
                ),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
              itemCount: _tickets.length,
              itemBuilder: (context, i) => _ticketCard(_tickets[i]),
            ),
    );
  }

  Widget _ticketCard(TicketRecord t) {
    const dim = TextStyle(fontSize: 12, color: kInkFaint);
    final answers = answersText(t.answers);
    final positionSuffix = t.position.isNotEmpty ? ' (${t.position})' : '';
    final age = t.isOpen ? liAgeLabel(t.raisedAt) : '';
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    t.lineName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(width: 8),
                Text('T-${t.towerNumber}', style: dim),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${t.itemLabel}$positionSuffix',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(t.defectLabel),
            if (answers.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(answers, style: dim),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                critChip(t.criticality),
                statusPill(t.status),
                // Was the raw ISO timestamp the API sends
                // ('2026-07-12T08:31:22.123Z'), unreadable at a glance.
                Text(liDayLabel(t.raisedAt), style: dim),
                // How long it has been outstanding — the difference between a
                // list and a backlog. Only meaningful while open.
                if (age.isNotEmpty) Text('$age open', style: dim),
                // Who recorded it. A supervisor sees their subordinates' tickets
                // alongside their own, so the raiser has to be on the card for
                // the list to be readable. Drone-sourced tickets carry no raiser.
                if (t.raisedBy.isNotEmpty)
                  Text(
                    t.raisedBy == widget.session.employeeId
                        ? 'by you'
                        : 'by ${t.raisedBy}',
                    style: dim,
                  ),
              ],
            ),
            if (!t.isOpen) _closureLine(t),
            if (t.isOpen) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  onPressed: () => _closeTicket(t),
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('Close'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The sign-off on a closed ticket: who cleared it, when, and what they wrote.
  /// Without it a closed ticket was indistinguishable from an open one apart from
  /// its status pill, even though the API had always sent all three.
  Widget _closureLine(TicketRecord t) {
    final who = t.closedBy.isEmpty
        ? ''
        : t.closedBy == widget.session.employeeId
            ? 'you'
            : t.closedBy;
    final when = t.closedAt.isEmpty ? '' : liDayLabel(t.closedAt);
    final parts = [
      if (who.isNotEmpty) 'by $who',
      if (when.isNotEmpty) when,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            parts.isEmpty ? 'Attended' : 'Attended $parts',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: kCritColor['ok'],
            ),
          ),
          if (t.closeNote.isNotEmpty)
            Text(t.closeNote,
                style: const TextStyle(fontSize: 12, color: kInkFaint)),
        ],
      ),
    );
  }
}

/// Sign-off note for closing a ticket, prefilled with the usual wording.
///
/// A widget rather than an inline `AlertDialog` so the note's controller is
/// disposed with the route: disposing it the moment `showDialog` resolved crashed
/// the app on Cancel, because the route is still mounted for its exit
/// transition — the same fault the presence-override dialog had.
class _ClosureNoteDialog extends StatefulWidget {
  const _ClosureNoteDialog({required this.ticket});

  final TicketRecord ticket;

  @override
  State<_ClosureNoteDialog> createState() => _ClosureNoteDialogState();
}

class _ClosureNoteDialogState extends State<_ClosureNoteDialog> {
  final _ctl = TextEditingController(text: 'Attended and rectified');

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.ticket;
    return AlertDialog(
      title: const Text('Close ticket'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Name what is being signed off: the dialog alone gave no
          // confirmation of which row was tapped.
          Text(
            '${t.defectLabel.isEmpty ? t.itemLabel : t.defectLabel}'
            ' · T-${t.towerNumber}',
            style: const TextStyle(fontSize: 13, color: kInkSoft),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _ctl,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Closure note',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, _ctl.text.trim()),
          child: const Text('Close ticket'),
        ),
      ],
    );
  }
}
