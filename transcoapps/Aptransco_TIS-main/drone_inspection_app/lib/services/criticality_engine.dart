import '../models/inspection_catalog.dart';

/// Criticality ordering, worst-of, and the tower-type gating rule — the small
/// amount of business logic the adaptive form needs, ported from the POC and
/// made data-driven off the server catalog's [CriticalityRule]s.
class CriticalityEngine {
  const CriticalityEngine._();

  /// Severity order. `none` = not inspected (UI only).
  static const Map<String, int> order = {
    'none': 0,
    'ok': 1,
    'minor': 2,
    'major': 3,
    'critical': 4,
  };

  static const Map<String, String> label = {
    'ok': 'Normal',
    'minor': 'Minor',
    'major': 'Major',
    'critical': 'Critical',
    'none': 'Not inspected',
  };

  /// The worst (highest) criticality in [list], or 'ok' if empty.
  static String worstOf(Iterable<String> list) {
    var worst = 'ok';
    for (final c in list) {
      if ((order[c] ?? 0) > (order[worst] ?? 0)) worst = c;
    }
    return worst;
  }

  /// Suggested criticality for [defect] given [answers], evaluating the
  /// catalog rules in priority order (first match wins) and falling back to the
  /// defect's default. Mirrors the POC's `critRule`.
  static String suggestedCriticality(
    Defect defect,
    Map<String, dynamic> answers,
    List<CriticalityRule> allRules,
  ) {
    final rules = allRules.where((r) => r.defectKey == defect.key).toList()
      ..sort((a, b) => a.priority.compareTo(b.priority));
    for (final r in rules) {
      if (!answers.containsKey(r.followUpKey)) continue;
      final v = answers[r.followUpKey];
      if (v == null || v == '') continue;
      if (_matches(v, r.operator, r.thresholdValue)) {
        return r.resultingCriticality;
      }
    }
    return defect.defaultCriticality;
  }

  static bool _matches(dynamic value, String op, dynamic threshold) {
    switch (op) {
      case 'eq':
        return _eq(value, threshold);
      case 'neq':
        return !_eq(value, threshold);
      case 'gte':
        return _cmp(value, threshold, (a, b) => a >= b);
      case 'lte':
        return _cmp(value, threshold, (a, b) => a <= b);
      case 'gt':
        return _cmp(value, threshold, (a, b) => a > b);
      case 'lt':
        return _cmp(value, threshold, (a, b) => a < b);
      default:
        return false;
    }
  }

  static bool _eq(dynamic a, dynamic b) => a.toString() == b.toString();

  static bool _cmp(dynamic a, dynamic b, bool Function(num, num) f) {
    final na = _num(a), nb = _num(b);
    if (na == null || nb == null) return false;
    return f(na, nb);
  }

  static num? _num(dynamic x) =>
      x is num ? x : num.tryParse(x.toString());

  /// Whether [item] applies to a tower of [towerType].
  ///
  /// The catalog gates only the D-series double-circuit towers (codes like
  /// `DA`, `DB`, `DC`, `DD`), while real tower types carry a body-extension
  /// suffix (e.g. `DA+0`, `DB+3`). Matching is therefore by prefix. Crucially,
  /// a tower that is NOT in the gated (D-series) family at all — `A+0`, `P+0`,
  /// `S+0`, `Boom`, ... — is treated as applicable rather than forced to N/A,
  /// so no item is ever silently un-inspectable on the bulk of real towers.
  ///
  /// NOTE: this gating scheme needs confirmation against APTRANSCO tower
  /// nomenclature; it is intentionally permissive until then.
  static bool itemApplies(ChecklistItem item, String towerType) {
    final types = item.applicableTowerTypes;
    if (types.isEmpty) return true;
    final tt = towerType.toUpperCase().trim();
    for (final code in types) {
      if (tt.startsWith(code.toUpperCase())) return true;
    }
    // No direct match. If the gate discriminates within the D-series and this
    // tower is a D-series tower, it's genuinely out of scope -> N/A. Otherwise
    // the tower is outside the gate's family -> show it (permissive default).
    final gateIsDSeries =
        types.every((c) => c.toUpperCase().startsWith('D'));
    final towerIsDSeries = tt.startsWith('D');
    if (gateIsDSeries && towerIsDSeries) return false;
    return true;
  }
}
