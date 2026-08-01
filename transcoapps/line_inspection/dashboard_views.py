"""Phase 3 field-engineer / oversight web dashboard — read-only.

No inspection capture here (that is the Flutter app, Phase 4). These are
server-rendered Django templates + vanilla JS in the same style as
admin_views.py. Every screen is scoped by the reporting-hierarchy OVERSIGHT
scope (viewing.py), NOT the own-assignment jurisdiction scope: a viewer sees
their own towers plus every tower assigned to Users beneath them.

  - map_view          any logged-in employee — role-scoped tower map
  - tickets_view      any logged-in employee — defect tickets in scope
  - inspections_view  any logged-in employee — inspection history in scope
  - rollup_view       management / admin only — zonal/circle/division rollups
"""
import json
import re

from django.db.models import Count, Q, Min, Max
from django.http import HttpResponseForbidden, HttpResponse
from django.shortcuts import render

from . import auth, viewing, register
from . import status as tower_status
from .models import Inspection, DefectTicket, attach_defect_counts

# Andhra Pradesh map default (matches gisapp's map_data center) for empty scopes.
AP_CENTER = [15.8497, 78.0661]
AP_ZOOM = 8

ROLLUP_LEVELS = ['zone', 'circle', 'division']


@auth.login_required
def map_view(request):
    employee_id = request.session['employee_id']
    towers = viewing.oversight_towers(employee_id, geocoded_only=True)

    bounds = towers.aggregate(
        min_lat=Min('latitude'), max_lat=Max('latitude'),
        min_lng=Min('longitude'), max_lng=Max('longitude'),
    )
    has_bounds = bounds['min_lat'] is not None
    tower_total = towers.count()
    inspected = towers.filter(last_inspection_at__isnull=False).count()

    context = {
        'active_tab': 'map',
        'tier': viewing.cadre_tier(employee_id),
        'cadre_label': viewing.display_label(employee_id),
        'tower_total': tower_total,
        'inspected_total': inspected,
        'pending_total': tower_total - inspected,
        'line_total': viewing.oversight_lines(employee_id).count(),
        'status_colors_json': json.dumps(tower_status.STATUS_COLORS),
        'status_labels': tower_status.STATUS_LABELS,
        'ap_center_json': json.dumps(AP_CENTER),
        'ap_zoom': AP_ZOOM,
        'bounds_json': json.dumps(bounds if has_bounds else None),
    }
    return render(request, 'line_inspection/dashboard_map.html', context)


@auth.login_required
def tickets_view(request):
    employee_id = request.session['employee_id']
    scope_tower_ids = viewing.oversight_towers(employee_id).values_list('id', flat=True)
    qs = DefectTicket.objects.filter(tower_id__in=scope_tower_ids).select_related('tower').order_by('-raised_at')

    status_f = request.GET.get('status', '')
    source_f = request.GET.get('source', '')
    crit_f = request.GET.get('criticality', '')
    if status_f:
        qs = qs.filter(status=status_f)
    if source_f:
        qs = qs.filter(source=source_f)
    if crit_f:
        qs = qs.filter(criticality=crit_f)

    context = {
        'active_tab': 'tickets',
        'tickets': qs[:500],
        'status_f': status_f, 'source_f': source_f, 'crit_f': crit_f,
        'is_admin': auth.is_admin(employee_id),
    }
    return render(request, 'line_inspection/dashboard_tickets.html', context)


@auth.login_required
def inspections_view(request):
    """Inspection history, oversight-scoped. Without ?tower: a summary list of
    the latest inspections across the viewer's scope. With ?tower=<id> (a tower
    in scope): that tower's full inspection history, newest-first, each expandable
    into its item results + defect entries. Optional ?cycle filters by type."""
    employee_id = request.session['employee_id']
    scope = viewing.oversight_towers(employee_id)
    cycle = request.GET.get('cycle', '')
    if cycle not in ('', 'ground_patrol', 'pmi'):
        cycle = ''

    tower_id = request.GET.get('tower')
    if tower_id:
        selected_tower = scope.filter(pk=tower_id).select_related('line').first()
        if not selected_tower:
            return render(request, 'line_inspection/dashboard_inspections.html', {
                'active_tab': 'inspections', 'out_of_scope': True,
                'cycle': cycle, 'cycle_labels': register.CYCLE_LABELS,
            })
        qs = (Inspection.objects.filter(tower=selected_tower)
              .prefetch_related('item_results__item', 'item_results__entries__defect')
              .order_by('-saved_at'))
        if cycle:
            qs = qs.filter(inspection_type=cycle)
        context = {
            'active_tab': 'inspections',
            'detail': True,
            'selected_tower': selected_tower,
            'cycle': cycle, 'cycle_labels': register.CYCLE_LABELS,
            'inspections': attach_defect_counts(qs),
        }
        return render(request, 'line_inspection/dashboard_inspections.html', context)

    # The count comes after the 500-row cut, not before it — see
    # attach_defect_counts. Annotating it grouped every inspection in the
    # viewer's scope just to label one page.
    qs = (Inspection.objects.filter(tower_id__in=scope.values_list('id', flat=True))
          .select_related('tower')
          .order_by('-saved_at')[:500])
    context = {
        'active_tab': 'inspections',
        'detail': False,
        'inspections': attach_defect_counts(qs),
    }
    return render(request, 'line_inspection/dashboard_inspections.html', context)


@auth.login_required
def register_view(request):
    """Line inspection register — per-line matrix (digital field-register
    replica). Read-only. `?line=<id>` selects the line (must be in the viewer's
    oversight scope), `?cycle=ground_patrol|pmi` the cycle, `?format=xlsx`
    streams the Excel download."""
    employee_id = request.session['employee_id']
    lines = viewing.oversight_lines(employee_id).order_by('name')

    cycle = request.GET.get('cycle', '')
    if cycle not in ('', 'ground_patrol', 'pmi'):
        cycle = ''

    line_id = request.GET.get('line')
    selected_line = None
    structure = None
    if line_id:
        selected_line = lines.filter(pk=line_id).first()
        if not selected_line:
            # Never trust the line id — it must be within the viewer's scope.
            return HttpResponseForbidden('That line is outside your jurisdiction.')
        structure = register.build_register(selected_line, cycle)

        if request.GET.get('format') == 'xlsx':
            content = register.register_to_xlsx(structure)
            resp = HttpResponse(
                content,
                content_type='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            )
            safe = re.sub(r'[^A-Za-z0-9]+', '_', (selected_line.name or str(selected_line.id))).strip('_')
            resp['Content-Disposition'] = f'attachment; filename="register_{safe}_{cycle or "latest"}.xlsx"'
            return resp

    context = {
        'active_tab': 'register',
        'lines': list(lines.values('id', 'name', 'voltage')),
        'selected_line': selected_line,
        'selected_line_id': int(line_id) if line_id and str(line_id).isdigit() else None,
        'cycle': cycle,
        'cycle_labels': register.CYCLE_LABELS,
        'cycle_label': register.CYCLE_LABELS.get(cycle, 'Latest'),
        'structure': structure,
        'status_colors': tower_status.STATUS_COLORS,
    }
    return render(request, 'line_inspection/dashboard_register.html', context)


def _rollup(level, tower_qs):
    """Aggregate inspection + ticket rollups grouped by a geo field
    (zone/circle/division) on Tower — all from the denormalized Tower cache and
    the DefectTicket table, no Inspection join. Reusable so a future mobile
    JSON endpoint can share it."""
    field = level if level in ROLLUP_LEVELS else 'zone'

    tower_rows = (
        tower_qs.values(field).annotate(
            total=Count('id'),
            inspected=Count('id', filter=Q(last_inspection_at__isnull=False)),
            minor=Count('id', filter=Q(last_worst_criticality='minor')),
            major=Count('id', filter=Q(last_worst_criticality='major')),
            critical=Count('id', filter=Q(last_worst_criticality='critical')),
        ).order_by(field)
    )

    ticket_key = f'tower__{field}'
    ticket_rows = (
        DefectTicket.objects.filter(tower__in=tower_qs).values(ticket_key).annotate(
            open=Count('id', filter=Q(status='open')),
            critical_open=Count('id', filter=Q(status='open', criticality='critical')),
            human=Count('id', filter=Q(source='human_inspection')),
            drone=Count('id', filter=Q(source='drone_inspection')),
        )
    )
    tickets_by_group = {row[ticket_key]: row for row in ticket_rows}

    result = []
    for row in tower_rows:
        tickets = tickets_by_group.get(row[field], {})
        result.append({
            'group': row[field] or '(unspecified)',
            'total': row['total'],
            'inspected': row['inspected'],
            'pending': row['total'] - row['inspected'],
            'minor': row['minor'], 'major': row['major'], 'critical': row['critical'],
            'tickets_open': tickets.get('open', 0),
            'tickets_critical_open': tickets.get('critical_open', 0),
            'tickets_human': tickets.get('human', 0),
            'tickets_drone': tickets.get('drone', 0),
        })
    return result


@auth.login_required
def rollup_view(request):
    employee_id = request.session['employee_id']
    is_mgmt = viewing.is_management(employee_id)
    if not (is_mgmt or auth.is_admin(employee_id)):
        return HttpResponseForbidden('The management reports are restricted to admins and management cadre.')

    level = request.GET.get('level', 'zone')
    if level not in ROLLUP_LEVELS:
        level = 'zone'

    # Management/super-admin see all active towers; other (admin) viewers see
    # only their oversight scope — both come out of oversight_towers, which owns
    # the is_management widening. is_mgmt survives here for the label only.
    tower_qs = viewing.oversight_towers(employee_id)
    scope_label = 'All towers (management view)' if is_mgmt else 'Your oversight scope'

    rows = _rollup(level, tower_qs)
    totals = {
        'total': sum(r['total'] for r in rows),
        'inspected': sum(r['inspected'] for r in rows),
        'pending': sum(r['pending'] for r in rows),
        'tickets_open': sum(r['tickets_open'] for r in rows),
    }
    context = {
        'active_tab': 'rollup',
        'level': level,
        'levels': ROLLUP_LEVELS,
        'rows': rows,
        'totals': totals,
        'scope_label': scope_label,
    }
    return render(request, 'line_inspection/dashboard_rollup.html', context)
