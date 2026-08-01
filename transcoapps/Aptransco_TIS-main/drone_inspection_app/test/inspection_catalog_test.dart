import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drone_inspection_app/models/inspection_catalog.dart';

/// The catalog body shape served by `GET /api/catalog/`. `follow_up_questions[]`
/// historically omitted `id`, which made the form fail to open with
/// "type 'Null' is not a subtype of type 'int' in type cast".
const _catalogJson = '''
{
  "version": 7,
  "criticality_rules": [
    {"defect_key": "disc_broken", "follow_up_key": "disc_count",
     "operator": "gte", "threshold_value": 2,
     "resulting_criticality": "critical", "priority": 1}
  ],
  "groups": [
    {"id": 3, "key": "tower_parts", "label": "Tower parts", "sort_order": 1,
     "items": [
       {"id": 11, "key": "members_bent", "sno": 5, "label": "Members bent",
        "sort_order": 1, "group_key": "tower_parts", "positions": [],
        "pos_meta": null, "is_availability_gated": false,
        "is_position_availability_gated": false,
        "applicable_tower_types": [], "na_reason": "",
        "defects": [
          {"id": 21, "key": "disc_broken", "label": "Disc broken",
           "ask": ["disc_count"], "default_criticality": "major"}
        ]}
     ]}
  ],
  "follow_up_questions": [
    {"key": "disc_count", "question_text": "How many discs?",
     "answer_type": "number", "options": [], "unit": "nos", "placeholder": ""}
  ]
}
''';

void main() {
  group('InspectionCatalog.fromJson', () {
    test('parses a catalog whose follow-up questions carry no id', () {
      final catalog = InspectionCatalog.fromJson(
          jsonDecode(_catalogJson) as Map<String, dynamic>);

      expect(catalog.version, 7);
      expect(catalog.groups.single.items.single.key, 'members_bent');
      expect(catalog.followUps.containsKey('disc_count'), isTrue);
      expect(catalog.followUps['disc_count']!.isNumber, isTrue);
      expect(catalog.criticalityRules.single.resultingCriticality, 'critical');
    });

    test('keeps the id when the server does send it', () {
      final body = jsonDecode(_catalogJson) as Map<String, dynamic>;
      (body['follow_up_questions'] as List).first['id'] = 42;

      final catalog = InspectionCatalog.fromJson(body);

      expect(catalog.followUps['disc_count']!.id, 42);
    });

    test('names the offending record when an item id really is missing', () {
      final body = jsonDecode(_catalogJson) as Map<String, dynamic>;
      (body['groups'] as List).first['items'][0].remove('id');

      expect(
        () => InspectionCatalog.fromJson(body),
        throwsA(isA<FormatException>().having(
            (e) => e.message, 'message', contains('item "members_bent"'))),
      );
    });
  });
}
