import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/models/li_records.dart';
import 'package:drone_inspection_app/screens/li_tabs/inspections_tab.dart';
import 'package:drone_inspection_app/utils/li_theme.dart';

InspectionSummary _s(
  int id,
  String date, {
  String tower = '1',
  String line = 'TEST LINE',
  String type = 'Suspension',
  String worst = 'ok',
  int defects = 0,
}) =>
    InspectionSummary(
      id: id,
      towerId: id,
      towerNumber: tower,
      towerType: type,
      lineName: line,
      date: date,
      inspector: 'AEE1',
      worst: worst,
      defectCount: defects,
    );

void main() {
  group('groupHistoryByDay', () {
    test('one group per day, newest day first', () {
      final days = groupHistoryByDay([
        _s(1, '2026-07-29'),
        _s(2, '2026-07-29'),
        _s(3, '2026-07-24'),
      ]);
      expect(days.map((d) => d.date).toList(), ['2026-07-29', '2026-07-24']);
      expect(days[0].rows.map((s) => s.id).toList(), [1, 2]);
      expect(days[1].rows.map((s) => s.id).toList(), [3]);
    });

    test('same-day rows keep the order the server returned them in', () {
      final days = groupHistoryByDay([
        _s(9, '2026-07-29', tower: '9'),
        _s(4, '2026-07-29', tower: '4'),
        _s(7, '2026-07-29', tower: '7'),
      ]);
      expect(days.single.rows.map((s) => s.towerNumber).toList(),
          ['9', '4', '7']);
    });

    test('a backdated inspection joins its own day instead of splitting it', () {
      // id 1 was saved most recently (so returned first) but visited earlier.
      final days = groupHistoryByDay([
        _s(1, '2026-07-27'),
        _s(2, '2026-07-29'),
        _s(3, '2026-07-27'),
      ]);
      expect(days.length, 2);
      expect(days[0].date, '2026-07-29');
      expect(days[1].rows.map((s) => s.id).toList(), [1, 3]);
    });

    test('an empty history produces no groups', () {
      expect(groupHistoryByDay(const []), isEmpty);
    });
  });

  group('historyDayLabel', () {
    final now = DateTime(2026, 7, 29, 14, 30);

    test('names today and yesterday relatively', () {
      expect(historyDayLabel('2026-07-29', now: now), 'TODAY');
      expect(historyDayLabel('2026-07-28', now: now), 'YESTERDAY');
    });

    test('spells out anything older', () {
      expect(historyDayLabel('2026-07-24', now: now), '24 JUL 2026');
      expect(historyDayLabel('2025-12-01', now: now), '1 DEC 2025');
    });

    test('a time-of-day component does not shift the day', () {
      // A late-evening save must still read as TODAY, not YESTERDAY.
      expect(historyDayLabel('2026-07-29T23:45:00', now: now), 'TODAY');
    });

    test('falls back readably on a missing or unparseable date', () {
      expect(historyDayLabel('', now: now), 'UNDATED');
      expect(historyDayLabel('not-a-date', now: now), 'NOT-A-DATE');
    });
  });

  group('defectsLabel', () {
    test('reads as words, singular and plural', () {
      expect(defectsLabel(0), 'No defects');
      expect(defectsLabel(1), '1 defect');
      expect(defectsLabel(4), '4 defects');
    });
  });

  group('coverageSplit', () {
    test('splits the level total into mine, others and untouched', () {
      final s = coverageSplit(total: 100, inspectedAtLevel: 30, myTowers: 12);
      expect(s.inspected, 30); // the figure Home's strip prints
      expect(s.mine, 12);
      expect(s.others, 18);
      expect(s.rest, 70);
      expect(s.mine + s.others + s.rest, s.total);
    });

    test('an unsynced inspection cannot make my share exceed the rollup', () {
      // 8 towers in my rows, but the server has only counted 6 — two are still
      // in the outbox. The bar must not draw a longer "by you" segment than the
      // inspected segment that contains it.
      final s = coverageSplit(total: 50, inspectedAtLevel: 6, myTowers: 8);
      expect(s.mine, 6);
      expect(s.others, 0);
      expect(s.rest, 44);
      expect(s.mine + s.others + s.rest, s.total);
    });

    test('a rollup larger than the total is clamped to it', () {
      final s = coverageSplit(total: 10, inspectedAtLevel: 12, myTowers: 12);
      expect(s.inspected, 10);
      expect(s.mine, 10);
      expect(s.rest, 0);
    });

    test('an empty jurisdiction stays at zero rather than dividing by it', () {
      final s = coverageSplit(total: 0, inspectedAtLevel: 0, myTowers: 0);
      expect(s.total, 0);
      expect(s.inspected, 0);
      expect(s.mine, 0);
      expect(s.others, 0);
      expect(s.rest, 0);
    });
  });

  group('InspectionHistoryTile', () {
    /// A 360dp phone is where a long line name would overflow the row.
    Future<void> pumpTile(WidgetTester tester, InspectionSummary s,
        {bool isMine = true}) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: buildLiTheme(),
        home: Scaffold(
          body: InspectionHistoryTile(
              summary: s, isMine: isMine, onTap: () {}),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('lays out the worst real-world row without overflowing',
        (tester) async {
      await pumpTile(
        tester,
        _s(1, '2026-07-29',
            tower: '147',
            line: 'Kurnool - Nandyal 220kV Ckt-1',
            type: 'DA+3',
            worst: 'critical',
            defects: 12),
      );

      expect(find.text('T-147'), findsOneWidget);
      expect(find.text('Critical'), findsOneWidget); // word, never colour alone
      expect(find.text('12 defects'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a queued row is marked pending, a synced row is not',
        (tester) async {
      await pumpTile(tester, _s(-3, '2026-07-29')); // negative id = in outbox
      expect(find.text('Pending'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await pumpTile(tester, _s(12, '2026-07-29'));
      expect(find.text('Pending'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a colleague\'s row names who captured it', (tester) async {
      final s = _s(1, '2026-07-29',
          tower: '147', line: 'Kurnool - Nandyal 220kV Ckt-1', type: 'DA+3');
      await pumpTile(tester, s, isMine: false);

      // Attribution takes the tower type's slot rather than widening the row.
      expect(find.text('AEE1'), findsOneWidget);
      expect(find.text('DA+3'), findsNothing);
      expect(tester.takeException(), isNull);

      await pumpTile(tester, s); // isMine: true
      expect(find.text('AEE1'), findsNothing);
      expect(find.text('DA+3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a row with no line name still lays out', (tester) async {
      await pumpTile(tester, _s(1, '2026-07-29', line: '', type: ''));
      expect(find.text('T-1'), findsOneWidget);
      expect(find.text('No defects'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('tapping the row reports the tap once', (tester) async {
      var taps = 0;
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: buildLiTheme(),
        home: Scaffold(
          body: InspectionHistoryTile(
            summary: _s(1, '2026-07-29'),
            onTap: () => taps++,
          ),
        ),
      ));
      await tester.tap(find.text('T-1'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });
}
