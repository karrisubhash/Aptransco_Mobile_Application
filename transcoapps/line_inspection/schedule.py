"""Line tower schedule — the ordered position of each tower along its line.

Order is derived by projecting each tower's lat/long onto the line's GeoJSON
LineString (distance measured *along* the line), which works for 100% of active
lines. For lines whose geometry is missing/degenerate or physically branched
(Tap/LILO — detected by duplicate tower_numbers), we fall back to a numeric
tower_number sort. The computed order is persisted as `Tower.line_sequence` by
management/commands/build_tower_schedule.py; `line_schedule()` reads it back.

Pure Python, no PostGIS: an equirectangular metres approximation about the line's
first vertex is plenty accurate for *ordering* towers along a ~kilometres-long
corridor.
"""
import math
import re
from collections import Counter

from django.db.models import F

from .models import Tower

_M_PER_DEG_LAT = 110_574.0
_M_PER_DEG_LON_EQ = 111_320.0


def tower_sort_key(tower):
    """Numeric-prefix-then-string fallback sort (Boom/Gantry rows, having no
    leading number, sort to the tail). Mirrors the original register sort."""
    m = re.match(r'\s*(\d+)', tower.tower_number or '')
    return (0, int(m.group(1)), tower.tower_number or '') if m else (1, 0, tower.tower_number or '')


def line_vertices(geometry):
    """(lon, lat) vertices of a GeoJSON LineString/MultiLineString, else []."""
    if not geometry:
        return []
    gtype = geometry.get('type')
    coords = geometry.get('coordinates') or []
    if gtype == 'LineString':
        return [(c[0], c[1]) for c in coords if isinstance(c, (list, tuple)) and len(c) >= 2]
    if gtype == 'MultiLineString':
        verts = []
        for part in coords or []:
            verts.extend((c[0], c[1]) for c in part if isinstance(c, (list, tuple)) and len(c) >= 2)
        return verts
    return []


def _to_xy(lon, lat, cos_lat0):
    return (lon * _M_PER_DEG_LON_EQ * cos_lat0, lat * _M_PER_DEG_LAT)


def project_onto_line(vertices, lon, lat):
    """Return (along_m, offset_m): distance along the polyline to the closest
    point on it, and the perpendicular distance to that point. None if the line
    has < 2 vertices or the tower has no coords."""
    if len(vertices) < 2 or lon is None or lat is None:
        return None, None
    cos_lat0 = math.cos(math.radians(vertices[0][1]))
    pts = [_to_xy(lo, la, cos_lat0) for lo, la in vertices]
    px, py = _to_xy(lon, lat, cos_lat0)

    best_off2, best_along, cum = None, 0.0, 0.0
    for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
        dx, dy = x2 - x1, y2 - y1
        seg2 = dx * dx + dy * dy
        seg_len = math.sqrt(seg2)
        if seg2 == 0.0:
            t, cx, cy = 0.0, x1, y1
        else:
            t = max(0.0, min(1.0, ((px - x1) * dx + (py - y1) * dy) / seg2))
            cx, cy = x1 + t * dx, y1 + t * dy
        off2 = (px - cx) ** 2 + (py - cy) ** 2
        if best_off2 is None or off2 < best_off2:
            best_off2, best_along = off2, cum + t * seg_len
        cum += seg_len
    return best_along, math.sqrt(best_off2)


def compute_line_order(line):
    """Return (mode, ordered) for one line WITHOUT writing. mode ∈
    {'geometry','fallback','empty'}; ordered = [(tower, offset_m_or_None), ...] in
    schedule order. Geometry projection primary; numeric tower_number fallback when
    geometry is missing/degenerate or the line is branched (duplicate numbers)."""
    towers = list(Tower.objects.filter(line=line, is_active=True)
                  .only('id', 'tower_number', 'latitude', 'longitude'))
    if not towers:
        return 'empty', []
    verts = line_vertices(line.geometry)
    dup = any(c > 1 for c in Counter(t.tower_number for t in towers if t.tower_number).values())
    use_geometry = len(verts) >= 2 and not dup
    ordered = []
    if use_geometry:
        projected, missing = [], []
        for t in towers:
            along, offset = project_onto_line(verts, t.longitude, t.latitude)
            (projected if along is not None else missing).append((t, along, offset))
        if not projected:
            use_geometry = False
        else:
            projected.sort(key=lambda p: p[1])
            ordered = ([(t, off) for t, _a, off in projected]
                       + [(t, None) for t, _a, _o in sorted(missing, key=lambda p: tower_sort_key(p[0]))])
    if not use_geometry:
        ordered = [(t, None) for t in sorted(towers, key=tower_sort_key)]
    return ('geometry' if use_geometry else 'fallback'), ordered


def assign_line_sequence(line):
    """Compute + persist line_sequence/line_offset_m for ONE line's active towers
    (fast, per-line). Reused by build_tower_schedule and the LILO reconcile.
    Returns the mode string."""
    mode, ordered = compute_line_order(line)
    for seq, (tower, offset) in enumerate(ordered, start=1):
        tower.line_sequence = seq
        tower.line_offset_m = round(offset, 2) if offset is not None else None
    if ordered:
        Tower.objects.bulk_update([t for t, _ in ordered], ['line_sequence', 'line_offset_m'], batch_size=1000)
    return mode


def line_schedule(line, include_virtual=True):
    """Towers on `line`, ordered along the line (`line_sequence`, nulls last).
    include_virtual=False drops VT rows (real-only)."""
    qs = Tower.objects.filter(line=line, is_active=True)
    if not include_virtual:
        qs = qs.filter(is_virtual=False)
    return list(qs.order_by(F('line_sequence').asc(nulls_last=True), 'tower_number', 'id'))
