"""Server-side jurisdiction filtering — the direct equivalent of the POC's
App.visibleLines()/visibleTowers()/canEdit(). No django.contrib.auth: callers
identify themselves by employee_id (resolved from Keycloak/checkCred), and
jurisdiction comes entirely from RoleAssignment rows an EE created for that
employee.

This is the *own-assignment* (edit/capture) scope: can_edit_tower depends on it
staying scoped to a single employee's own assignments. The
reporting-hierarchy-widened *oversight* (read) scope for the Phase 3 dashboard
lives in viewing.py and is built on top of _lines_for_assignments below — never
by widening these functions.

Recording an inspection now goes through can_inspect_tower, which by default
allows any authenticated employee (settings.LINE_INSPECTION_OPEN_INSPECT). The
per-assignment rule it falls back to is unchanged and still governs ticket
close, so opening capture did not widen any other permission."""
from django.conf import settings
from django.db.models import Q

from .models import Line, Tower, RoleAssignment, LineTowerAssignment


def _active_assignments(employee_id):
    return RoleAssignment.objects.filter(employee_id=employee_id, is_active=True)


def _lines_for_assignments(assignments):
    """Active Lines granted by an iterable/queryset of RoleAssignments — via
    subdivision membership and/or explicit line membership. Shared by the
    single-employee own scope (visible_lines) and viewing.oversight_lines
    (a whole reporting subtree), so the union logic exists once."""
    assignments = list(assignments)
    if not assignments:
        return Line.objects.none()

    subdivision_ids = [a.subdivision_id for a in assignments if a.subdivision_id]
    line_ids = list(
        RoleAssignment.lines.through.objects.filter(roleassignment__in=assignments)
        .values_list('line_id', flat=True)
    )

    if not subdivision_ids and not line_ids:
        return Line.objects.none()

    query = Q(pk__in=[])
    if subdivision_ids:
        query |= Q(subdivision_id__in=subdivision_ids)
    if line_ids:
        query |= Q(pk__in=line_ids)
    return Line.objects.filter(query, is_active=True).distinct()


def visible_lines(employee_id):
    return _lines_for_assignments(_active_assignments(employee_id))


def range_tower_ids(employee_ids):
    """Real tower ids covered by from/to-tower range assignments for the given
    employee id(s). A range covers the line's towers whose line_sequence lies
    between the two boundary towers' sequences (boundaries stored as towers, so
    a schedule rebuild can't drift the stretch). Falls back to just the two
    boundary towers if the schedule hasn't been built for them yet."""
    if isinstance(employee_ids, str):
        employee_ids = [employee_ids]
    ids = set()
    ranges = (LineTowerAssignment.objects
              .filter(employee_id__in=list(employee_ids), is_active=True)
              .select_related('from_tower', 'to_tower'))
    for r in ranges:
        f_seq, t_seq = r.from_tower.line_sequence, r.to_tower.line_sequence
        if f_seq is not None and t_seq is not None:
            lo, hi = sorted((f_seq, t_seq))
            ids.update(Tower.objects.filter(
                line_id=r.line_id, is_active=True, is_virtual=False,
                line_sequence__gte=lo, line_sequence__lte=hi,
            ).values_list('id', flat=True))
        else:
            ids.update({r.from_tower_id, r.to_tower_id})
    return ids


def range_line_ids(employee_ids):
    """Distinct line ids touched by active from/to-tower range assignments for
    the given employee id(s) — the lines behind range_tower_ids' towers.

    A range grant is deliberately for "when a whole line isn't one person's",
    so its line never gets a RoleAssignment of its own and is invisible to
    _lines_for_assignments. Callers that walk lines to reach towers (Home's
    map: line list, then towers-per-line) need this line id too, or a
    range-only grant's towers are never fetched even though oversight_towers
    already counts them."""
    if isinstance(employee_ids, str):
        employee_ids = [employee_ids]
    return set(
        LineTowerAssignment.objects.filter(employee_id__in=list(employee_ids), is_active=True)
        .values_list('line_id', flat=True)
    )


def visible_towers(employee_id):
    """Real towers an employee may inspect: those on their whole-line/subdivision
    grants UNION those inside their from/to-tower ranges. VT rows are never
    inspected/counted (they surface only via circuits_at())."""
    line_ids = list(visible_lines(employee_id).values_list('id', flat=True))
    range_ids = range_tower_ids(employee_id)
    scope = Q(line_id__in=line_ids)
    if range_ids:
        scope |= Q(id__in=range_ids)
    return Tower.objects.filter(scope, is_active=True, is_virtual=False)


def can_edit_tower(employee_id, tower):
    if tower.line_id is None:
        return False
    if visible_lines(employee_id).filter(pk=tower.line_id).exists():
        return True
    return tower.id in range_tower_ids(employee_id)


def can_inspect_tower(employee_id, tower):
    """Whether `employee_id` may RECORD an inspection on `tower`.

    Deliberately separate from can_edit_tower. With
    settings.LINE_INSPECTION_OPEN_INSPECT on (the default) recording is open to
    any authenticated employee — see the settings comment for why. Turn the flag
    off and this falls straight back to the per-assignment rule below, which is
    left intact rather than deleted.

    Keeping this distinct matters: can_edit_tower also backs the defect-ticket
    close sign-off (api/views.py) and viewing.py's edit authority, and neither of
    those should widen just because field capture did.
    """
    if getattr(settings, 'LINE_INSPECTION_OPEN_INSPECT', False):
        return True
    return can_edit_tower(employee_id, tower)
