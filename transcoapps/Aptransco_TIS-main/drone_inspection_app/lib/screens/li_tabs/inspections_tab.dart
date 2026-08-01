import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../../models/li_export.dart';
import '../../models/li_session.dart';
import '../../models/li_records.dart';
import '../../services/li_export.dart';
import '../../services/line_inspection_api.dart';
import '../../services/offline/cache_warmer.dart';
import '../../services/offline/sync_engine.dart';
import '../../utils/li_style.dart';
import '../../widgets/li_export_button.dart';
import '../../widgets/li_photo_thumbnail.dart';

/// One day's worth of history: the inspection date and the rows done on it.
@visibleForTesting
class HistoryDay {
  const HistoryDay(this.date, this.rows);
  final String date;
  final List<InspectionSummary> rows;
}

/// Splits a history list into day groups, newest day first.
///
/// Within a day, rows keep the order they arrived in — the server sorts by save
/// time, so the most recently saved inspection of a day stays on top. Grouping
/// on the inspection date rather than trusting arrival order matters because an
/// inspection can be saved days after the visit: ordered by save time its row
/// would land among a different day's, splitting that day's group in two.
@visibleForTesting
List<HistoryDay> groupHistoryByDay(List<InspectionSummary> rows) {
  final indexed = [for (var i = 0; i < rows.length; i++) (i, rows[i])]
    ..sort((a, b) {
      final byDate = b.$2.date.compareTo(a.$2.date); // ISO dates sort as dates
      return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
    });
  final out = <HistoryDay>[];
  for (final (_, s) in indexed) {
    if (out.isEmpty || out.last.date != s.date) {
      out.add(HistoryDay(s.date, [s]));
    } else {
      out.last.rows.add(s);
    }
  }
  return out;
}

/// '3 defects' / '1 defect' / 'No defects' — full words, not `n defect(s)`.
@visibleForTesting
String defectsLabel(int n) => switch (n) {
  0 => 'No defects',
  1 => '1 defect',
  _ => '$n defects',
};

/// What the download sheet has to say when [pending] inspections are still in
/// the outbox — null when there is nothing to warn about.
///
/// A report is rendered by the server, so an inspection that has not synced yet
/// cannot be in it. Left unsaid, a download taken at the end of a day with no
/// signal would read as a complete record of that day's work.
@visibleForTesting
String? pendingCaveat(int pending) {
  if (pending <= 0) return null;
  final subject = pending == 1 ? '1 inspection' : '$pending inspections';
  final verb = pending == 1 ? 'has' : 'have';
  return '$subject on this device $verb not synced yet, so the report '
      'will not include ${pending == 1 ? 'it' : 'them'}.';
}

/// The coverage meter's three parts, reconciled so they always sum to [total].
@visibleForTesting
class CoverageSplit {
  const CoverageSplit({
    required this.total,
    required this.inspected,
    required this.mine,
  });

  /// Towers at this user's level, from the shared dashboard rollup.
  final int total;

  /// Of those, how many anyone has inspected — the figure Home also prints.
  final int inspected;

  /// Of those inspected, how many this user captured.
  final int mine;

  int get others => inspected - mine;
  int get rest => total - inspected;
}

/// Reconciles the two sources behind the coverage meter.
///
/// [inspectedAtLevel] is the server's rollup (towers with any inspection);
/// [myTowers] is counted from the history rows this user captured. They can
/// legitimately disagree — an inspection still in the outbox is in the user's
/// rows but not yet in the server's rollup — so `mine` is capped at
/// `inspected`: otherwise the "by you" segment would be drawn longer than the
/// inspected segment that contains it, and the parts would not sum to [total].
@visibleForTesting
CoverageSplit coverageSplit({
  required int total,
  required int inspectedAtLevel,
  required int myTowers,
}) {
  final t = total < 0 ? 0 : total;
  final inspected = inspectedAtLevel.clamp(0, t);
  return CoverageSplit(
    total: t,
    inspected: inspected,
    mine: myTowers.clamp(0, inspected),
  );
}

const _kMonths = [
  'JAN',
  'FEB',
  'MAR',
  'APR',
  'MAY',
  'JUN',
  'JUL',
  'AUG',
  'SEP',
  'OCT',
  'NOV',
  'DEC',
];

/// 'TODAY' / 'YESTERDAY' / '24 JUL 2026' for a `yyyy-MM-dd` inspection date.
/// [now] is injectable so the relative labels are testable.
@visibleForTesting
String historyDayLabel(String iso, {required DateTime now}) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso.isEmpty ? 'UNDATED' : iso.toUpperCase();
  final days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days == 0) return 'TODAY';
  if (days == 1) return 'YESTERDAY';
  return '${d.day} ${_kMonths[d.month - 1]} ${d.year}';
}

/// Renders one inspection photo reference: a `local://<path>` points at a photo
/// staged for a not-yet-synced inspection (shown from disk); anything else is a
/// server media path.
Widget _liThumb(String ref, {double size = 120}) {
  if (ref.startsWith('local://')) {
    return LiPhotoThumbnail.file(File(ref.substring(8)), size: size);
  }
  return LiPhotoThumbnail.network(LineInspectionApi.mediaUrl(ref), size: size);
}

/// History tab: every inspection saved at this user's level, newest first,
/// grouped by the day it was done. Tapping a row opens the full inspection.
///
/// One flat list across every line their level covers, with no line picker and
/// no search: `GET /line-inspections/list/` is already scoped to the user's
/// oversight, so the response *is* the list to show.
///
/// **Scope, and why it is the level rather than the employee.** The list is not
/// narrowed to `inspector_employee_id == me`. That field records who *captured*
/// an inspection, and supervisors do not capture — their subordinates do — so
/// filtering on it emptied the tab for every DEE, EE and SE while Home's KPI
/// strip counted the very same inspections, and the two tabs disagreed. The
/// Tickets tab was fixed the same way, for the same reason. The card's coverage
/// figures always describe the whole level and come from the same dashboard
/// rollup Home prints, so the two screens cannot quote different numbers; each
/// row also names who captured it (see [InspectionHistoryTile]) when that was
/// not the signed-in user.
///
/// Towers still awaiting an inspection are *not* shown here. That is forward
/// work, not history, and Home already owns it: the map ranks the nearest towers
/// from the live GPS fix and a tap opens the form through the presence gate.
class InspectionsTab extends StatefulWidget {
  const InspectionsTab({super.key, required this.session});
  final LiSession session;

  @override
  State<InspectionsTab> createState() => _InspectionsTabState();
}

class _InspectionsTabState extends State<InspectionsTab>
    with AutomaticKeepAliveClientMixin {
  // Kept alive while another tab is on screen: coming back to History returns to
  // the same list at the same scroll position, with no reload.
  @override
  bool get wantKeepAlive => true;

  /// Every inspection at this user's level, in the order the server (or cache)
  /// returned them.
  List<InspectionSummary> _history = const [];

  /// The same KPI rollup Home's strip prints, read through the same cache-first
  /// call — so the two tabs cannot quote different jurisdiction figures. Null
  /// until it has loaded once, and the coverage block is then omitted rather
  /// than shown against a made-up total.
  DashboardData? _coverage;

  bool _loading = true;
  String? _error;

  /// Guards against a stale reload landing after a newer one.
  int _token = 0;

  String get _employeeId => widget.session.employeeId;

  /// Whether this row was captured by the signed-in user.
  ///
  /// Compared case- and whitespace-insensitively: the id travels from SAP
  /// through login into `inspector_employee_id`, and a stray difference in case
  /// or padding must not make a user's own work look like someone else's.
  bool _isMine(InspectionSummary s) =>
      s.inspector.trim().toLowerCase() == _employeeId.trim().toLowerCase();

  @override
  void initState() {
    super.initState();
    // Reload when a queued inspection syncs, so its row switches from the
    // optimistic (pending) copy to the authoritative server record.
    SyncEngine.instance.dataRevision.addListener(_onSynced);
    _load();
  }

  /// A sync landed, so the queued row has become an authoritative one — go past
  /// the read layer's freshness window and pick up the server's version.
  void _onSynced() {
    if (mounted) _load(force: true);
  }

  @override
  void dispose() {
    SyncEngine.instance.dataRevision.removeListener(_onSynced);
    super.dispose();
  }

  // ---- Data ---------------------------------------------------------------

  /// Loads the history cache-first: the copy already on the device is shown
  /// immediately, and the server's replaces it when it lands. The spinner is only
  /// for a first run with nothing saved yet.
  ///
  /// The history and the coverage total leave together and land independently, so
  /// neither waits on the other — and a failed rollup costs only the meter.
  Future<void> _load({bool force = false}) async {
    final token = ++_token;
    // Deliberately *not* narrowed to this employee id. `inspector_employee_id`
    // records who captured an inspection, and supervisors do not capture — their
    // subordinates do — so asking for `?inspector=<me>` left a DEE/EE/SE looking
    // at an empty History while Home's strip counted the very same inspections.
    // The Tickets tab was fixed the same way (see `tickets_tab.dart`). The list
    // is still scoped: the backend returns only this user's oversight.
    final historyRead = LineInspectionApi.readInspections(force: force);
    final coverageRead = LineInspectionApi.readDashboard(force: force);
    unawaited(_applyCoverage(coverageRead, token));
    try {
      final read = await historyRead;
      if (!mounted || token != _token) return;
      final cached = read.cached;
      if (cached != null) {
        _showHistory(cached);
      } else if (_history.isEmpty) {
        setState(() {
          _loading = true;
          _error = null;
        });
      }
      final fresh = await read.fresh;
      if (!mounted || token != _token) return;
      if (fresh != null) _showHistory(fresh);
      if (_loading) setState(() => _loading = false);
    } catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _loading = false;
        // Keep a history that is already on screen — it reads fine offline.
        _error = _history.isEmpty ? e.toString() : null;
      });
    }
  }

  void _showHistory(List<InspectionSummary> rows) {
    setState(() {
      _history = rows;
      _loading = false;
      _error = null;
    });
    // Quietly pull down what the rows now on screen would need if the signal
    // went away mid-scroll. A summary carries no photo reference, so reaching
    // the media means reading each detail first — both steps are cache-first,
    // so rows already warmed cost nothing and this is free on a repeat load.
    CacheWarmer.instance.prefetchForList(rows);
  }

  /// The coverage denominator. A nicety: its failure leaves the meter out rather
  /// than costing the user their history.
  Future<void> _applyCoverage(
    Future<CacheRead<DashboardData>> read,
    int token,
  ) async {
    try {
      final r = await read;
      if (!mounted || token != _token) return;
      if (r.cached != null) setState(() => _coverage = r.cached);
      final fresh = await r.fresh;
      if (!mounted || token != _token) return;
      if (fresh != null) setState(() => _coverage = fresh);
    } catch (_) {
      // No total to measure against — the bar is simply omitted.
    }
  }

  /// Downloads the history at this user's level as a report.
  ///
  /// Passes no `inspector` — deliberately, and for the same reason [_load] does
  /// not: the tab shows the whole level's work, so the download has to be the
  /// same list. Anything narrower would hand a supervisor a report that
  /// contradicted the screen they took it from.
  Future<ExportedReport> _export(ExportFormat format) =>
      LiExport.shareInspections(format: format);

  void _openDetail(InspectionSummary s) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _InspectionDetailScreen(summary: s),
      ),
    );
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    super.build(context); // keep-alive registration
    if (_loading && _history.isEmpty) {
      return liLoading(message: 'Loading inspections…');
    }
    if (_error != null && _history.isEmpty) {
      return _ErrorView(message: _error!, onRetry: () => _load(force: true));
    }
    if (_history.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            const SizedBox(height: kSpaceXl),
            liEmptyState(
              Icons.history,
              'No inspections yet',
              subtitle:
                  'Every inspection saved at your level shows up here, '
                  'newest first. Start one from the Home map.',
            ),
          ],
        ),
      );
    }

    final days = groupHistoryByDay(_history);
    final now = DateTime.now();

    // One pinned header + one lazy row list per day, so the day a user is
    // scrolling through stays labelled at the top of the viewport.
    return RefreshIndicator(
      // An explicit pull asks for the server's copy, not the cached one.
      onRefresh: () => _load(force: true),
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _summaryCard()),
          for (final day in days) ...[
            SliverPersistentHeader(
              pinned: true,
              delegate: _DayHeaderDelegate(
                label: historyDayLabel(day.date, now: now),
                count: day.rows.length,
              ),
            ),
            SliverList.builder(
              itemCount: day.rows.length,
              itemBuilder: (_, i) => InspectionHistoryTile(
                summary: day.rows[i],
                isMine: _isMine(day.rows[i]),
                onTap: () => _openDetail(day.rows[i]),
              ),
            ),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: kSpaceLg)),
        ],
      ),
    );
  }

  /// The header card: coverage of the jurisdiction, then the figures for the
  /// whole level's history.
  ///
  /// The coverage block is **the same three numbers Home's KPI strip prints** —
  /// `inspected`, `tower_total` and `coverage_pct` straight off the shared
  /// dashboard rollup — because a user comparing the two tabs must never be
  /// shown two different answers to "how many towers are inspected". It counts
  /// towers inspected by *anyone* at this level, which is what Home means too;
  /// this user's own share is drawn as the darker part of the same bar and
  /// spelled out in the caption beneath it.
  ///
  /// The meter needs a denominator, so it only appears once the rollup has
  /// loaded. The figures below the hairline come from the history itself and are
  /// always shown.
  Widget _summaryCard() {
    final d = _coverage;
    final split = coverageSplit(
      total: d?.towerTotal ?? 0,
      inspectedAtLevel: d?.inspected ?? 0,
      myTowers: <int>{
        for (final s in _history)
          if (_isMine(s)) s.towerId,
      }.length,
    );
    final total = split.total;
    // The percentage is the server's own, not one recomputed here, so it reads
    // identically to Home's "Coverage" KPI down to the rounding.
    final pct = d?.coveragePct ?? 0;

    final defects = _history.fold<int>(0, (sum, s) => sum + s.defectCount);
    final critical = _history.where((s) => s.worst == 'critical').length;
    final pending = _history.where((s) => s.id < 0).length;

    return Container(
      margin: const EdgeInsets.fromLTRB(kSpaceMd, kSpaceMd, kSpaceMd, kSpaceXs),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            kBrandAccent.withValues(alpha: 0.10),
            kBrandPrimary.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(kRadiusLg),
        border: Border.all(color: kBrandAccent.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.all(kSpaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Text(
                  'Coverage at your level',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    color: kBrandPrimary,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
              if (total > 0)
                Text(
                  '$pct%',
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 20,
                    height: 1,
                    color: kBrandPrimary,
                  ),
                ),
            ],
          ),
          if (total > 0) ...[
            const SizedBox(height: kSpaceMd),
            _CoverageBar(split: split),
            const SizedBox(height: kSpaceSm),
            Text(
              '${split.inspected} of $total towers inspected'
              '${split.mine > 0 ? ' · ${split.mine} by you' : ''}',
              style: const TextStyle(fontSize: 12.5, color: kInkSoft),
            ),
          ],
          const SizedBox(height: kSpaceMd),
          Divider(height: 1, color: kBrandAccent.withValues(alpha: 0.18)),
          const SizedBox(height: kSpaceXs),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'ALL AT YOUR LEVEL',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.9,
                    color: kInkFaint,
                  ),
                ),
              ),
              // On this row rather than beside the coverage percentage above it:
              // the figures under this label are what the report contains, and
              // the meter above describes the jurisdiction, not the history.
              LiExportButton(
                title: 'inspection history',
                rowCount: _history.isEmpty ? null : _history.length,
                caveat: pendingCaveat(pending),
                runner: _export,
              ),
            ],
          ),
          const SizedBox(height: kSpaceXs),
          Row(
            children: [
              _Stat(value: '${_history.length}', label: 'Inspections'),
              _StatDivider(),
              _Stat(value: '$defects', label: 'Defects found'),
              _StatDivider(),
              _Stat(
                value: '$critical',
                label: 'Critical',
                color: critical > 0 ? critColor('critical') : null,
              ),
              if (pending > 0) ...[
                _StatDivider(),
                _Stat(
                  value: '$pending',
                  label: 'Pending',
                  color: kCritColor['major'],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// The coverage meter, in three parts: the towers this user inspected, the ones
/// their colleagues at the same level inspected, and the remaining track.
///
/// Splitting it is what lets one bar carry both readings — the jurisdiction
/// total that Home also prints, and this user's share of it — instead of the tab
/// having to pick one and look wrong against the other.
class _CoverageBar extends StatelessWidget {
  const _CoverageBar({required this.split});

  final CoverageSplit split;

  @override
  Widget build(BuildContext context) {
    // Flex takes the counts directly, so the segments are exact — no rounding.
    final mine = split.mine;
    final others = split.others;
    final rest = split.rest;
    return ClipRRect(
      borderRadius: BorderRadius.circular(kRadiusPill),
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            if (mine > 0)
              Expanded(
                flex: mine,
                child: const ColoredBox(color: kBrandAccent),
              ),
            if (others > 0)
              Expanded(
                flex: others,
                child: ColoredBox(color: kBrandAccent.withValues(alpha: 0.38)),
              ),
            if (rest > 0)
              Expanded(
                flex: rest,
                child: ColoredBox(color: kBrandPrimary.withValues(alpha: 0.10)),
              ),
          ],
        ),
      ),
    );
  }
}

/// One figure in the summary card's stat row.
class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.color});
  final String value;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 17,
              height: 1.1,
              fontWeight: FontWeight.w800,
              color: color ?? kBrandPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.2,
              color: kInkSoft,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 26,
    margin: const EdgeInsets.symmetric(horizontal: kSpaceMd),
    color: kBrandAccent.withValues(alpha: 0.18),
  );
}

/// The pinned day label above each group. Opaque over [kSurface] so rows scroll
/// out of sight behind it, with a hairline that only appears once content has
/// scrolled under — a flat label while it sits at rest.
class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DayHeaderDelegate({required this.label, required this.count});
  final String label;
  final int count;

  static const double _height = 34;

  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return Container(
      height: _height,
      padding: const EdgeInsets.symmetric(horizontal: kSpaceMd),
      decoration: BoxDecoration(
        color: kSurface,
        border: Border(
          bottom: BorderSide(
            color: overlapsContent ? kOutline : Colors.transparent,
          ),
        ),
      ),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.9,
                color: kInkSoft,
              ),
            ),
          ),
          Text(
            '$count',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: kInkFaint,
            ),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_DayHeaderDelegate old) =>
      old.label != label || old.count != count;
}

/// One inspection in the History list.
///
/// The criticality is carried by a coloured edge *and* the word for it, never by
/// colour alone. The tower number leads because that is what an engineer scans
/// the list for; the line name follows for the supervisors whose history spans
/// several lines.
class InspectionHistoryTile extends StatelessWidget {
  const InspectionHistoryTile({
    super.key,
    required this.summary,
    required this.onTap,
    this.isMine = true,
  });

  final InspectionSummary summary;
  final VoidCallback onTap;

  /// Whether the signed-in user captured this inspection. When they did not, the
  /// capturing employee's id is shown on the meta line — the list spans a whole
  /// level, so "who did this one" is part of reading it.
  final bool isMine;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final crit = critColor(s.worst);
    // Locally-created inspections carry a negative id until the outbox drains.
    final pending = s.id < 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(kSpaceMd, 0, kSpaceMd, kSpaceSm),
      child: Material(
        color: kCardBg,
        borderRadius: BorderRadius.circular(kRadiusMd),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(kRadiusMd),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(kRadiusMd),
              border: Border.all(color: kOutline),
            ),
            child: Row(
              children: [
                // Criticality edge — full-height so the severity of a row is
                // readable while scanning, without a chip competing for space.
                Container(
                  width: 4,
                  height: 58,
                  decoration: BoxDecoration(
                    color: crit,
                    borderRadius: const BorderRadius.horizontal(
                      left: Radius.circular(kRadiusMd),
                    ),
                  ),
                ),
                const SizedBox(width: kSpaceMd),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              'T-${s.towerNumber}',
                              style: const TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w800,
                                color: kInk,
                                letterSpacing: 0.2,
                              ),
                            ),
                            if (s.lineName.isNotEmpty) ...[
                              const SizedBox(width: kSpaceSm),
                              Expanded(
                                child: Text(
                                  s.lineName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                    color: kInkSoft,
                                  ),
                                ),
                              ),
                            ] else
                              const Spacer(),
                            if (pending) const _PendingPill(),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Row(
                          children: [
                            Text(
                              critLabel(s.worst),
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: crit,
                              ),
                            ),
                            const _MetaDot(),
                            Text(
                              defectsLabel(s.defectCount),
                              style: const TextStyle(
                                fontSize: 12,
                                color: kInkSoft,
                              ),
                            ),
                            // Who captured it outranks the tower type on a list
                            // that spans a whole level, so it takes the same
                            // slot rather than adding width to the row.
                            if (!isMine && s.inspector.isNotEmpty) ...[
                              const _MetaDot(),
                              const Icon(
                                Icons.person_outline,
                                size: 12,
                                color: kInkFaint,
                              ),
                              const SizedBox(width: 3),
                              Expanded(
                                child: Text(
                                  s.inspector,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: kInkFaint,
                                  ),
                                ),
                              ),
                            ] else if (s.towerType.isNotEmpty) ...[
                              const _MetaDot(),
                              Expanded(
                                child: Text(
                                  s.towerType,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: kInkFaint,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right, size: 20, color: kInkFaint),
                const SizedBox(width: kSpaceSm),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The '·' separating two facts on a meta line.
class _MetaDot extends StatelessWidget {
  const _MetaDot();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 6),
    child: Text('·', style: TextStyle(fontSize: 12, color: kInkFaint)),
  );
}

/// Marks a row that is still in the outbox, so a user who saved offline can see
/// the inspection is recorded but not yet on the server.
class _PendingPill extends StatelessWidget {
  const _PendingPill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: kCritColor['major']!.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(kRadiusPill),
        border: Border.all(color: kCritColor['major']!.withValues(alpha: 0.40)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_upload_outlined,
            size: 11,
            color: kCritColor['major'],
          ),
          const SizedBox(width: 4),
          Text(
            'Pending',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.3,
              color: kCritColor['major'],
            ),
          ),
        ],
      ),
    );
  }
}

/// Full-screen detail for a single inspection.
class _InspectionDetailScreen extends StatefulWidget {
  const _InspectionDetailScreen({required this.summary});
  final InspectionSummary summary;

  @override
  State<_InspectionDetailScreen> createState() =>
      _InspectionDetailScreenState();
}

class _InspectionDetailScreenState extends State<_InspectionDetailScreen> {
  late Future<InspectionDetail> _future;

  /// Cache-first: a saved inspection never changes, so one that has been opened
  /// before (or pre-downloaded for offline) opens from disk with no round trip.
  Future<InspectionDetail> _read({bool force = false}) =>
      LineInspectionApi.readInspectionDetail(
        widget.summary.id,
        force: force,
      ).then((r) => r.value);

  @override
  void initState() {
    super.initState();
    _future = _read();
  }

  void _retry() {
    setState(() {
      _future = _read(force: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('T-${widget.summary.towerNumber}')),
      body: FutureBuilder<InspectionDetail>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return liLoading();
          }
          if (snap.hasError) {
            return _ErrorView(message: '${snap.error}', onRetry: _retry);
          }
          final d = snap.data!;
          return _DetailBody(detail: d);
        },
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody({required this.detail});
  final InspectionDetail detail;

  @override
  Widget build(BuildContext context) {
    final withDefects = detail.itemResults
        .where((r) => r.entries.isNotEmpty)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Header(detail: detail),
        const SizedBox(height: 16),
        if (withDefects.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check_circle, color: critColor('ok'), size: 20),
                  const SizedBox(width: 8),
                  Text(
                    'All normal',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: critColor('ok'),
                    ),
                  ),
                ],
              ),
            ),
          )
        else
          ...withDefects.map((r) => _ItemCard(item: r)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.detail});
  final InspectionDetail detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            kBrandAccent.withValues(alpha: 0.10),
            kBrandPrimary.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(kRadiusLg),
        border: Border.all(color: kBrandAccent.withValues(alpha: 0.22)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'T-${detail.towerNumber} · ${detail.towerType}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: kBrandPrimary,
                  ),
                ),
              ),
              critChip(detail.worst),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            detail.lineName,
            style: const TextStyle(fontWeight: FontWeight.w600, color: kInk),
          ),
          const SizedBox(height: 4),
          Text(
            '${detail.date} · ${detail.inspector}',
            style: const TextStyle(fontSize: 13, color: kInkSoft),
          ),
          if (detail.remarks.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              detail.remarks,
              style: const TextStyle(fontStyle: FontStyle.italic, color: kInk),
            ),
          ],
        ],
      ),
    );
  }
}

class _ItemCard extends StatelessWidget {
  const _ItemCard({required this.item});
  final ItemResultDetail item;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${item.sno}. ${item.itemLabel}'
              '${item.position.isNotEmpty ? ' · ${item.position}' : ''}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            if (item.photo != null) ...[
              const SizedBox(height: 10),
              _Thumb(path: item.photo!),
            ],
            const SizedBox(height: 8),
            ...item.entries.map((e) => _EntryTile(entry: e)),
          ],
        ),
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final DefectEntryDetail entry;

  @override
  Widget build(BuildContext context) {
    final answers = answersText(entry.answers);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: critColor(entry.criticality).withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: critColor(entry.criticality).withValues(alpha: 0.25),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              critChip(entry.criticality),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.defectLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          if (answers.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(answers, style: const TextStyle(fontSize: 13)),
          ],
          if (entry.note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              entry.note,
              style: const TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: kInkSoft,
              ),
            ),
          ],
          if (entry.photo != null) ...[
            const SizedBox(height: 8),
            _Thumb(path: entry.photo!),
          ],
        ],
      ),
    );
  }
}

/// A ~120px inspection photo thumbnail: tappable, with a loading spinner, a
/// full-screen pinch-to-zoom viewer, and a broken-image fallback.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    return _liThumb(path);
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) =>
      liErrorState(message, title: 'Could not load', onRetry: onRetry);
}
