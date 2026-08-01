import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/models/li_export.dart';
import 'package:drone_inspection_app/screens/li_tabs/inspections_tab.dart';
import 'package:drone_inspection_app/services/li_export.dart';
import 'package:drone_inspection_app/services/line_inspection_api.dart';
import 'package:drone_inspection_app/services/offline/connectivity_service.dart';
import 'package:drone_inspection_app/utils/li_theme.dart';
import 'package:drone_inspection_app/widgets/li_export_button.dart';

/// The History / Tickets report download: the pieces that decide what lands on
/// the phone and what the user is told before it does.
///
/// The transport itself is not exercised here — it is one authenticated GET
/// sharing [LineInspectionApi]'s existing 401 and timeout handling. What is
/// pinned instead is everything that could go wrong *around* it: the filename
/// taken from a server header (which must never be treated as a path), the
/// offline refusal, and the outbox caveat that keeps a report from reading as a
/// complete record of work still sitting on the device.

ExportedReport _report(String name, {int size = 4096}) => ExportedReport(
      bytes: Uint8List(size),
      filename: name,
    );

void main() {
  group('filenameFromDisposition', () {
    test('takes the quoted filename Django sends', () {
      expect(
        LineInspectionApi.filenameFromDisposition(
            'attachment; filename="li_history_20260730_1042.xlsx"'),
        'li_history_20260730_1042.xlsx',
      );
    });

    test('accepts an unquoted filename and the RFC 5987 form', () {
      expect(
        LineInspectionApi.filenameFromDisposition('attachment; filename=a.pdf'),
        'a.pdf',
      );
      expect(
        LineInspectionApi.filenameFromDisposition(
            "attachment; filename*=UTF-8''li%20tickets.pdf"),
        'li tickets.pdf',
      );
    });

    test('is case-insensitive about the header keyword', () {
      expect(
        LineInspectionApi.filenameFromDisposition(
            'attachment; FileName="x.xlsx"'),
        'x.xlsx',
      );
    });

    test('null when there is no header or no filename in it', () {
      expect(LineInspectionApi.filenameFromDisposition(null), isNull);
      expect(LineInspectionApi.filenameFromDisposition('attachment'), isNull);
    });

    test('a server-supplied name can never escape its directory', () {
      // The name arrives over the network and is about to be joined onto a
      // directory path, so it is only ever used as a leaf.
      expect(
        LineInspectionApi.filenameFromDisposition(
            'attachment; filename="../../etc/passwd"'),
        'passwd',
      );
      expect(
        LineInspectionApi.filenameFromDisposition(
            r'attachment; filename="..\..\windows\system32\evil.xlsx"'),
        'evil.xlsx',
      );
      // A name that is nothing but traversal still yields something writable.
      expect(
        LineInspectionApi.filenameFromDisposition('attachment; filename="../"'),
        'aptransco_report',
      );
    });
  });

  group('ExportFormat', () {
    test('the wire value is what the backend validates, not the enum name', () {
      expect(ExportFormat.xlsx.wire, 'xlsx');
      expect(ExportFormat.pdf.wire, 'pdf');
    });

    test('each format carries the mime type the share sheet needs', () {
      // Without it Android offers almost no target for a spreadsheet.
      expect(ExportFormat.xlsx.mimeType, contains('spreadsheetml'));
      expect(ExportFormat.pdf.mimeType, 'application/pdf');
    });
  });

  group('formatSize', () {
    test('whole kilobytes below a megabyte, one decimal above', () {
      expect(LiExport.formatSize(512), '512 B');
      expect(LiExport.formatSize(49152), '48 KB');
      expect(LiExport.formatSize(1572864), '1.5 MB');
    });
  });

  group('pendingCaveat', () {
    test('nothing to say when the outbox is empty', () {
      expect(pendingCaveat(0), isNull);
      expect(pendingCaveat(-1), isNull);
    });

    test('names the unsynced count so a report is not read as complete', () {
      expect(pendingCaveat(1), contains('1 inspection'));
      expect(pendingCaveat(1), contains('has not synced'));
      expect(pendingCaveat(3), contains('3 inspections'));
      expect(pendingCaveat(3), contains('have not synced'));
    });
  });

  group('LiExportButton', () {
    Widget host(Widget child) => MaterialApp(
          theme: buildLiTheme(),
          home: Scaffold(body: Center(child: child)),
        );

    // The service is a singleton, so a test that goes offline restores it.
    tearDown(() {
      ConnectivityService.instance.online.value = true;
    });

    testWidgets('is a labelled button, not a bare icon', (tester) async {
      // The only route a report has off the phone, so it names itself rather
      // than leaving a download arrow to be discovered by tapping.
      ConnectivityService.instance.online.value = true;
      await tester.pumpWidget(host(LiExportButton(
        title: 'inspection history',
        runner: (_) async => _report('x.xlsx'),
      )));

      expect(find.widgetWithText(OutlinedButton, 'Download'), findsOneWidget);
      expect(find.byIcon(Icons.download_outlined), findsOneWidget);
    });

    testWidgets('says it is working while the report is built', (tester) async {
      ConnectivityService.instance.online.value = true;
      final gate = Completer<ExportedReport>();
      await tester.pumpWidget(host(LiExportButton(
        title: 'inspection history',
        runner: (_) => gate.future,
      )));

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Excel'));
      await tester.pump(); // the sheet closes, the request is in flight

      expect(find.text('Preparing…'), findsOneWidget);
      // Disabled, so a second tap cannot start a second download.
      expect(
        tester
            .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Preparing…'))
            .onPressed,
        isNull,
      );

      gate.complete(_report('x.xlsx'));
      await tester.pumpAndSettle();
      expect(find.text('Download'), findsOneWidget);
    });

    testWidgets('offers both formats and runs the chosen one', (tester) async {
      ConnectivityService.instance.online.value = true;
      final asked = <ExportFormat>[];
      await tester.pumpWidget(host(LiExportButton(
        title: 'inspection history',
        rowCount: 15,
        runner: (format) async {
          asked.add(format);
          return _report('li_history_20260730_1042.xlsx');
        },
      )));

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.text('Download inspection history'), findsOneWidget);
      expect(find.text('15'), findsOneWidget); // the row-count badge
      expect(find.text('Excel'), findsOneWidget);
      expect(find.text('PDF'), findsOneWidget);

      await tester.tap(find.text('Excel'));
      await tester.pumpAndSettle();
      expect(asked, [ExportFormat.xlsx]);
      // The confirmation names the file and its size, so a dismissed share
      // sheet still leaves proof the report was produced.
      expect(
        find.textContaining('li_history_20260730_1042.xlsx'),
        findsOneWidget,
      );
      expect(find.textContaining('4 KB'), findsOneWidget);
    });

    testWidgets('shows the outbox caveat in the sheet', (tester) async {
      ConnectivityService.instance.online.value = true;
      await tester.pumpWidget(host(LiExportButton(
        title: 'inspection history',
        caveat: pendingCaveat(2),
        runner: (_) async => _report('x.pdf'),
      )));

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 inspections'), findsOneWidget);
    });

    testWidgets('refuses offline instead of failing at the end', (tester) async {
      ConnectivityService.instance.online.value = false;
      var ran = false;
      await tester.pumpWidget(host(LiExportButton(
        title: 'defect tickets',
        runner: (_) async {
          ran = true;
          return _report('x.xlsx');
        },
      )));

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      // No format sheet, no request — a report is built server-side, so there is
      // nothing to queue and replay.
      expect(find.text('Excel'), findsNothing);
      expect(ran, isFalse);
      expect(find.textContaining('cannot be downloaded offline'), findsOneWidget);
    });

    testWidgets('surfaces a failure and re-enables the button', (tester) async {
      ConnectivityService.instance.online.value = true;
      await tester.pumpWidget(host(LiExportButton(
        title: 'defect tickets',
        runner: (_) async => throw Exception('Tickets export failed (500)'),
      )));

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('PDF'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not download'), findsOneWidget);
      expect(find.textContaining('500'), findsOneWidget);
      // Still tappable — a failed download must not dead-end the tab, and the
      // label has gone back from 'Preparing…' to 'Download'.
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Download'),
      );
      expect(button.onPressed, isNotNull);
    });

    testWidgets('a session expiry is left to the app, not the snackbar',
        (tester) async {
      ConnectivityService.instance.online.value = true;
      await tester.pumpWidget(host(LiExportButton(
        title: 'inspection history',
        runner: (_) async => throw const UnauthorizedException(),
      )));

      await tester.tap(find.text('Download'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Excel'));
      await tester.pumpAndSettle();

      // The app returns to the login screen on its own; a download complaint on
      // the way out would be noise.
      expect(find.textContaining('Could not download'), findsNothing);
    });
  });
}
