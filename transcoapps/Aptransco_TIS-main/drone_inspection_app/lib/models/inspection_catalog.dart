/// Data model for the APTRANSCO line-inspection questionnaire catalog, served
/// by `GET /api/catalog/` (backed by the PostgreSQL `clear` schema).
///
/// The catalog is version-stamped; the app caches it and only re-parses when
/// the version changes. Everything the adaptive inspection form renders — the
/// item groups, the per-item defects, the follow-up question bank, and the
/// declarative criticality rules — comes from here rather than being hardcoded,
/// because the server catalog evolves independently of the app.
library;

/// Reads an identifier the form genuinely cannot work without (they key the
/// draft maps and are posted back as `item_id` / `defect_id`, so defaulting
/// them would silently mix up answers). Fails with the field named rather than
/// a bare "'Null' is not a subtype of 'int'" cast error.
int _requiredId(Map<String, dynamic> j, String what) {
  final v = j['id'];
  if (v is num) return v.toInt();
  throw FormatException("Catalog $what is missing its 'id' (got $v)");
}

/// A single follow-up question (the "ask" chain of a defect references these
/// by [key]).
class FollowUpQuestion {
  final int id;
  final String key;
  final String questionText;
  final String answerType; // choice | multichoice | number | text
  final List<String> options;
  final String unit;
  final String placeholder;

  const FollowUpQuestion({
    required this.id,
    required this.key,
    required this.questionText,
    required this.answerType,
    required this.options,
    required this.unit,
    required this.placeholder,
  });

  factory FollowUpQuestion.fromJson(Map<String, dynamic> j) => FollowUpQuestion(
        // Follow-ups are looked up by `key`; the id is informational only, so a
        // catalog that omits it must not stop the form from opening.
        id: (j['id'] as num?)?.toInt() ?? 0,
        key: j['key'] as String? ?? '',
        questionText: j['question_text'] as String? ?? '',
        answerType: j['answer_type'] as String? ?? 'text',
        options: (j['options'] as List?)?.map((e) => e.toString()).toList() ??
            const [],
        unit: j['unit'] as String? ?? '',
        placeholder: j['placeholder'] as String? ?? '',
      );

  bool get isChoice => answerType == 'choice';
  bool get isMultiChoice => answerType == 'multichoice';
  bool get isNumber => answerType == 'number';
  bool get isText => answerType == 'text';
}

/// A declarative rule that maps a follow-up answer to a criticality. Evaluated
/// in [priority] order (first match wins), falling back to the defect's
/// `default_criticality`. See CriticalityEngine.
class CriticalityRule {
  final String defectKey;
  final String followUpKey;
  final String operator; // eq | neq | gte | lte | gt | lt
  final dynamic thresholdValue; // num or String (from jsonb)
  final String resultingCriticality;
  final int priority;

  const CriticalityRule({
    required this.defectKey,
    required this.followUpKey,
    required this.operator,
    required this.thresholdValue,
    required this.resultingCriticality,
    required this.priority,
  });

  factory CriticalityRule.fromJson(Map<String, dynamic> j) => CriticalityRule(
        defectKey: j['defect_key'] as String? ?? '',
        followUpKey: j['follow_up_key'] as String? ?? '',
        operator: j['operator'] as String? ?? 'eq',
        thresholdValue: j['threshold_value'],
        resultingCriticality: j['resulting_criticality'] as String? ?? 'minor',
        priority: j['priority'] as int? ?? 0,
      );
}

/// One defect that can be recorded against a checklist item.
class Defect {
  final int id;
  final String key;
  final String label;
  final int sortOrder;
  final List<String> ask; // ordered follow-up keys
  final String defaultCriticality;

  const Defect({
    required this.id,
    required this.key,
    required this.label,
    required this.sortOrder,
    required this.ask,
    required this.defaultCriticality,
  });

  factory Defect.fromJson(Map<String, dynamic> j) => Defect(
        id: _requiredId(j, 'defect "${j['key']}"'),
        key: j['key'] as String? ?? '',
        label: j['label'] as String? ?? '',
        sortOrder: j['sort_order'] as int? ?? 0,
        ask: (j['ask'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        defaultCriticality: j['default_criticality'] as String? ?? 'minor',
      );
}

/// Optional per-position dropdown attached to a positional item (e.g. the
/// insulator "Type of insulator" select).
class PosMeta {
  final String id;
  final String label;
  final String defaultValue;
  final List<String> options;

  const PosMeta({
    required this.id,
    required this.label,
    required this.defaultValue,
    required this.options,
  });

  static PosMeta? fromJson(Map<String, dynamic>? j) {
    if (j == null) return null;
    return PosMeta(
      id: j['id'] as String? ?? '',
      label: j['label'] as String? ?? '',
      defaultValue: j['default'] as String? ?? '',
      options:
          (j['options'] as List?)?.map((e) => e.toString()).toList() ?? const [],
    );
  }
}

/// A checklist line item within a group.
class ChecklistItem {
  final int id;
  final String key;
  final int sno;
  final String label;
  final int sortOrder;

  /// Positions recorded separately (e.g. Top/Middle/Bottom). Empty for a plain
  /// single-status item.
  final List<String> positions;
  final PosMeta? posMeta;

  /// If true the item first asks Available / Not available (defaults to Not
  /// available) before its condition is recorded.
  final bool isAvailabilityGated;

  /// If true each position independently starts Not available.
  final bool isPositionAvailabilityGated;

  /// Tower types this item applies to. Empty = applies to all. See
  /// CriticalityEngine.itemApplies for how the (D-series) codes are matched
  /// against real tower types like "DA+0".
  final List<String> applicableTowerTypes;
  final String naReason;
  final String groupKey;
  final List<Defect> defects;

  const ChecklistItem({
    required this.id,
    required this.key,
    required this.sno,
    required this.label,
    required this.sortOrder,
    required this.positions,
    required this.posMeta,
    required this.isAvailabilityGated,
    required this.isPositionAvailabilityGated,
    required this.applicableTowerTypes,
    required this.naReason,
    required this.groupKey,
    required this.defects,
  });

  bool get hasPositions => positions.isNotEmpty;

  factory ChecklistItem.fromJson(Map<String, dynamic> j) => ChecklistItem(
        id: _requiredId(j, 'item "${j['key']}"'),
        key: j['key'] as String? ?? '',
        sno: j['sno'] as int? ?? 0,
        label: j['label'] as String? ?? '',
        sortOrder: j['sort_order'] as int? ?? 0,
        positions:
            (j['positions'] as List?)?.map((e) => e.toString()).toList() ??
                const [],
        posMeta: PosMeta.fromJson(j['pos_meta'] as Map<String, dynamic>?),
        isAvailabilityGated: j['is_availability_gated'] as bool? ?? false,
        isPositionAvailabilityGated:
            j['is_position_availability_gated'] as bool? ?? false,
        applicableTowerTypes: (j['applicable_tower_types'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        naReason: j['na_reason'] as String? ?? '',
        groupKey: j['group_key'] as String? ?? '',
        defects: (j['defects'] as List?)
                ?.map((e) => Defect.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );

  Defect? defectByKey(String key) {
    for (final d in defects) {
      if (d.key == key) return d;
    }
    return null;
  }

  Defect? defectById(int id) {
    for (final d in defects) {
      if (d.id == id) return d;
    }
    return null;
  }
}

/// A group of checklist items (e.g. "Coping & foundation").
class ChecklistGroup {
  final int id;
  final String key;
  final String label;
  final int sortOrder;
  final List<ChecklistItem> items;

  const ChecklistGroup({
    required this.id,
    required this.key,
    required this.label,
    required this.sortOrder,
    required this.items,
  });

  factory ChecklistGroup.fromJson(Map<String, dynamic> j) => ChecklistGroup(
        id: _requiredId(j, 'group "${j['key']}"'),
        key: j['key'] as String? ?? '',
        label: j['label'] as String? ?? '',
        sortOrder: j['sort_order'] as int? ?? 0,
        items: (j['items'] as List?)
                ?.map((e) => ChecklistItem.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const [],
      );
}

/// The whole questionnaire catalog.
class InspectionCatalog {
  final int version;
  final List<ChecklistGroup> groups;
  final Map<String, FollowUpQuestion> followUps; // by key
  final List<CriticalityRule> criticalityRules;

  const InspectionCatalog({
    required this.version,
    required this.groups,
    required this.followUps,
    required this.criticalityRules,
  });

  factory InspectionCatalog.fromJson(Map<String, dynamic> j) {
    final fus = <String, FollowUpQuestion>{};
    for (final e in (j['follow_up_questions'] as List? ?? const [])) {
      final fu = FollowUpQuestion.fromJson(e as Map<String, dynamic>);
      fus[fu.key] = fu;
    }
    return InspectionCatalog(
      version: j['version'] as int? ?? 0,
      groups: (j['groups'] as List? ?? const [])
          .map((e) => ChecklistGroup.fromJson(e as Map<String, dynamic>))
          .toList(),
      followUps: fus,
      criticalityRules: (j['criticality_rules'] as List? ?? const [])
          .map((e) => CriticalityRule.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// All items across all groups (flat), in inspection order.
  Iterable<ChecklistItem> get allItems =>
      groups.expand((g) => g.items);
}
