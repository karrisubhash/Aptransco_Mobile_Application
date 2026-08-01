// Basic smoke test ensuring the app boots without throwing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/main.dart';

void main() {
  testWidgets('App boots to the line-inspection login screen', (WidgetTester tester) async {
    // main() now kicks the offline-layer boot off behind the first frame and
    // hands the future down; nothing here needs that layer, so a completed
    // future stands in for it.
    await tester.pumpWidget(AptranscoApp(boot: Future<void>.value()));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
