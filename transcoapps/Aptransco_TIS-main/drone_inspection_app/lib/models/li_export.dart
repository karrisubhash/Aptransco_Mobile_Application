/// The report-download value types, shared by the transport that fetches a
/// report ([LineInspectionApi.exportInspections] / `exportTickets`), the service
/// that writes and shares it (`services/li_export.dart`) and the button that
/// offers it (`widgets/li_export_button.dart`).
///
/// They live here, in `models/`, rather than in either of those files so the
/// import graph stays one-way: the service imports the API, and both import
/// this.
library;

import 'dart:typed_data';

/// A download format the export endpoints can produce.
///
/// [wire] is the `?format=` value the backend validates against
/// (`exports.FORMATS`), kept separate from the enum name so renaming one here
/// cannot silently change the request.
enum ExportFormat {
  xlsx(
    wire: 'xlsx',
    label: 'Excel',
    detail: 'Spreadsheet (.xlsx) — filter and sort every column',
    mimeType:
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  ),
  pdf(
    wire: 'pdf',
    label: 'PDF',
    detail: 'Printable report — one page-wide table',
    mimeType: 'application/pdf',
  );

  const ExportFormat({
    required this.wire,
    required this.label,
    required this.detail,
    required this.mimeType,
  });

  /// The `?format=` value sent to the server.
  final String wire;

  /// What the download sheet calls this format.
  final String label;

  /// The supporting line under [label] — what the reader gets, not how it is
  /// made, so the choice can be made without knowing the file formats.
  final String detail;

  /// Passed to the OS share sheet, which uses it to decide which apps can
  /// receive the file. Without it Android offers almost nothing for an .xlsx.
  final String mimeType;
}

/// A report as it came off the wire: its bytes, and the name the *server* gave
/// it.
///
/// The name matters enough to carry: the backend already names every export
/// (`exports.Report.filename`), so honouring it here keeps one naming scheme
/// across the phone and the web dashboard rather than each inventing its own.
class ExportedReport {
  const ExportedReport({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;

  int get sizeBytes => bytes.length;
}
