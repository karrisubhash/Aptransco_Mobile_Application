"""Evaluates a Defect's CriticalityRule rows against submitted answers —
the data-driven replacement for the POC's hardcoded critRule() JS
functions. First matching rule (by priority) wins; falls back to
Defect.default_criticality."""


def _coerce_for_compare(value, threshold):
    if isinstance(threshold, (int, float)) and not isinstance(threshold, bool):
        try:
            return float(value)
        except (TypeError, ValueError):
            return None
    return value


def _rule_matches(rule, answers):
    value = answers.get(rule.follow_up_key)
    if value is None:
        return False
    threshold = rule.threshold_value

    if rule.operator == 'gte':
        coerced = _coerce_for_compare(value, threshold)
        return coerced is not None and coerced >= float(threshold)
    if rule.operator == 'lte':
        coerced = _coerce_for_compare(value, threshold)
        return coerced is not None and coerced <= float(threshold)
    if rule.operator == 'eq':
        return value == threshold
    if rule.operator == 'in':
        return value in (threshold if isinstance(threshold, list) else [threshold])
    if rule.operator == 'contains_any':
        values = value if isinstance(value, list) else [value]
        return bool(set(values) & set(threshold or []))
    if rule.operator == 'contains_all':
        values = set(value if isinstance(value, list) else [value])
        return set(threshold or []).issubset(values)
    return False


def suggest_criticality(defect, answers):
    for rule in defect.criticality_rules.all():
        if _rule_matches(rule, answers):
            return rule.resulting_criticality
    return defect.default_criticality


CRITICALITY_ORDER = {'none': 0, 'ok': 1, 'minor': 2, 'major': 3, 'critical': 4}


def worst_of(criticalities):
    worst = 'ok'
    for c in criticalities:
        if CRITICALITY_ORDER.get(c, 0) > CRITICALITY_ORDER.get(worst, 0):
            worst = c
    return worst
