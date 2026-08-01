import 'package:flutter/material.dart';
import '../../models/li_session.dart';
import '../../models/li_records.dart';
import '../../services/line_inspection_api.dart';
import '../../services/offline/offline_actions.dart';
import '../../services/offline/sync_engine.dart';
import '../../utils/li_style.dart';

/// Support tab: raise a request to the admin (data correction, questionnaire
/// change, ticket dispute, other) and browse existing requests. HQ users can
/// resolve open requests.
class SupportTab extends StatefulWidget {
  const SupportTab({super.key, required this.session});
  final LiSession session;

  @override
  State<SupportTab> createState() => _SupportTabState();
}

class _SupportTabState extends State<SupportTab>
    with AutomaticKeepAliveClientMixin {
  // Kept alive while another tab is on screen, so a half-typed request survives
  // a glance at the map and coming back costs no reload.
  @override
  bool get wantKeepAlive => true;

  static const _categories = <String>[
    'Tower / line data correction',
    'Questionnaire change request',
    'Defect ticket dispute',
    'Other',
  ];

  final _subjectCtrl = TextEditingController();
  final _textCtrl = TextEditingController();
  String _category = _categories.first;
  bool _sending = false;

  bool _loading = true;
  String? _error;
  List<SupportRequest> _requests = const [];

  @override
  void initState() {
    super.initState();
    _load();
    SyncEngine.instance.dataRevision.addListener(_onSynced);
  }

  @override
  void dispose() {
    SyncEngine.instance.dataRevision.removeListener(_onSynced);
    _subjectCtrl.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  /// A sync landed, so a queued request/resolution is now the server's — go past
  /// the read layer's freshness window for it.
  void _onSynced() {
    if (mounted) _load(force: true);
  }

  /// Guards against an older load landing last.
  int _loadGen = 0;

  /// Cache-first: the requests already on the device are shown at once and the
  /// server's copy replaces them when it lands.
  Future<void> _load({bool force = false}) async {
    final gen = ++_loadGen;
    try {
      final read = await LineInspectionApi.readSupportRequests(
          subdivision: widget.session.scopeSubdivisionId, force: force);
      if (gen != _loadGen || !mounted) return;
      final cached = read.cached;
      if (cached != null) {
        _show(cached);
      } else if (_requests.isEmpty) {
        setState(() {
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
        _error = _requests.isEmpty ? e.toString() : null;
      });
    }
  }

  void _show(List<SupportRequest> list) {
    setState(() {
      _requests = list;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _submit() async {
    final subject = _subjectCtrl.text.trim();
    final text = _textCtrl.text.trim();
    if (subject.isEmpty || text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a subject and description.')),
      );
      return;
    }
    setState(() => _sending = true);
    try {
      final r = await OfflineActions.createSupport(
        raisedBy: widget.session.employeeId,
        category: _category,
        subject: subject,
        text: text,
        subdivisionId: widget.session.subdivisionId,
        subdivisionName: widget.session.subdivisionName ?? '',
        scopeSubdivisionId: widget.session.scopeSubdivisionId,
      );
      if (!mounted) return;
      _subjectCtrl.clear();
      _textCtrl.clear();
      setState(() {
        _category = _categories.first;
        _sending = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(r.queued
                ? 'Saved offline — will send to admin when online.'
                : 'Request sent to admin.')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send: $e')),
      );
    }
  }

  Future<void> _resolve(SupportRequest req) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ResolveNoteDialog(subject: req.subject),
    );
    if (note == null) return; // cancelled
    if (note.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a response before resolving.')),
      );
      return;
    }
    try {
      final r = await OfflineActions.resolveSupport(
        supportId: req.id,
        resolvedBy: widget.session.employeeId,
        response: note,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(r.queued
                ? 'Resolved offline — will sync when online.'
                : 'Request resolved.')),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not resolve: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // required by AutomaticKeepAliveClientMixin
    return RefreshIndicator(
      // An explicit pull asks for the server's copy, not the cached one.
      onRefresh: () => _load(force: true),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildForm(),
            const SizedBox(height: 20),
            liSectionHeader(Icons.inbox_outlined, 'Requests'),
            const SizedBox(height: 10),
            _buildRequests(),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            liSectionHeader(Icons.edit_note_outlined, 'Raise a request'),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              initialValue: _category,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Category',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final c in _categories)
                  DropdownMenuItem(value: c, child: Text(c)),
              ],
              onChanged: _sending
                  ? null
                  : (v) => setState(() => _category = v ?? _categories.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _subjectCtrl,
              enabled: !_sending,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Subject',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _textCtrl,
              enabled: !_sending,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _sending ? null : _submit,
              icon: _sending
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(_sending ? 'Sending…' : 'Send to admin'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRequests() {
    if (_loading) {
      return liLoading(message: 'Loading requests…');
    }
    if (_error != null) {
      return liErrorState(_error!,
          title: 'Could not load requests', onRetry: _load);
    }
    if (_requests.isEmpty) {
      return liEmptyState(
        Icons.inbox_outlined,
        'Nothing yet',
        subtitle: 'Requests you raise to the admin will show up here.',
      );
    }
    return Column(
      children: [
        for (final r in _requests) _requestCard(r),
      ],
    );
  }

  Widget _requestCard(SupportRequest r) {
    const dim = TextStyle(fontSize: 12, color: kInkFaint);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(r.subject,
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(width: 8),
                statusPill(r.status),
              ],
            ),
            const SizedBox(height: 2),
            Text(r.category, style: dim),
            if (r.text.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(r.text),
            ],
            if (r.response.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kBlue100.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: kBlue.withValues(alpha: 0.3)),
                ),
                child: Text('Admin: ${r.response}',
                    style: const TextStyle(color: kBlue600)),
              ),
            ],
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: Text(r.createdAt, style: dim)),
                Text('by ${r.raisedBy}', style: dim),
              ],
            ),
            if (widget.session.isManagementOrAdmin && r.isOpen) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonalIcon(
                  onPressed: () => _resolve(r),
                  icon: const Icon(Icons.check_circle_outline, size: 18),
                  label: const Text('Resolve'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The admin's reply when resolving a support request.
///
/// A widget rather than an inline `AlertDialog` so the response's controller is
/// disposed with the route: disposing it the moment `showDialog` resolved crashed
/// the app on Cancel, because the route is still mounted for its exit
/// transition — the same fault the presence-override dialog had.
class _ResolveNoteDialog extends StatefulWidget {
  const _ResolveNoteDialog({required this.subject});

  final String subject;

  @override
  State<_ResolveNoteDialog> createState() => _ResolveNoteDialogState();
}

class _ResolveNoteDialogState extends State<_ResolveNoteDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Resolve: ${widget.subject}'),
      content: TextField(
        controller: _ctl,
        autofocus: true,
        maxLines: 4,
        decoration: const InputDecoration(
          labelText: 'Response to requester',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctl.text.trim()),
          child: const Text('Resolve'),
        ),
      ],
    );
  }
}
