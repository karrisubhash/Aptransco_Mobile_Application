import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/models/li_asset.dart';
import 'package:drone_inspection_app/widgets/inspect_launcher.dart';

/// Tower lists are oversight-scoped and wider than the capture scope the server
/// enforces on submit, so a visible tower is not necessarily one this inspector
/// may save against. An employee with no role assignments sees their whole
/// subtree and could inspect none of it: every form they filled in queued, then
/// failed at sync with 403 "You don't have jurisdiction over this tower."
///
/// These pin the gate that refuses the form up front instead.
LiTower _tower({required bool canInspect}) => LiTower(
      id: 467,
      towerNumber: '14',
      towerType: 'DA+0',
      voltage: '132KV',
      lineName: '132KV Bommuru- Mallayyapeta DC Line (P), Ckt-1',
      latitude: 17.0,
      longitude: 81.8,
      lineId: 79,
      subdivisionName: 'Rajahmundry',
      canInspect: canInspect,
    );

void main() {
  group('LiTower.canInspect parsing', () {
    test('reads the server flag', () {
      expect(
        LiTower.fromJson({'id': 1, 'can_inspect': false}).canInspect,
        isFalse,
      );
      expect(
        LiTower.fromJson({'id': 1, 'can_inspect': true}).canInspect,
        isTrue,
      );
    });

    test('defaults to true when the field is absent', () {
      // A tower list cached before the server sent the flag must keep working
      // offline; the server stays the authority on submit.
      expect(LiTower.fromJson({'id': 1}).canInspect, isTrue);
    });
  });

  group('launchInspection jurisdiction gate', () {
    testWidgets('refuses a tower outside the capture scope', (tester) async {
      bool? opened;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                opened = await launchInspection(
                  context,
                  tower: _tower(canInspect: false),
                  inspectorEmployeeId: '01019688',
                );
              },
              child: const Text('Inspect'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Inspect'));
      await tester.pumpAndSettle();

      // Explains the situation and names who can fix it, rather than just
      // refusing — and never reaches the GPS fix or the catalog fetch.
      expect(find.text('Not your tower to inspect'), findsOneWidget);
      expect(find.textContaining('Ask your EE to assign you this line'),
          findsOneWidget);
      expect(find.textContaining('Tower 14'), findsOneWidget);

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      expect(opened, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an inspectable tower is not blocked by the gate',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              // Deliberately not awaited: past the gate this reaches the GPS
              // fix and the catalog fetch, which this test does not stand up.
              onPressed: () => launchInspection(
                context,
                tower: _tower(canInspect: true),
                inspectorEmployeeId: '01019688',
              ),
              child: const Text('Inspect'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Inspect'));
      await tester.pump();

      expect(find.text('Not your tower to inspect'), findsNothing);
    });
  });
}
