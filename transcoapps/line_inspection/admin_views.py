"""Custom admin panel views — no django.contrib.admin anywhere.

Three screens gated by auth.py's decorators:
  - manage_admins       (@super_admin_required) — grant/revoke Admin (FieldEECadrePosition)
  - role_assignments    (@admin_required)        — assign Users (AEE/DEE) to lines/towers
  - checklist_editor    (@admin_required)        — edit the DB-backed checklist catalog
  - sap_mapping         (@admin_required)        — SAP<->ArcGIS line mapping
"""
import json

from django.contrib import messages
from django.core.management import call_command
from django.db import IntegrityError, transaction
from django.http import JsonResponse
from django.utils import timezone
from django.shortcuts import render, redirect, get_object_or_404
from django.urls import reverse

from . import auth
from .forms import (
    FieldEECadrePositionForm, RoleAssignmentForm, ChecklistItemGroupForm, ChecklistItemForm,
    DefectForm, FollowUpQuestionForm, CriticalityRuleForm, SapLineForm,
)
from .models import (
    EmployeeCadreSnapshot, FieldEECadrePosition, RoleAssignment, LineTowerAssignment,
    Subdivision, Line, Tower, CatalogVersion, ChecklistItemGroup, ChecklistItem, Defect,
    FollowUpQuestion, CriticalityRule, SapLine,
)
from . import schedule as sched
from .services import sap_client
from .services.sap_client import SapClientError
from .services.sap_matching import find_best_matches
from .services import lilo_matching as lm
from .models import LiloEvent


@auth.login_required
def admin_home(request):
    context = {
        'towers': Tower.objects.filter(is_active=True).count(),
        'lines': Line.objects.filter(is_active=True).count(),
        'active_assignments': RoleAssignment.objects.filter(is_active=True).count(),
        'unmapped_lines': Line.objects.filter(sap_line=None, is_active=True).count(),
        'catalog_version': CatalogVersion.current(),
    }
    # Super-Admin safety-net badge: count of likely undeclared LILO/shift churn.
    if auth.is_super_admin(request.session['employee_id']):
        context['churn_count'] = len(lm.detect_churn())
    return render(request, 'line_inspection/admin_home.html', context)


# ---------------------------------------------------------------------------
# Manage Admins (Super Admin only)
# ---------------------------------------------------------------------------

@auth.super_admin_required
def manage_admins(request):
    if request.method == 'POST':
        action = request.POST.get('action')
        if action == 'grant':
            position_id = request.POST.get('position_id', '').strip()
            position_text = request.POST.get('position_text', '').strip()
            if position_id:
                FieldEECadrePosition.objects.get_or_create(
                    position_id=position_id, defaults={'position_text': position_text},
                )
                messages.success(request, f'Granted Admin rights to position {position_id}.')
        elif action == 'revoke':
            FieldEECadrePosition.objects.filter(position_id=request.POST.get('position_id')).delete()
            messages.success(request, 'Revoked Admin rights.')
        elif action == 'add_manual':
            form = FieldEECadrePositionForm(request.POST)
            if form.is_valid():
                form.save()
                messages.success(request, 'Admin position added.')
        return redirect('line_inspection:manage-admins')

    granted_ids = set(FieldEECadrePosition.objects.values_list('position_id', flat=True))

    # The exact candidate filter the user specified: DE/EE cadre + O&M postings.
    # Real synced data uses the single combined code "DE/EE" (confirmed against
    # the live sync, not two separate "DE"/"EE" values).
    candidates_qs = (
        EmployeeCadreSnapshot.objects
        .filter(emp_sub_grp='DE/EE', position_text__icontains='O&M')
        .exclude(position_id='')
        .order_by('position_text')
    )
    seen_positions = {}
    for emp in candidates_qs:
        seen_positions.setdefault(emp.position_id, {
            'position_id': emp.position_id,
            'position_text': emp.position_text,
            'sample_employee': emp.employee_name,
            'granted': emp.position_id in granted_ids,
        })

    context = {
        'candidates': sorted(seen_positions.values(), key=lambda c: c['position_text']),
        'granted': FieldEECadrePosition.objects.order_by('position_text'),
        'manual_form': FieldEECadrePositionForm(),
    }
    return render(request, 'line_inspection/manage_admins.html', context)


@auth.super_admin_required
def lookup_position(request, position_id):
    """JSON endpoint backing the "Add by position id" fallback's auto-fill —
    posid/postext are interlinked in SAP, so an Admin only needs to type the
    position id; this resolves position_text and the current holder."""
    try:
        info = sap_client.get_employee_by_position_id(position_id)
    except SapClientError as exc:
        return JsonResponse({'error': str(exc)}, status=400)
    return JsonResponse(info)


# ---------------------------------------------------------------------------
# Role & jurisdiction assignment (Admin)
# ---------------------------------------------------------------------------

def _subordinates(employee_id):
    """Reporting-hierarchy subtree walk. Single implementation lives in
    viewing.subordinate_snapshots (shared with the Phase 3 oversight scope)."""
    from . import viewing
    return viewing.subordinate_snapshots(employee_id)


def _jurisdiction_coverage(employee_id):
    assignments = RoleAssignment.objects.filter(employee_id=employee_id, is_active=True)
    assigned_lines = set()
    subdivisions = set()
    for a in assignments:
        if a.subdivision_id:
            subdivisions.add(a.subdivision_id)
        assigned_lines.update(a.lines.values_list('id', flat=True))
    total_lines = Line.objects.filter(subdivision_id__in=subdivisions).count() if subdivisions else 0
    return {'assigned_lines': len(assigned_lines), 'total_lines_in_subdivisions': total_lines, 'subdivision_count': len(subdivisions)}


@auth.admin_required
def role_assignments(request):
    if request.method == 'POST':
        action = request.POST.get('action')
        if action == 'create':
            form = RoleAssignmentForm(request.POST)
            if form.is_valid():
                assignment = form.save(commit=False)
                assignment.role = 'FIELD_INSPECTOR'
                assignment.assigned_by_employee_id = request.session['employee_id']
                assignment.save()
                form.save_m2m()
                messages.success(request, f'Assigned {assignment.employee_id}.')
            else:
                messages.error(request, f'Could not save assignment: {form.errors.as_text()}')
        elif action == 'deactivate':
            RoleAssignment.objects.filter(pk=request.POST.get('assignment_id')).update(is_active=False)
            messages.success(request, 'Assignment deactivated.')
        elif action == 'create_range':
            employee_id = request.POST.get('employee_id')
            line_id = request.POST.get('range_line_id')
            from_id = request.POST.get('from_tower_id')
            to_id = request.POST.get('to_tower_id')
            if employee_id and line_id and from_id and to_id:
                on_line = set(Tower.objects.filter(pk__in=[from_id, to_id], line_id=line_id)
                              .values_list('id', flat=True))
                if {int(from_id), int(to_id)} <= on_line:
                    LineTowerAssignment.objects.create(
                        employee_id=employee_id, line_id=line_id,
                        from_tower_id=from_id, to_tower_id=to_id,
                        assigned_by_employee_id=request.session['employee_id'],
                    )
                    messages.success(request, f'Assigned tower range to {employee_id}.')
                else:
                    messages.error(request, 'From/To towers must both belong to the selected line.')
            else:
                messages.error(request, 'Line, from-tower and to-tower are all required for a range.')
        elif action == 'deactivate_range':
            LineTowerAssignment.objects.filter(pk=request.POST.get('range_id')).update(is_active=False)
            messages.success(request, 'Tower range deactivated.')
        return redirect('line_inspection:role-assignments')

    query = request.GET.get('q', '').strip()
    if query:
        candidates = EmployeeCadreSnapshot.objects.filter(employee_name__icontains=query) | \
            EmployeeCadreSnapshot.objects.filter(employee_id__icontains=query)
        candidates = candidates.distinct()[:50]
        candidate_source = 'search'
    else:
        candidates = _subordinates(request.session['employee_id'])
        candidate_source = 'hierarchy'

    candidate_rows = [
        {'employee': emp, 'coverage': _jurisdiction_coverage(emp.employee_id)}
        for emp in candidates
    ]

    context = {
        'candidate_rows': candidate_rows,
        'candidate_source': candidate_source,
        'query': query,
        'subdivisions': Subdivision.objects.order_by('name'),
        'assignments': RoleAssignment.objects.filter(is_active=True).select_related('subdivision').prefetch_related('lines').order_by('employee_id'),
        'tower_ranges': (LineTowerAssignment.objects.filter(is_active=True)
                         .select_related('line', 'from_tower', 'to_tower').order_by('employee_id')),
    }
    return render(request, 'line_inspection/role_assignments.html', context)


@auth.admin_required
def line_schedule_json(request, line_id):
    """Ordered real-tower schedule for one line — backs the from/to range picker."""
    line = get_object_or_404(Line, pk=line_id)
    towers = [
        {'id': t.id, 'tower_number': t.tower_number or str(t.id), 'cp_sp': t.cp_sp,
         'line_sequence': t.line_sequence}
        for t in sched.line_schedule(line, include_virtual=False)
    ]
    return JsonResponse({'line': line.name, 'towers': towers})


@auth.admin_required
def role_assignment_new(request, employee_id):
    employee = get_object_or_404(EmployeeCadreSnapshot, employee_id=employee_id)
    form = RoleAssignmentForm(initial={'employee_id': employee_id})
    # Drives the subdivision-filtered line search combobox client-side —
    # same active-lines queryset the form's 'lines' field validates against.
    lines_payload = list(
        Line.objects.filter(is_active=True)
        .order_by('name')
        .values('id', 'name', 'subdivision_id', 'voltage')
    )
    return render(request, 'line_inspection/role_assignment_form.html', {
        'employee': employee,
        'form': form,
        'lines_json': json.dumps(lines_payload),
    })


# ---------------------------------------------------------------------------
# Checklist catalog editor (Admin)
# ---------------------------------------------------------------------------

@auth.admin_required
def checklist_editor(request):
    groups = ChecklistItemGroup.objects.prefetch_related('items__defects__criticality_rules').all()
    context = {
        'groups': groups,
        'follow_up_questions': FollowUpQuestion.objects.all(),
        'catalog_version': CatalogVersion.current(),
    }
    return render(request, 'line_inspection/checklist_editor.html', context)


def _tower_type_choices():
    return sorted({t for t in Tower.objects.values_list('tower_type', flat=True).distinct() if t})


@auth.admin_required
def checklist_item_group_form(request, pk=None):
    instance = get_object_or_404(ChecklistItemGroup, pk=pk) if pk else None
    if request.method == 'POST':
        form = ChecklistItemGroupForm(request.POST, instance=instance)
        if form.is_valid():
            form.save()
            CatalogVersion.bump()
            messages.success(request, 'Group saved.')
            return redirect('line_inspection:checklist-editor')
    else:
        form = ChecklistItemGroupForm(instance=instance)
    return render(request, 'line_inspection/simple_form.html', {'form': form, 'title': 'Checklist item group'})


@auth.admin_required
def checklist_item_form(request, pk=None):
    instance = get_object_or_404(ChecklistItem, pk=pk) if pk else None
    initial = {'positions': ','.join(instance.positions)} if instance else {}
    if request.method == 'POST':
        form = ChecklistItemForm(request.POST, instance=instance, tower_type_choices=_tower_type_choices())
        if form.is_valid():
            item = form.save(commit=False)
            item.positions = form.cleaned_data['positions']
            item.applicable_tower_types = form.cleaned_data['applicable_tower_types']
            item.save()
            CatalogVersion.bump()
            messages.success(request, 'Checklist item saved.')
            return redirect('line_inspection:checklist-editor')
    else:
        form = ChecklistItemForm(instance=instance, initial=initial, tower_type_choices=_tower_type_choices())
        if instance:
            form.initial['applicable_tower_types'] = instance.applicable_tower_types
    return render(request, 'line_inspection/simple_form.html', {'form': form, 'title': 'Checklist item'})


@auth.admin_required
def defect_form(request, pk=None):
    instance = get_object_or_404(Defect, pk=pk) if pk else None
    initial = {'ask': ','.join(instance.ask)} if instance else {}
    if request.method == 'POST':
        form = DefectForm(request.POST, instance=instance)
        if form.is_valid():
            defect = form.save(commit=False)
            defect.ask = form.cleaned_data['ask']
            defect.save()
            CatalogVersion.bump()
            messages.success(request, 'Defect saved.')
            return redirect('line_inspection:checklist-editor')
    else:
        form = DefectForm(instance=instance, initial=initial)
    return render(request, 'line_inspection/simple_form.html', {'form': form, 'title': 'Defect'})


@auth.admin_required
def followup_question_form(request, pk=None):
    instance = get_object_or_404(FollowUpQuestion, pk=pk) if pk else None
    initial = {'options': ','.join(instance.options)} if instance else {}
    if request.method == 'POST':
        form = FollowUpQuestionForm(request.POST, instance=instance)
        if form.is_valid():
            question = form.save(commit=False)
            question.options = form.cleaned_data['options']
            question.save()
            CatalogVersion.bump()
            messages.success(request, 'Follow-up question saved.')
            return redirect('line_inspection:checklist-editor')
    else:
        form = FollowUpQuestionForm(instance=instance, initial=initial)
    return render(request, 'line_inspection/simple_form.html', {'form': form, 'title': 'Follow-up question'})


@auth.admin_required
def criticality_rule_form(request, pk=None):
    instance = get_object_or_404(CriticalityRule, pk=pk) if pk else None
    if request.method == 'POST':
        form = CriticalityRuleForm(request.POST, instance=instance)
        if form.is_valid():
            form.save()
            CatalogVersion.bump()
            messages.success(request, 'Criticality rule saved.')
            return redirect('line_inspection:checklist-editor')
    else:
        form = CriticalityRuleForm(instance=instance)
    return render(request, 'line_inspection/simple_form.html', {'form': form, 'title': 'Criticality rule'})


@auth.admin_required
def checklist_delete(request, model_name, pk):
    model_map = {
        'group': ChecklistItemGroup, 'item': ChecklistItem, 'defect': Defect,
        'followup': FollowUpQuestion, 'rule': CriticalityRule,
    }
    model = model_map.get(model_name)
    if model and request.method == 'POST':
        model.objects.filter(pk=pk).delete()
        CatalogVersion.bump()
        messages.success(request, 'Deleted.')
    return redirect('line_inspection:checklist-editor')


# ---------------------------------------------------------------------------
# SAP <-> ArcGIS line mapping
# ---------------------------------------------------------------------------

@auth.admin_required
def sap_mapping(request):
    if request.method == 'POST':
        action = request.POST.get('action')
        if action == 'auto_map':
            call_command('map_sap_lines')
            messages.success(request, 'Auto-mapping run complete.')
        elif action == 'set_mapping':
            line = get_object_or_404(Line, pk=request.POST.get('line_id'))
            line.sap_line_id = request.POST.get('sap_line_id') or None
            try:
                # Atomic so a unique-violation rolls back cleanly instead of
                # leaving the connection in an aborted-transaction state.
                with transaction.atomic(using='line_inspection_db'):
                    line.save(update_fields=['sap_line'])
                messages.success(request, f'Updated mapping for {line.name}.')
            except IntegrityError:
                messages.error(request, 'That SAP line is already mapped to another ArcGIS line — clear the existing mapping first.')
        elif action == 'add_sap_line':
            form = SapLineForm(request.POST)
            if form.is_valid():
                form.save()
                messages.success(request, 'SAP line added.')
        return redirect('line_inspection:sap-mapping')

    query = request.GET.get('q', '').strip()
    lines = Line.objects.filter(is_active=True).select_related('sap_line').order_by('name')
    if query:
        lines = lines.filter(name__icontains=query)

    all_sap_lines = list(SapLine.objects.all())
    rows = []
    for line in lines[:300]:
        suggestions = [] if line.sap_line_id else find_best_matches(line, all_sap_lines, top_n=3)
        rows.append({'line': line, 'suggestions': suggestions})

    context = {
        'rows': rows,
        'query': query,
        'all_sap_lines': all_sap_lines,
        'unmatched_count': Line.objects.filter(sap_line=None, is_active=True).count(),
        'matched_count': Line.objects.exclude(sap_line=None).count(),
        'sap_line_form': SapLineForm(),
    }
    return render(request, 'line_inspection/sap_mapping.html', context)


# ---------------------------------------------------------------------------
# LILO (Loop-In Loop-Out) — Super Admin only. Rare, explicitly triggered.
# ---------------------------------------------------------------------------

@auth.super_admin_required
def lilo_home(request):
    if request.method == 'POST' and request.POST.get('action') == 'create_lilo':
        old_line = get_object_or_404(Line, pk=request.POST.get('old_line_id'))
        event = LiloEvent.objects.create(
            old_line=old_line, lilo_date=request.POST.get('lilo_date') or None,
            notes=request.POST.get('notes', ''), performed_by_employee_id=request.session['employee_id'],
        )
        event.new_lines.set(Line.objects.filter(pk__in=request.POST.getlist('new_line_ids')))
        messages.success(request, f'LILO #{event.pk} recorded — review the tower reconcile.')
        return redirect('line_inspection:lilo-reconcile', pk=event.pk)

    lines = list(Line.objects.filter(is_active=True).order_by('name').values('id', 'name', 'voltage'))
    context = {
        'events': (LiloEvent.objects.select_related('old_line').prefetch_related('new_lines')
                   .order_by('-created_at')[:50]),
        'lines_json': json.dumps(lines),
        'churn_flags': lm.detect_churn(),
        # prefill (from a churn flag's "Start LILO" link)
        'prefill_old': request.GET.get('old_line', ''),
        'prefill_new': request.GET.get('new_line', ''),
    }
    return render(request, 'line_inspection/lilo.html', context)


@auth.super_admin_required
def lilo_reconcile(request, pk):
    event = get_object_or_404(LiloEvent, pk=pk)
    if request.method == 'POST' and request.POST.get('action') == 'apply':
        proposal = lm.propose_matches(event)
        decisions = {}
        for pair in proposal['pairs']:
            nid = pair['new_tower'].id
            val = request.POST.get(f'decision_{nid}', '')
            if val.startswith('match:'):
                decisions[nid] = int(val.split(':', 1)[1])
            elif val == 'new':
                decisions[nid] = None
        summary = lm.apply_reconcile(event, decisions)
        event.applied_at = timezone.now()
        event.save(update_fields=['applied_at'])
        messages.success(request, f"Applied: {summary['matched']} tower(s) re-linked (history preserved), "
                                  f"{summary['new']} new.")
        return redirect('line_inspection:lilo-home')

    return render(request, 'line_inspection/lilo_reconcile.html',
                  {'event': event, 'proposal': lm.propose_matches(event)})
