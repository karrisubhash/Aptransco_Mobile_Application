"""LILO reconcile — matching surviving physical towers across an ArcGIS
object_id churn, plus detecting *undeclared* churn.

A physical tower keeps its coordinates through a LILO (or a slight road-works
shift), so coordinates are the durable identity; `tower_number` equality and
old-line lineage corroborate. Nothing here is trusted to auto-merge on its own
beyond a high-confidence threshold — the Super-Admin reconcile screen reviews
everything else. Used ONLY by the on-demand reconcile / detector; NEVER by the
routine ArcGIS sync.
"""
import math
from collections import defaultdict

from django.db.models import Q, Exists, OuterRef

from ..models import Tower, Inspection, LineTowerAssignment

_M_PER_DEG_LAT = 110_574.0
_M_PER_DEG_LON_EQ = 111_320.0

# Thresholds (metres)
AUTO_EXACT_M = 5.0      # near-identical coords -> auto-accept the match
AUTO_NUMBER_M = 60.0    # moderate move but SAME tower_number -> auto-accept
CANDIDATE_M = 250.0     # farthest an old tower may be to even be a manual candidate
CHURN_M = 30.0          # co-location radius for the "stranded history" detector


def distance_m(lat1, lng1, lat2, lng2):
    """Planar (equirectangular) metres between two lat/lng — accurate enough for
    matching towers a few metres to a few hundred metres apart."""
    if None in (lat1, lng1, lat2, lng2):
        return None
    cos_lat = math.cos(math.radians((lat1 + lat2) / 2.0))
    dx = (lng1 - lng2) * _M_PER_DEG_LON_EQ * cos_lat
    dy = (lat1 - lat2) * _M_PER_DEG_LAT
    return math.hypot(dx, dy)


def _norm_number(tower_number):
    return (tower_number or '').strip().upper().replace(' ', '')


def _is_auto(dist, number_match):
    return dist is not None and (dist <= AUTO_EXACT_M or (dist <= AUTO_NUMBER_M and number_match))


def _old_towers_for(event):
    """Deactivated towers that belonged to the pre-LILO line (by FK or name) —
    the churned-away rows whose identity/history we want to preserve."""
    old_line = event.old_line
    return list(Tower.objects.filter(is_active=False)
                .filter(Q(line=old_line) | Q(line_name=old_line.name)))


def _new_towers_for(event):
    """Active towers on the post-LILO line(s) — the freshly-created rows."""
    new_line_ids = list(event.new_lines.values_list('id', flat=True))
    return list(Tower.objects.filter(line_id__in=new_line_ids, is_active=True))


def propose_matches(event):
    """Propose, for a LiloEvent, how each NEW tower maps to a surviving OLD tower.

    Returns {'pairs': [...], 'unmatched_old': [...], 'counts': {...}}. Each pair:
      {new_tower, old_tower (suggested/None), distance_m, number_match,
       method: 'auto'|'review'|'new', candidates: [{old_tower, distance_m, number_match}...]}
    'auto' = high-confidence (apply as-is); 'review' = operator must confirm the
    suggestion or override; 'new' = genuinely new tower (no old match)."""
    new_towers = _new_towers_for(event)
    old_towers = _old_towers_for(event)

    old_geo = [o for o in old_towers if o.latitude is not None and o.longitude is not None]

    # candidate old towers per new tower, nearest first
    per_new = {}
    for n in new_towers:
        cands = []
        if n.latitude is not None and n.longitude is not None:
            for o in old_geo:
                d = distance_m(n.latitude, n.longitude, o.latitude, o.longitude)
                if d is None or d > CANDIDATE_M:
                    continue
                nm = bool(_norm_number(n.tower_number)) and _norm_number(n.tower_number) == _norm_number(o.tower_number)
                cands.append({'old_tower': o, 'distance_m': d, 'number_match': nm})
            # Prefer a same-tower_number candidate (a surviving tower keeps its
            # number in a LILO), then nearest — this is the *review suggestion*
            # ordering; auto-accept (below) stays purely distance-based.
            cands.sort(key=lambda c: (not c['number_match'], c['distance_m']))
        per_new[n.id] = cands

    # greedy one-to-one auto assignment, globally nearest first (key by distance
    # only; never compare the model objects in the tuple)
    auto_candidates = sorted(
        ((c['distance_m'], n.id, n, c) for n in new_towers for c in per_new[n.id]
         if _is_auto(c['distance_m'], c['number_match'])),
        key=lambda x: x[0],
    )
    assigned_new, assigned_old = {}, set()
    for dist, _nid, n, c in auto_candidates:
        if n.id in assigned_new or c['old_tower'].id in assigned_old:
            continue
        assigned_new[n.id] = c
        assigned_old.add(c['old_tower'].id)

    pairs = []
    for n in new_towers:
        if n.id in assigned_new:
            c = assigned_new[n.id]
            pairs.append({'new_tower': n, 'old_tower': c['old_tower'], 'distance_m': round(c['distance_m'], 1),
                          'number_match': c['number_match'], 'method': 'auto', 'candidates': []})
            continue
        free = [c for c in per_new[n.id] if c['old_tower'].id not in assigned_old]
        if free:
            best = free[0]
            pairs.append({'new_tower': n, 'old_tower': best['old_tower'], 'distance_m': round(best['distance_m'], 1),
                          'number_match': best['number_match'], 'method': 'review',
                          'candidates': [{'old_tower': c['old_tower'], 'distance_m': round(c['distance_m'], 1),
                                          'number_match': c['number_match']} for c in free[:5]]})
        else:
            pairs.append({'new_tower': n, 'old_tower': None, 'distance_m': None,
                          'number_match': False, 'method': 'new', 'candidates': []})

    # "unmatched" = old towers with no proposal at all (neither an auto match nor
    # a review suggestion) — e.g. a removed/renumbered tower for the operator to judge.
    used_old = {p['old_tower'].id for p in pairs if p['old_tower'] is not None}
    unmatched_old = [o for o in old_towers if o.id not in used_old]
    counts = {
        'auto': sum(1 for p in pairs if p['method'] == 'auto'),
        'review': sum(1 for p in pairs if p['method'] == 'review'),
        'new': sum(1 for p in pairs if p['method'] == 'new'),
        'unmatched_old': len(unmatched_old),
    }
    return {'pairs': pairs, 'unmatched_old': unmatched_old, 'counts': counts}


# Attributes copied from the fresh NEW row onto the surviving OLD row (line/
# subdivision FKs handled separately). Excludes voltage (unchanged) and the
# denormalized last_* / line_sequence caches (recomputed).
_COPY_FIELDS = [
    'source_layer', 'arcgis_object_id', 'tower_number', 'tower_type', 'line_name',
    'latitude', 'longitude', 'cp_sp', 'tower_ckts_conductor', 'circuit_type', 'circuit_count',
    'conductor_type', 'no_of_conductors_per_phase', 'relay_setting_length_in_km', 'span_km',
    'date_of_commissioning', 'zone', 'circle', 'division', 'subdivision_name', 'geometry', 'raw_properties',
]


def apply_reconcile(event, decisions):
    """Apply confirmed reconcile decisions for a LiloEvent.

    `decisions`: {new_tower_id: old_tower_id or None}. For a match, the surviving
    OLD tower is **revived in place** — its PK (hence inspections / tickets /
    range assignments / history) is kept while it adopts the NEW row's ArcGIS
    attributes; the duplicate NEW row is deleted. For None the NEW row stays a
    genuine new tower. Writes `LiloTowerRemap` audit rows and rebuilds the
    schedule for the event's new lines. Does NOT set `applied_at` — the caller
    does (so a partial CLI apply can leave the event open). Returns counts."""
    from django.db import transaction
    from django.utils import timezone
    from ..models import LiloTowerRemap
    from .. import schedule as sched

    new_by_id = {t.id: t for t in Tower.objects.filter(id__in=list(decisions.keys()))}
    old_by_id = {t.id: t for t in Tower.objects.filter(id__in=[v for v in decisions.values() if v])}
    summary = {'matched': 0, 'new': 0}

    with transaction.atomic(using='line_inspection_db'):
        for new_id, old_id in decisions.items():
            new = new_by_id.get(new_id)
            if new is None:
                continue
            if not old_id:
                LiloTowerRemap.objects.create(event=event, surviving_tower=new, old_object_id='',
                                              new_object_id=new.arcgis_object_id, distance_m=None, method='new')
                summary['new'] += 1
                continue
            old = old_by_id.get(old_id)
            if old is None:
                continue
            dist = distance_m(new.latitude, new.longitude, old.latitude, old.longitude)
            nm = bool(_norm_number(new.tower_number)) and _norm_number(new.tower_number) == _norm_number(old.tower_number)
            method = 'auto' if _is_auto(dist, nm) else 'manual'
            old_obj, new_obj = old.arcgis_object_id, new.arcgis_object_id
            snapshot = {f: getattr(new, f) for f in _COPY_FIELDS}
            new_line_id, new_sub_id = new.line_id, new.subdivision_id
            new.delete()  # free (source_layer, object_id) and drop the duplicate BEFORE adopting it
            for f in _COPY_FIELDS:
                setattr(old, f, snapshot[f])
            old.line_id, old.subdivision_id = new_line_id, new_sub_id
            old.is_active = True
            if old.latitude is not None and old.longitude is not None:
                old.structure_key = f'{old.voltage}:{old.latitude:.5f}:{old.longitude:.5f}'
            old.save()
            LiloTowerRemap.objects.create(event=event, surviving_tower=old, old_object_id=old_obj,
                                          new_object_id=new_obj,
                                          distance_m=round(dist, 1) if dist is not None else None, method=method)
            summary['matched'] += 1

        for line in event.new_lines.all():
            sched.assign_line_sequence(line)
    return summary


def detect_churn(line=None):
    """Deactivated towers that carry inspection history or active range
    assignments AND have a co-located ACTIVE tower (within CHURN_M) — i.e. a
    likely undeclared LILO/shift that would strand history. Read-only; flags
    only. Optionally scoped to one line's deactivated towers.

    Returns [{'stranded': tower, 'twin': tower, 'distance_m': float}]."""
    has_inspection = Inspection.objects.filter(tower=OuterRef('pk'))
    has_assignment = LineTowerAssignment.objects.filter(
        Q(from_tower=OuterRef('pk')) | Q(to_tower=OuterRef('pk')), is_active=True)
    qs = (Tower.objects.filter(is_active=False)
          .annotate(_has_insp=Exists(has_inspection), _has_assign=Exists(has_assignment))
          .filter(Q(_has_insp=True) | Q(_has_assign=True)))
    if line is not None:
        qs = qs.filter(Q(line=line) | Q(line_name=line.name))

    results = []
    delta = 0.0004  # ~44m bbox around each stranded tower
    for t in qs:
        if t.latitude is None or t.longitude is None:
            continue
        nearby = Tower.objects.filter(
            is_active=True, voltage=t.voltage,
            latitude__range=(t.latitude - delta, t.latitude + delta),
            longitude__range=(t.longitude - delta, t.longitude + delta),
        ).exclude(pk=t.pk)
        best_twin, best_d = None, CHURN_M
        for a in nearby:
            d = distance_m(t.latitude, t.longitude, a.latitude, a.longitude)
            if d is not None and d <= best_d:
                best_d, best_twin = d, a
        if best_twin is not None:
            results.append({'stranded': t, 'twin': best_twin, 'distance_m': round(best_d, 1)})
    return results
