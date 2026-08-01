"""Tower inspection-status helpers for the Phase 3 dashboard.

Status = the worst_criticality of a tower's most recent Inspection ('none' if
never inspected). The Tower model carries a denormalized cache
(last_inspection_at / last_worst_criticality / last_inspection_type), maintained
on inspection create by bump_tower_cache() below — the map and rollups read that
cache directly and avoid any per-tower subquery across ~67k towers.
latest_inspection_status() recomputes from the Inspection table (source of truth,
used to warm the cache and by tests), with an optional inspection_type filter for
the twice-yearly Ground-Patrol vs PMI cycles. STATUS_COLORS matches the POC
colour coding so map markers, legend, and rollup bars all agree.
"""
from .models import Inspection, WORST_CHOICES

# POC colour coding (gisdata/clearpoc.html). Single source so map/legend/rollup match.
STATUS_COLORS = {
    'none': '#898781',
    'ok': '#0ca30c',
    'minor': '#fab219',
    'major': '#ec835a',
    'critical': '#d03b3b',
}

STATUS_LABELS = dict(WORST_CHOICES)


def latest_inspection_status(tower_ids, inspection_type=None):
    """{tower_id: worst_criticality} for the latest inspection of each tower.
    Towers with no matching inspection are omitted (callers treat missing as
    'none'). One query, latest-per-tower via Postgres DISTINCT ON over the
    existing (tower, saved_at) index. inspection_type ('ground_patrol'/'pmi')
    narrows to the latest of that cycle only; None = latest of any type."""
    tower_ids = list(tower_ids)
    if not tower_ids:
        return {}
    qs = Inspection.objects.filter(tower_id__in=tower_ids)
    if inspection_type:
        qs = qs.filter(inspection_type=inspection_type)
    rows = (
        qs.order_by('tower_id', '-saved_at', '-id')
        .distinct('tower_id')
        .values_list('tower_id', 'worst_criticality')
    )
    return dict(rows)


def latest_inspections(tower_ids, inspection_type=None):
    """{tower_id: Inspection} for the latest inspection of each tower, with
    item results / defect entries / follow-ups prefetched for the register
    matrix. Postgres DISTINCT ON over the (tower, saved_at) index. Companion to
    latest_inspection_status (which returns only the criticality). inspection_type
    ('ground_patrol'/'pmi') narrows to a cycle; None = latest of any type."""
    tower_ids = list(tower_ids)
    if not tower_ids:
        return {}
    qs = Inspection.objects.filter(tower_id__in=tower_ids)
    if inspection_type:
        qs = qs.filter(inspection_type=inspection_type)
    latest = (
        qs.order_by('tower_id', '-saved_at', '-id')
        .distinct('tower_id')
        .prefetch_related('item_results__item', 'item_results__entries__defect')
    )
    return {insp.tower_id: insp for insp in latest}


def bump_tower_cache(tower, saved_at, worst_criticality, inspection_type):
    """Advance a Tower's denormalized status cache to reflect an inspection,
    but only if it is newer than what's already stored (so a late-arriving older
    inspection never regresses the cache). Called inside the inspection-create
    transaction; writes just the three cache columns."""
    if tower.last_inspection_at and saved_at and saved_at < tower.last_inspection_at:
        return
    tower.last_inspection_at = saved_at
    tower.last_worst_criticality = worst_criticality
    tower.last_inspection_type = inspection_type
    tower.save(update_fields=['last_inspection_at', 'last_worst_criticality', 'last_inspection_type'])
