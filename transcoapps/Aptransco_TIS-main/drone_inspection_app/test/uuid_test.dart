import 'package:flutter_test/flutter_test.dart';
import 'package:drone_inspection_app/utils/uuid.dart';

void main() {
  final v4Pattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  test('generates well-formed version-4 UUIDs', () {
    for (int i = 0; i < 100; i++) {
      final uuid = generateUuidV4();
      expect(uuid, matches(v4Pattern), reason: 'malformed UUID: $uuid');
    }
  });

  test('does not repeat', () {
    final seen = {for (int i = 0; i < 1000; i++) generateUuidV4()};
    expect(seen.length, 1000);
  });
}
