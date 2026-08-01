import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/li_export.dart';
import 'line_inspection_api.dart';

/// Downloading a report and handing it to the engineer.
///
/// The split with [LineInspectionApi] is deliberate: the API owns the request
/// (auth, timeouts, the 401 path), this owns what happens to the bytes once they
/// land — writing them somewhere real, and opening the OS share sheet so they
/// can be saved to Files/Drive or sent on to whoever asked for the report.
///
/// **Why the share sheet rather than a Downloads folder.** Writing into shared
/// storage means `WRITE_EXTERNAL_STORAGE` on old Android and the Storage Access
/// Framework on new, and either way the file lands somewhere the app cannot then
/// point the user at. Writing into the app's *own* directory needs no permission
/// on any Android version, and the share sheet is what turns it into "save to
/// Drive" or "send to the EE" — which is what a downloaded report is actually
/// for.
class LiExport {
  LiExport._();

  /// Where downloaded reports are written. A subdirectory so a stale report can
  /// be swept without touching anything else the app keeps on disk.
  static const String _dirName = 'reports';

  /// Fetches [format] of the History report and hands it to the share sheet.
  /// Filters mirror the ones the tab is reading under.
  static Future<ExportedReport> shareInspections({
    required ExportFormat format,
    int? subdivision,
    int? line,
    int? tower,
    String? inspector,
  }) async {
    final report = await LineInspectionApi.exportInspections(
      format: format,
      subdivision: subdivision,
      line: line,
      tower: tower,
      inspector: inspector,
    );
    await shareReport(report, format, subject: 'Inspection history');
    return report;
  }

  /// Fetches [format] of the Tickets report and hands it to the share sheet.
  static Future<ExportedReport> shareTickets({
    required ExportFormat format,
    String? status,
    int? subdivision,
    int? line,
    int? tower,
  }) async {
    final report = await LineInspectionApi.exportTickets(
      format: format,
      status: status,
      subdivision: subdivision,
      line: line,
      tower: tower,
    );
    await shareReport(report, format, subject: 'Defect tickets');
    return report;
  }

  /// Writes [report] to disk and opens the share sheet on it.
  static Future<void> shareReport(
    ExportedReport report,
    ExportFormat format, {
    required String subject,
  }) async {
    final file = await writeToDisk(report);
    await SharePlus.instance.share(
      ShareParams(
        // `subject` becomes the subject line when the target is mail, and is
        // ignored elsewhere. The shared file keeps the name it was written
        // under, which is already the server's — so nothing has to override it.
        subject: subject,
        files: [XFile(file.path, mimeType: format.mimeType)],
      ),
    );
  }

  /// Writes [report] into the app's reports directory and returns the file.
  ///
  /// The previous download of the same report is overwritten rather than
  /// accumulating `report (3).xlsx` copies: the server stamps every filename with
  /// the minute it was generated, so two files only ever collide when the same
  /// report was asked for twice inside the same minute — in which case they hold
  /// the same thing.
  @visibleForTesting
  static Future<File> writeToDisk(ExportedReport report) async {
    final dir = Directory('${(await _baseDir()).path}/$_dirName');
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File('${dir.path}/${report.filename}');
    await file.writeAsBytes(report.bytes, flush: true);
    return file;
  }

  /// Prefers the platform's own downloads directory where there is one (desktop,
  /// and iOS' per-app Documents), falling back to app support. Both are inside
  /// the app's sandbox on mobile, so neither needs a storage permission.
  ///
  /// Neither is the share cache, and that is a requirement rather than a
  /// preference: share_plus copies whatever it is given into
  /// `cacheDir/share_plus` and shares it from there through its own
  /// FileProvider — and it *throws* if handed a file that already lives in that
  /// folder, since it wipes it between shares.
  static Future<Directory> _baseDir() async {
    try {
      final downloads = await getDownloadsDirectory();
      if (downloads != null) return downloads;
    } on UnsupportedError {
      // Android has no per-app downloads directory — fall through.
    } catch (_) {
      // Any other platform-channel failure: the fallback is just as usable.
    }
    return getApplicationSupportDirectory();
  }

  /// A short human size for the download confirmation — '48 KB', '1.2 MB'.
  ///
  /// Rounded to whole kilobytes below a megabyte: the reader is checking that
  /// something substantial arrived, and a decimal on '48 KB' is noise.
  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.round()} KB';
    return '${(kb / 1024).toStringAsFixed(1)} MB';
  }
}
