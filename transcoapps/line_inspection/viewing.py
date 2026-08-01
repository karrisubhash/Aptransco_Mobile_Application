"""Oversight (viewing) scope for the Phase 3 web dashboard — the reporting-
hierarchy-widened superset of jurisdiction.py's own-assignment scope.

Kept deliberately separate from jurisdiction.py: jurisdiction.visible_*/
can_edit_tower is the *edit/capture* authority the REST API write path relies
on and must stay scoped to an employee's own RoleAssignments. viewing.* is
*read-only* oversight — a supervisor sees every tower assigned to Users beneath
them in the reporting hierarchy, but that never grants edit rights.

ONE DELIBERATE EXCEPTION: oversees_tower() below backs closing a defect ticket
(DefectTicketCloseView). Closing is a supervisory sign-off — "attended and
rectified" — not field capture, and a DEE/EE/SE is precisely who signs off
defects raised by the AEEs reporting to them. Recording an inspection is
different: it is presence-gated fieldwork, so _create_inspection stays on
jurisdiction.can_edit_tower and must NOT be widened to oversight.

Viewing tier is FUNCTIONAL, not grade-based: real SAP cadre codes are coarse/
combined (e.g. 'DE/EE'), so authorization derives from the reporting tree + who
actually holds RoleAssignments. emp_sub_grp is used only for display labels and
the management-dashboard gate (CADRE_LABELS / MANAGEMENT_SUBGRPS).

ONE WIDENING ABOVE THE REPORTING TREE: is_management() (super admins, plus the
top technical cadre) means all-tower scope, and oversight_lines/oversight_towers
honour it directly — see oversight_lines. Anything above the tree therefore
belongs in is_management(), not in a per-view `if is_management` branch; those
branches are what let the two scopes drift apart.
"""
from django.db.models import Q

from .models import Tower, Line, RoleAssignment, EmployeeCadreSnapshot
from . import jurisdiction
from .auth import is_admin, is_super_admin
from .request_scope import memoized as _memoized


# Display-only map of SAP emp_sub_grp codes -> field cadre label, derived from
# the live synced snapshot (see memory/aptransco-cadre-codes). NOT authoritative
# for authorization. Codes not listed fall back to the raw emp_sub_grp.
CADRE_LABELS = {
    'AAE': 'AEE', 'AE': 'AEE', 'ADE/AEE': 'DEE',
    'DE/EE': 'EE', 'SE': 'SE', 'CE': 'CE',
    'DIRECTOR': 'Director', 'GM': 'GM', 'JMD': 'JMD', 'CMD': 'CMD',
}

# emp_sub_grp codes whose holders get the zonal/circle/division management
# rollups (and all-tower scope). Top of the technical cadre only.
MANAGEMENT_SUBGRPS = {'CE', 'DIRECTOR', 'GM', 'JMD', 'CMD'}


def subordinate_snapshots(employee_id):
    """All employees below employee_id in the reporting hierarchy (BFS over
    EmployeeCadreSnapshot.reporting_manager_id, which is indexed). Cheap
    in-memory walk over the ~1,830-row snapshot; the seed employee is NOT
    included. This is the single implementation of the subtree walk — the
    role-assignment candidate list in admin_views reuses it.

    Memoized per request, so asking twice in one response costs one walk."""
    return _memoized(('subtree', employee_id),
                     lambda: _walk_subtree(employee_id))


def _walk_subtree(employee_id):
    by_manager = {}
    for emp in EmployeeCadreSnapshot.objects.exclude(reporting_manager_id='').only(
        'employee_id', 'employee_name', 'reporting_manager_id', 'position_text', 'emp_sub_grp'
    ):
        by_manager.setdefault(emp.reporting_manager_id, []).append(emp)

    result, frontier, seen = [], [employee_id], {employee_id}
    while frontier:
        next_frontier = []
        for manager_id in frontier:
            for emp in by_manager.get(manager_id, []):
                if emp.employee_id not in seen:
                    seen.add(emp.employee_id)
                    result.append(emp)
                    next_frontier.append(emp.employee_id)
        frontier = next_frontier
    return result


def visible_employee_ids(employee_id):
    """{employee_id} plus every subordinate id — the employees whose
    RoleAssignments make up this viewer's oversight scope. Self is included so
    a leaf User's oversight scope equals their own jurisdiction exactly."""
    def compute():
        ids = {employee_id}
        ids.update(e.employee_id for e in subordinate_snapshots(employee_id))
        return ids

    return _memoized(('scope_ids', employee_id), compute)


def oversight_lines(employee_id):
    """Union of the active Lines assigned to the viewer OR anyone below them in
    the reporting hierarchy — one widened query, not N per-subordinate.

    Management viewers (is_management: any super admin, or the top technical
    cadre) get every active line. is_management has always meant "all-tower
    scope", but only the rollup queryset, the mobile dashboard totals and the
    subdivision list honoured it; every other read — the line list, both map
    endpoints, tickets, inspections, the register — came through here and so fell
    back to the viewer's own RoleAssignments. A super admin holds none, so the
    app reported ~66k towers in the KPI strip and "No lines assigned to you yet"
    over the map in the same frame. Widening here instead of at each caller keeps
    the two answers from drifting apart again."""
    if is_management(employee_id):
        return Line.objects.filter(is_active=True)
    assignments = RoleAssignment.objects.filter(
        employee_id__in=visible_employee_ids(employee_id), is_active=True,
    )
    return jurisdiction._lines_for_assignments(assignments)


def oversight_lines_including_ranges(employee_id):
    """oversight_lines() widened with any line a from/to-tower RANGE grant
    touches in the viewer's subtree, but only for callers that walk lines to
    reach towers (the mobile line list, and Home's map behind it: fetch lines,
    then fetch each line's towers).

    A range assignment intentionally never grants the whole line — that is the
    point of LineTowerAssignment ("for when a whole line isn't one person's") —
    so its line has no RoleAssignment and oversight_lines() never surfaces it.
    Every OTHER read already scopes by tower, not by line (oversight_towers
    unions the range ids in directly), so the dashboard KPIs, tickets and
    history already count a range grant's towers correctly. Only the line-first
    callers were blind to them: Home would show a KPI total that included those
    towers while its map, walking oversight_lines(), never fetched the line
    that held them and so could never draw or open one.

    Deliberately NOT folded into oversight_lines() itself: MapLineListView's
    per-line rollup counts every tower on a line directly, trusting that a line
    in oversight_lines is either wholly granted or all-lines-for-management.
    Widening oversight_lines there would hand a range-only viewer a rollup for
    the WHOLE line instead of just their granted stretch. The Line row added
    here is safe only because the tower-level read that follows it
    (oversight_towers, e.g. LineTowerListView) independently narrows a
    range-only line straight back down to the granted towers."""
    lines = oversight_lines(employee_id)
    if is_management(employee_id):
        return lines  # already every active line
    range_line_ids = jurisdiction.range_line_ids(visible_employee_ids(employee_id))
    if not range_line_ids:
        return lines
    return Line.objects.filter(
        Q(pk__in=lines.values_list('pk', flat=True)) | Q(pk__in=range_line_ids),
        is_active=True,
    ).distinct()


def oversight_line_ids(employee_id):
    """The ids behind oversight_lines, memoized per request.

    Every scoped queryset in the app is filtered on these, so they were resolved
    over and over within one response — twice per oversight_towers() call alone."""
    return _memoized(
        ('line_ids', employee_id),
        lambda: list(oversight_lines(employee_id).values_list('id', flat=True)),
    )


def oversight_range_tower_ids(employee_id):
    """Tower ids granted by from/to-tower range assignments anywhere in the
    viewer's subtree. Memoized per request for the same reason as the line ids —
    it is a query per assignment range."""
    return _memoized(
        ('range_ids', employee_id),
        lambda: jurisdiction.range_tower_ids(visible_employee_ids(employee_id)),
    )


def oversight_towers(employee_id, geocoded_only=False):
    """Active towers on any line in the viewer's oversight scope. Pass
    geocoded_only=True for the map (towers without lat/lng can't be placed);
    leave it False for tickets/inspections/rollups, which count every tower."""
    # Real towers only (see jurisdiction.visible_towers) — VT rows never inspected/counted.
    if is_management(employee_id):
        # Short-circuit rather than going through oversight_line_ids: the answer
        # is every active real tower either way, and resolving ~1,200 line ids to
        # reach it is a wasted query plus a 1,200-element IN list. This is the
        # same queryset rollup_view and MobileDashboardView built by hand.
        qs = Tower.objects.filter(is_active=True, is_virtual=False)
    else:
        scope = Q(line_id__in=oversight_line_ids(employee_id))
        range_ids = oversight_range_tower_ids(employee_id)
        if range_ids:
            scope |= Q(id__in=range_ids)
        qs = Tower.objects.filter(scope, is_active=True, is_virtual=False)
    if geocoded_only:
        qs = qs.filter(latitude__isnull=False, longitude__isnull=False)
    return qs


def oversees_tower(employee_id, tower):
    """Whether this tower falls inside employee_id's oversight scope — i.e. it is
    assigned to them or to someone below them in the reporting hierarchy.

    Read the module docstring before using this to authorise a write: it backs the
    ticket-close sign-off only. Because oversight_towers is all-tower for
    is_management viewers, so is this: a super admin could already close any
    ticket (DefectTicketCloseView's is_admin bypass), but a non-admin management
    cadre (CE/Director/GM/JMD/CMD) can now sign off a ticket anywhere, not just
    inside their own reporting subtree. That follows from them being shown every
    ticket in the first place — the alternative is a statewide ticket list whose
    rows mostly refuse to close. Note this is a superset of
    jurisdiction.can_edit_tower for active, real towers (visible_employee_ids
    includes self), but not for inactive/VT rows, which oversight_towers filters
    out — so callers that need to preserve an existing own-scope permission should
    OR the two rather than replace one with the other."""
    if tower is None or tower.id is None:
        return False
    return oversight_towers(employee_id).filter(pk=tower.id).exists()


def circuits_at(tower):
    """All active circuits/lines strung on the same physical structure as this
    tower — its own line plus every co-located (real or VT) row's line, resolved
    via the shared structure_key. Answers 'click a tower → which lines/circuits
    run through it'. Returns Line objects, deduped, ordered by voltage then name."""
    if tower.structure_key:
        line_ids = list(
            Tower.objects.filter(structure_key=tower.structure_key, is_active=True, line__isnull=False)
            .values_list('line_id', flat=True).distinct()
        )
    else:
        line_ids = [tower.line_id] if tower.line_id else []
    if not line_ids:
        return []
    return list(Line.objects.filter(id__in=line_ids, is_active=True).order_by('voltage', 'name'))


def _snapshot(employee_id):
    """The viewer's own snapshot row, memoized per request: is_management() and
    display_label() both want it, and so does every cadre label on a page."""
    return _memoized(
        ('snapshot', employee_id),
        lambda: EmployeeCadreSnapshot.objects.filter(employee_id=employee_id).first(),
    )


def cadre_tier(employee_id):
    """Functional viewing tier (NOT a grade label):
      'admin'      — holds a granted FieldEECadrePosition / is a super admin
      'supervisor' — a subordinate (not self) holds an active RoleAssignment
      'field_user' — only the viewer themselves holds an active RoleAssignment
      'none'       — no active assignment anywhere in the viewer's scope
    Used only for map framing and the landing view; never to restrict a viewer
    below their own jurisdiction."""
    if is_admin(employee_id):
        return 'admin'
    scope_ids = visible_employee_ids(employee_id)
    assigned = set(
        RoleAssignment.objects.filter(employee_id__in=scope_ids, is_active=True)
        .values_list('employee_id', flat=True)
    )
    if not assigned:
        return 'none'
    if assigned == {employee_id}:
        return 'field_user'
    return 'supervisor'


def is_management(employee_id):
    """Whether to expose the zonal/circle/division rollups (and all-tower
    scope). Super admins always; otherwise holders of a top-cadre emp_sub_grp.

    The dashboard endpoint asks twice (once to pick the tower scope, once to
    decide on the per-subdivision roll), so this is memoized per request too."""
    def compute():
        if is_super_admin(employee_id):
            return True
        snap = _snapshot(employee_id)
        return bool(snap and snap.emp_sub_grp in MANAGEMENT_SUBGRPS)

    return _memoized(('is_management', employee_id), compute)


def display_label(employee_id):
    """Human-readable cadre label for the header, e.g. 'AEE'/'EE'/'SE'. Falls
    back to the raw emp_sub_grp when the code isn't in CADRE_LABELS."""
    snap = _snapshot(employee_id)
    if not snap:
        return ''
    return CADRE_LABELS.get(snap.emp_sub_grp, snap.emp_sub_grp or '')
