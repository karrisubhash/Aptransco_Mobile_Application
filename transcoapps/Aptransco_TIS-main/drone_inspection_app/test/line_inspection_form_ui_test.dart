import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drone_inspection_app/models/inspection_catalog.dart';
import 'package:drone_inspection_app/models/li_asset.dart';
import 'package:drone_inspection_app/screens/line_inspection_form_screen.dart';
import 'package:drone_inspection_app/utils/li_theme.dart';

/// UI-layer regression tests for the inspection form.
///
/// The group label and the gated three-option status control below are the real
/// worst case from the seeded catalog — "Suspension / tension hardware" is the
/// longest group label, and an availability-gated non-positional item renders
/// the widest control ("Not available | Normal | Defect"). Together on a 360dp
/// phone they used to overflow, because the status control was a single
/// un-splittable Row inside a Wrap and the section header did not let its title
/// yield. Any RenderFlex overflow fails these tests.
const _catalogJson = '''
{
  "version": 9,
  "criticality_rules": [],
  "groups": [
    {"id": 4, "key": "hardware", "label": "Suspension / tension hardware",
     "sort_order": 1,
     "items": [
       {"id": 31, "key": "arcing_horn", "sno": 12,
        "label": "Arcing horn / grading ring condition",
        "sort_order": 1, "group_key": "hardware", "positions": [],
        "pos_meta": null, "is_availability_gated": true,
        "is_position_availability_gated": false,
        "applicable_tower_types": [], "na_reason": "",
        "defects": [
          {"id": 41, "key": "horn_missing", "label": "Missing",
           "ask": [], "default_criticality": "major"}
        ]}
     ]}
  ],
  "follow_up_questions": []
}
''';

const _tower = LiTower(
  id: 5,
  towerNumber: '47',
  towerType: 'DA+3',
  voltage: '220kV',
  lineName: 'Kurnool - Nandyal 220kV Ckt-1',
  latitude: 15.8,
  longitude: 78.0,
  lineId: 2,
  subdivisionName: 'Nandyal',
);

InspectionCatalog _catalog() =>
    InspectionCatalog.fromJson(jsonDecode(_catalogJson) as Map<String, dynamic>);

Widget _app() => MaterialApp(
      theme: buildLiTheme(),
      home: LineInspectionFormScreen(
        tower: _tower,
        catalog: _catalog(),
        inspectorEmployeeId: '12345',
      ),
    );

/// Renders at a small-phone *width*, which is what makes horizontal overflow
/// reachable. The viewport is deliberately tall so every card is laid out and
/// findable without scrolling — the lazy ListView would otherwise skip the
/// remarks card entirely.
Future<void> _pumpNarrow(WidgetTester tester) async {
  tester.view.physicalSize = const Size(360, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  group('inspection form layout', () {
    testWidgets('renders the register header on a 360dp phone', (tester) async {
      await _pumpNarrow(tester);

      expect(find.text('Inspect Tower 47'), findsOneWidget);
      expect(find.text('Suspension / tension hardware'), findsOneWidget);
      // The numbered register fields survive the restyle.
      expect(find.text('Date of inspection  '), findsOneWidget);
      expect(find.text('Loc No  '), findsOneWidget);
      expect(find.text('Type of tower  '), findsOneWidget);
      expect(find.text('DA+3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expands a group and lays out the three-option control without '
        'overflowing', (tester) async {
      await _pumpNarrow(tester);

      await tester.tap(find.text('Suspension / tension hardware'));
      await tester.pumpAndSettle();

      // All three segments are laid out and legible.
      expect(find.text('Not available'), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      expect(find.text('Defect'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the status segments share the row width equally',
        (tester) async {
      await _pumpNarrow(tester);
      await tester.tap(find.text('Suspension / tension hardware'));
      await tester.pumpAndSettle();

      final np = tester.getSize(find.text('Not available'));
      final normal = tester.getSize(find.text('Normal'));
      final defect = tester.getSize(find.text('Defect'));

      // Equal-flex segments: every label gets the same slice, so no option is
      // harder to hit than another.
      expect(np.width, greaterThan(0));
      expect((normal.width - defect.width).abs(), lessThan(1.0));
      expect(np.height, normal.height);
    });
  });

  group('unsaved-work guard', () {
    testWidgets('a fresh form leaves without prompting', (tester) async {
      await _pumpNarrow(tester);

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Discard this inspection?'), findsNothing);
    });

    testWidgets('a form with a defect marked asks before discarding',
        (tester) async {
      await _pumpNarrow(tester);
      await tester.tap(find.text('Suspension / tension hardware'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Defect'));
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Discard this inspection?'), findsOneWidget);

      // Choosing to stay keeps the inspection on screen.
      await tester.tap(find.text('Keep inspecting'));
      await tester.pumpAndSettle();

      expect(find.text('Discard this inspection?'), findsNothing);
      expect(find.text('Inspect Tower 47'), findsOneWidget);
    });

    testWidgets('typed remarks alone are enough to prompt', (tester) async {
      await _pumpNarrow(tester);

      await tester.enterText(
          find.widgetWithText(TextFormField, 'Remarks (optional)'),
          'Access road washed out');
      await tester.pumpAndSettle();

      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      navigator.maybePop();
      await tester.pumpAndSettle();

      expect(find.text('Discard this inspection?'), findsOneWidget);
    });
  });
}
