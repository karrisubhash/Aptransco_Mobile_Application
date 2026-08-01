import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/widgets/inspect_launcher.dart';

/// The presence-override dialog carries a TextEditingController for the
/// mandatory reason. It used to be disposed the instant `showDialog` resolved —
/// while the TextField was still mounted for the route's exit transition, and
/// before focus was handed back — so dismissing the dialog used the controller
/// after disposal and dropped the inspector on the red error screen.
///
/// Cancel is the routine path (wrong tower tapped, inspector decides to walk
/// closer first), so these pin it.
Widget _host(void Function(String?) onResult) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async => onResult(await askPresenceOverride(
              context,
              flag: 'out_of_range',
              distance: 320,
            )),
            child: const Text('Inspect'),
          ),
        ),
      ),
    );

void main() {
  group('askPresenceOverride', () {
    testWidgets('cancelling closes cleanly and reports no reason',
        (tester) async {
      String? reason;
      var returned = false;

      await tester.pumpWidget(_host((r) {
        reason = r;
        returned = true;
      }));

      await tester.tap(find.text('Inspect'));
      await tester.pumpAndSettle();
      expect(find.text('Presence check'), findsOneWidget);
      expect(find.textContaining('320 m from this tower'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(returned, isTrue);
      expect(reason, isNull, reason: 'cancel must not authorise an override');
      expect(find.text('Presence check'), findsNothing);
    });

    testWidgets('a reason is mandatory, and comes back trimmed',
        (tester) async {
      String? reason;

      await tester.pumpWidget(_host((r) => reason = r));

      await tester.tap(find.text('Inspect'));
      await tester.pumpAndSettle();

      // Empty is refused: the dialog stays put rather than recording a blank
      // override on an out-of-range inspection.
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Presence check'), findsOneWidget);
      expect(reason, isNull);

      await tester.enterText(
          find.byType(TextField), '  GPS not locking under the tower  ');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(reason, 'GPS not locking under the tower');
    });
  });
}
