import 'package:flutter/material.dart';

import '../models/li_export.dart';
import '../services/li_export.dart';
import '../services/line_inspection_api.dart';
import '../services/offline/connectivity_service.dart';
import '../utils/li_style.dart';

/// Fetches one report and hands it to the share sheet. Supplied by the tab, so
/// the button carries no knowledge of which endpoint or which filters are in
/// play.
typedef ExportRunner = Future<ExportedReport> Function(ExportFormat format);

/// The download control on the History and Tickets tabs: a single icon that
/// opens a sheet offering Excel or PDF, then fetches the chosen one and passes it
/// to the OS share sheet.
///
/// One widget for both tabs so the two downloads are the same gesture, the same
/// wording and the same failure handling — a tab supplies only its [runner], its
/// [title], and anything it needs said before the download starts ([caveat]).
///
/// **Offline.** The report is rendered by the server against the authoritative
/// data, so this is the one action in the app that genuinely cannot be queued:
/// there is nothing to write locally and replay. It refuses early with a plain
/// explanation instead of opening the sheet and failing at the end of it.
class LiExportButton extends StatefulWidget {
  const LiExportButton({
    super.key,
    required this.title,
    required this.runner,
    this.caveat,
    this.rowCount,
  });

  /// What is being exported — 'Inspection history', 'Defect tickets'. Heads the
  /// sheet, so the user can see what they are about to download.
  final String title;

  /// Fetches and shares the report in the chosen format.
  final ExportRunner runner;

  /// Something the reader has to know before downloading — currently the count
  /// of inspections still in the outbox, which the server cannot know about and
  /// so cannot include. Shown in the sheet, above the format choice.
  final String? caveat;

  /// How many rows the tab is currently showing, if it knows. Shown in the sheet
  /// so the size of the download is no surprise.
  final int? rowCount;

  @override
  State<LiExportButton> createState() => _LiExportButtonState();
}

class _LiExportButtonState extends State<LiExportButton> {
  /// True from the moment a format is chosen until the share sheet has been
  /// handed the file. Guards against a second tap starting a second download.
  bool _busy = false;

  Future<void> _open() async {
    if (_busy) return;
    if (!ConnectivityService.instance.online.value) {
      _say(
        'No connection — a report is built on the server, '
        'so it cannot be downloaded offline.',
      );
      return;
    }
    final format = await showModalBottomSheet<ExportFormat>(
      context: context,
      backgroundColor: kCardBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusXl)),
      ),
      builder: (_) => _FormatSheet(
        title: widget.title,
        caveat: widget.caveat,
        rowCount: widget.rowCount,
      ),
    );
    if (format == null || !mounted) return;
    await _run(format);
  }

  Future<void> _run(ExportFormat format) async {
    setState(() => _busy = true);
    try {
      final report = await widget.runner(format);
      if (!mounted) return;
      // The share sheet has already been offered by this point — this only
      // confirms what was produced, so the user knows the file is real and how
      // big it is even if they dismissed the sheet without choosing a target.
      _say('${report.filename} · ${LiExport.formatSize(report.sizeBytes)}');
    } on UnauthorizedException {
      // Deliberately not reported here: the app as a whole reacts to an expired
      // session and returns to the login screen, and a snackbar about a failed
      // download on the way out would only be noise.
    } catch (e) {
      if (!mounted) return;
      _say('Could not download the report: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _say(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Icon *and* word, not the icon alone. A download arrow on its own is the
    // kind of control an engineer has to tap to discover — and this one is the
    // only way to get a report off the phone, so it says what it does. The
    // outlined treatment matches the Close action on a ticket card, so the two
    // secondary actions in these tabs read as the same weight.
    return Tooltip(
      // The label says what the control does; this says what comes out of it.
      // Long-press on a phone, hover on the desktop builds.
      message: 'Download as Excel or PDF',
      child: _button(),
    );
  }

  Widget _button() {
    return OutlinedButton.icon(
      onPressed: _busy ? null : _open,
      icon: _busy
          ? const SizedBox(
              width: 15,
              height: 15,
              child: CircularProgressIndicator(
                strokeWidth: 2.0,
                color: kBrandAccent,
              ),
            )
          : const Icon(Icons.download_outlined, size: 17),
      label: Text(_busy ? 'Preparing…' : 'Download'),
      style: OutlinedButton.styleFrom(
        foregroundColor: kBrandAccent,
        side: BorderSide(color: kBrandAccent.withValues(alpha: 0.45)),
        // Sized to sit inside a filter row and a card header without setting the
        // row's height: the default button padding is built for a form.
        padding: const EdgeInsets.symmetric(horizontal: kSpaceMd, vertical: 0),
        minimumSize: const Size(0, 34),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.2,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusSm),
        ),
      ),
    );
  }
}

/// The format choice: Excel or PDF, with the caveat and row count above them.
class _FormatSheet extends StatelessWidget {
  const _FormatSheet({required this.title, this.caveat, this.rowCount});

  final String title;
  final String? caveat;
  final int? rowCount;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      // Scrollable, not just min-height: a modal sheet is capped at a fraction
      // of the screen, and the caveat is a variable-length paragraph — on a
      // short screen the header, the caveat and both format rows together
      // overflowed the cap and the second format was unreachable.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(kSpaceLg, kSpaceMd, kSpaceLg, kSpaceSm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Grab handle — the sheet is dismissible, and this is what says so.
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: kSpaceMd),
                decoration: BoxDecoration(
                  color: kOutline,
                  borderRadius: BorderRadius.circular(kRadiusPill),
                ),
              ),
            ),
            liSectionHeader(
              Icons.download_outlined,
              'Download $title',
              count: rowCount,
            ),
            if (caveat != null) ...[
              const SizedBox(height: kSpaceMd),
              _Caveat(text: caveat!),
            ],
            const SizedBox(height: kSpaceSm),
            for (final format in ExportFormat.values)
              _FormatTile(format: format),
            const SizedBox(height: kSpaceXs),
          ],
        ),
      ),
    );
  }
}

/// One format row in the sheet.
class _FormatTile extends StatelessWidget {
  const _FormatTile({required this.format});

  final ExportFormat format;

  static const Map<ExportFormat, IconData> _icons = {
    ExportFormat.xlsx: Icons.table_chart_outlined,
    ExportFormat.pdf: Icons.picture_as_pdf_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: kBrandAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(kRadiusSm),
        ),
        child: Icon(_icons[format], color: kBrandAccent, size: 21),
      ),
      title: Text(
        format.label,
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          fontSize: 14.5,
          color: kInk,
        ),
      ),
      subtitle: Text(
        format.detail,
        style: const TextStyle(fontSize: 12, color: kInkSoft, height: 1.3),
      ),
      trailing: const Icon(Icons.chevron_right, size: 20, color: kInkFaint),
      onTap: () => Navigator.pop(context, format),
    );
  }
}

/// The "not everything is on the server yet" note above the format choice.
///
/// Deliberately prominent rather than a footnote: a report that silently omits
/// the work still sitting in the outbox would read as a complete record of it.
class _Caveat extends StatelessWidget {
  const _Caveat({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final color = kCritColor['major']!;
    return Container(
      padding: const EdgeInsets.all(kSpaceMd),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(kRadiusSm),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.cloud_upload_outlined, size: 17, color: color),
          const SizedBox(width: kSpaceSm),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12.5, color: kInk, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}
