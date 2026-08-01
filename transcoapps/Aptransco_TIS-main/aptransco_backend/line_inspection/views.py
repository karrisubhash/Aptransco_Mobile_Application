"""API views for the line-inspection platform (clear schema).

Endpoints (all under /api/):
  GET  catalog/                      full questionnaire catalog (+ version)
  GET  lines/?search=&subdivision=   transmission lines (for the line selector)
  GET  lines/<line_id>/towers/       towers on a line (for the Loc No selector)
  GET  towers/<tower_id>/            single tower context
  POST line-inspections/            create an inspection (+ item results,
                                     defect entries, and open defect tickets)
"""
import json
import logging
import os
import uuid
from datetime import timedelta

from django.core.files.storage import default_storage
from django.db import transaction, IntegrityError
from django.db.models import Count
from django.utils import timezone
from rest_framework import status
from rest_framework.response import Response
from rest_framework.views import APIView

from .models import (
    CatalogVersion, ChecklistItemGroup, ChecklistItem, Defect,
    FollowUpQuestion, CriticalityRule, Line, Tower, Subdivision,
    Inspection, ItemResult, DefectEntry, DefectTicket, SupportRequest,
)
from .serializers import (
    ChecklistItemGroupSerializer, FollowUpQuestionSerializer,
    CriticalityRuleSerializer, LineSerializer, TowerSerializer,
    SubdivisionSerializer, InspectionListSerializer, InspectionDetailSerializer,
    TicketSerializer, SupportRequestSerializer,
)

log = logging.getLogger('inspections')

# Ordering used to roll individual defect criticalities up to an inspection's
# worst_criticality. Mirrors the POC's CRIT_ORDER.
CRIT_ORDER = {'none': 0, 'ok': 1, 'minor': 2, 'major': 3, 'critical': 4}


def _worst(criticalities):
    worst = 'ok'
    for c in criticalities:
        if CRIT_ORDER.get(c, 0) > CRIT_ORDER.get(worst, 0):
            worst = c
    return worst


class PingView(APIView):
    """A tiny, DB-free reachability probe. The mobile app hits this to tell a
    genuine internet/backend connection apart from a mere link-layer connection
    (Wi-Fi joined but no route to the server) before deciding it is "online" and
    flushing its offline queue."""

    def get(self, request):
        return Response({'ok': True, 'time': timezone.now()})

    def head(self, request):
        return Response(status=status.HTTP_200_OK)


def _save_photo(request, key):
    """Persist an uploaded photo referenced by `key` (a multipart file part
    name embedded in the payload as `photo_key`). Returns the stored relative
    path (fits the varchar(100) `photo` columns) or None."""
    if not key:
        return None
    f = request.FILES.get(key)
    if not f:
        return None
    ext = os.path.splitext(f.name or '')[1].lower()
    if not ext or len(ext) > 5:
        ext = '.jpg'
    return default_storage.save(f'inspections/li/{uuid.uuid4().hex}{ext}', f)


class CatalogView(APIView):
    """The whole questionnaire in one payload — it's small (5 groups, 25 items,
    ~75 defects, 22 questions, 16 rules) and the app caches it by version."""

    def get(self, request):
        version_row = CatalogVersion.objects.order_by('-version').first()
        groups = ChecklistItemGroup.objects.prefetch_related(
            'items__defects'
        ).all()
        return Response({
            'version': version_row.version if version_row else 0,
            'updated_at': version_row.updated_at if version_row else None,
            'groups': ChecklistItemGroupSerializer(groups, many=True).data,
            'follow_up_questions': FollowUpQuestionSerializer(
                FollowUpQuestion.objects.all(), many=True).data,
            'criticality_rules': CriticalityRuleSerializer(
                CriticalityRule.objects.select_related('defect').all(),
                many=True).data,
        })


class LineListView(APIView):
    """Transmission lines for the line selector. Supports ?search= (name
    contains) and ?subdivision= (exact subdivision_name)."""

    def get(self, request):
        qs = Line.objects.all()
        search = request.query_params.get('search', '').strip()
        subdivision = request.query_params.get('subdivision', '').strip()
        if search:
            qs = qs.filter(name__icontains=search)
        if subdivision:
            qs = qs.filter(subdivision_name=subdivision)
        qs = qs[:500]  # guardrail; refine with search rather than dumping 1200+
        return Response(LineSerializer(qs, many=True).data)


class LineTowersView(APIView):
    """Towers on one line, ordered by tower number — the Loc No selector."""

    def get(self, request, line_id):
        qs = Tower.objects.filter(line_id=line_id)
        return Response(TowerSerializer(qs, many=True).data)


class TowerDetailView(APIView):
    def get(self, request, tower_id):
        try:
            tower = Tower.objects.get(pk=tower_id)
        except Tower.DoesNotExist:
            return Response({'detail': 'Tower not found'},
                            status=status.HTTP_404_NOT_FOUND)
        return Response(TowerSerializer(tower).data)


class InspectionCreateView(APIView):
    """Create one inspection for a tower.

    Body (JSON)::

        {
          "tower_id": 46072,
          "inspector_employee_id": "1073164",
          "catalog_version": 1,          // optional; defaults to latest
          "date": "2026-07-22",          // optional; defaults to today
          "remarks": "",
          "client_id": "uuid",           // optional idempotency key
          "items": [
            {"item_id": 1, "position": "", "status": "defect", "meta": {},
             "entries": [
               {"defect_id": 1, "answers": {...}, "criticality": "major",
                "suggested_criticality": "major", "note": ""}
             ]}
          ]
        }

    Every recorded defect entry is also raised as an open DefectTicket.
    """

    def post(self, request):
        # Photos ride along as multipart file parts; the structured inspection
        # then arrives as a JSON string in the `payload` field. A plain JSON
        # body (no photos) is still accepted as-is.
        if request.content_type and 'multipart' in request.content_type:
            raw = request.data.get('payload')
            try:
                data = json.loads(raw) if raw else {}
            except (TypeError, ValueError):
                return Response({'detail': 'Invalid payload JSON'},
                                status=status.HTTP_400_BAD_REQUEST)
        else:
            data = request.data
        tower_id = data.get('tower_id')
        if not tower_id:
            return Response({'detail': 'tower_id is required'},
                            status=status.HTTP_400_BAD_REQUEST)
        try:
            tower = Tower.objects.get(pk=tower_id)
        except Tower.DoesNotExist:
            return Response({'detail': 'Tower not found'},
                            status=status.HTTP_404_NOT_FOUND)

        client_id = (data.get('client_id') or '').strip() or None

        # Idempotency: a replayed submit (offline re-sync, timeout retry)
        # returns the already-saved inspection instead of duplicating.
        if client_id:
            existing = Inspection.objects.filter(client_id=client_id).first()
            if existing:
                return Response(self._result(existing),
                                status=status.HTTP_200_OK)

        inspector = (data.get('inspector_employee_id') or '').strip() or 'unknown'
        items_in = data.get('items') or []

        # Resolve labels once for the tickets we may raise.
        item_ids = {i.get('item_id') for i in items_in if i.get('item_id')}
        defect_ids = {
            e.get('defect_id')
            for i in items_in for e in (i.get('entries') or [])
            if e.get('defect_id')
        }
        item_map = {it.id: it for it in
                    ChecklistItem.objects.filter(id__in=item_ids)}
        defect_map = {d.id: d for d in
                      Defect.objects.filter(id__in=defect_ids)}

        # catalog_version fallback
        catalog_version = data.get('catalog_version')
        if catalog_version is None:
            latest = CatalogVersion.objects.order_by('-version').first()
            catalog_version = latest.version if latest else 0

        # date fallback
        date = data.get('date') or timezone.now().date().isoformat()

        all_crit = [
            e.get('criticality', 'ok')
            for i in items_in for e in (i.get('entries') or [])
        ]
        worst = _worst(all_crit)
        now = timezone.now()

        try:
            with transaction.atomic(using='clear_db'):
                inspection = Inspection.objects.create(
                    tower=tower,
                    inspector_employee_id=inspector,
                    catalog_version=catalog_version,
                    date=date,
                    remarks=data.get('remarks', '') or '',
                    worst_criticality=worst,
                    saved_at=now,
                    created_at=now,
                    client_id=client_id,
                )

                ticket_count = 0
                for item_in in items_in:
                    item_id = item_in.get('item_id')
                    if not item_id:
                        continue
                    item_obj = item_map.get(item_id)
                    result = ItemResult.objects.create(
                        inspection=inspection,
                        item_id=item_id,
                        position=item_in.get('position', '') or '',
                        status=item_in.get('status', 'normal'),
                        meta=item_in.get('meta') or {},
                        photo=_save_photo(request, item_in.get('photo_key')),
                    )
                    for entry in (item_in.get('entries') or []):
                        defect_id = entry.get('defect_id')
                        if not defect_id:
                            continue
                        defect_obj = defect_map.get(defect_id)
                        crit = entry.get('criticality', 'minor')
                        suggested = entry.get('suggested_criticality', crit)
                        answers = entry.get('answers') or {}
                        DefectEntry.objects.create(
                            item_result=result,
                            defect_id=defect_id,
                            answers=answers,
                            suggested_criticality=suggested,
                            criticality=crit,
                            note=entry.get('note', '') or '',
                            photo=_save_photo(request, entry.get('photo_key')),
                            created_at=now,
                        )
                        DefectTicket.objects.create(
                            tower=tower,
                            inspection=inspection,
                            item_id=item_id,
                            defect_id=defect_id,
                            item_label=item_obj.label if item_obj else '',
                            position=item_in.get('position', '') or '',
                            defect_label=defect_obj.label if defect_obj else '',
                            answers=answers,
                            criticality=crit,
                            status='open',
                            source='inspection',
                            drone_metadata=None,
                            raised_at=now,
                            raised_by_employee_id=inspector,
                            closed_at=None,
                            closed_by_employee_id='',
                            close_note='',
                        )
                        ticket_count += 1
        except IntegrityError:
            # A concurrent replay of the same submit (same client_id) can slip
            # past the pre-check above and lose the race on the unique
            # constraint. The row the winner committed is the canonical save —
            # return it with 200 instead of a spurious 400 to the retry.
            if client_id:
                existing = Inspection.objects.filter(client_id=client_id).first()
                if existing:
                    return Response(self._result(existing),
                                    status=status.HTTP_200_OK)
            log.exception('Integrity error saving line inspection')
            return Response({'detail': 'Could not save inspection (conflict)'},
                            status=status.HTTP_409_CONFLICT)
        except Exception as exc:  # noqa: BLE001 - surface a clean 400
            log.exception('Failed to save line inspection')
            return Response({'detail': f'Could not save inspection: {exc}'},
                            status=status.HTTP_400_BAD_REQUEST)

        payload = self._result(inspection)
        payload['tickets_raised'] = ticket_count
        return Response(payload, status=status.HTTP_201_CREATED)

    @staticmethod
    def _result(inspection):
        return {
            'id': inspection.id,
            'tower_id': inspection.tower_id,
            'worst_criticality': inspection.worst_criticality,
            'date': inspection.date,
            'client_id': inspection.client_id,
            'saved_at': inspection.saved_at,
        }


# ===========================================================================
# Records, tickets, support & dashboard (the remaining POC tabs)
# ===========================================================================
class SubdivisionListView(APIView):
    def get(self, request):
        return Response(
            SubdivisionSerializer(Subdivision.objects.all(), many=True).data)


class InspectionListView(APIView):
    """Inspection records, newest first. Filters: ?subdivision= (id), ?line=
    (id), ?tower= (id). Each row carries its defect_count."""

    def get(self, request):
        qs = (Inspection.objects.select_related('tower')
              .annotate(defect_count=Count('item_results__entries'))
              .order_by('-saved_at', '-created_at'))
        sd = request.query_params.get('subdivision')
        line = request.query_params.get('line')
        tower = request.query_params.get('tower')
        if sd:
            qs = qs.filter(tower__subdivision_id=sd)
        if line:
            qs = qs.filter(tower__line_id=line)
        if tower:
            qs = qs.filter(tower_id=tower)
        return Response(InspectionListSerializer(qs[:500], many=True).data)


class InspectionDetailView(APIView):
    def get(self, request, pk):
        try:
            insp = (Inspection.objects.select_related('tower')
                    .prefetch_related('item_results__entries__defect',
                                      'item_results__item__group')
                    .get(pk=pk))
        except Inspection.DoesNotExist:
            return Response({'detail': 'Not found'},
                            status=status.HTTP_404_NOT_FOUND)
        return Response(InspectionDetailSerializer(insp).data)


class TicketListView(APIView):
    """Defect tickets. Filters: ?status=open|closed, ?subdivision= (id),
    ?line= (id), ?tower= (id)."""

    def get(self, request):
        qs = DefectTicket.objects.select_related('tower').order_by('-raised_at')
        st = request.query_params.get('status')
        sd = request.query_params.get('subdivision')
        line = request.query_params.get('line')
        tower = request.query_params.get('tower')
        if st in ('open', 'closed'):
            qs = qs.filter(status=st)
        if sd:
            qs = qs.filter(tower__subdivision_id=sd)
        if line:
            qs = qs.filter(tower__line_id=line)
        if tower:
            qs = qs.filter(tower_id=tower)
        return Response(TicketSerializer(qs[:1000], many=True).data)


class TicketCloseView(APIView):
    """Close a defect ticket with a resolution note."""

    def post(self, request, pk):
        try:
            t = DefectTicket.objects.get(pk=pk)
        except DefectTicket.DoesNotExist:
            return Response({'detail': 'Not found'},
                            status=status.HTTP_404_NOT_FOUND)
        if t.status != 'closed':
            t.status = 'closed'
            t.closed_at = timezone.now()
            t.closed_by_employee_id = (request.data.get('closed_by') or 'unknown')[:32]
            t.close_note = request.data.get('close_note') or 'Attended'
            t.save(update_fields=['status', 'closed_at',
                                  'closed_by_employee_id', 'close_note'])
        return Response(TicketSerializer(t).data)


class SupportRequestListCreateView(APIView):
    def get(self, request):
        qs = (SupportRequest.objects.select_related('subdivision')
              .order_by('-created_at'))
        sd = request.query_params.get('subdivision')
        if sd:
            qs = qs.filter(subdivision_id=sd)
        return Response(SupportRequestSerializer(qs[:500], many=True).data)

    def post(self, request):
        d = request.data
        raised_by = (d.get('raised_by_employee_id') or 'unknown')[:32]
        category = (d.get('category') or '')[:255]
        subject = (d.get('subject') or '')[:255]
        text = d.get('text') or ''

        # Idempotency for the offline queue: a request that was committed but
        # whose response never reached the phone gets retried on reconnect. The
        # SupportRequest table (external `clear` schema) has no client_id column
        # to key on, so fall back to a short-window content match — an identical
        # open request from the same person within the last 10 minutes is treated
        # as the same submission and returned instead of duplicated.
        recent = SupportRequest.objects.filter(
            raised_by_employee_id=raised_by,
            subject=subject,
            text=text,
            category=category,
            status='open',
            created_at__gte=timezone.now() - timedelta(minutes=10),
        ).order_by('-created_at').first()
        if recent:
            return Response(SupportRequestSerializer(recent).data,
                            status=status.HTTP_200_OK)

        sr = SupportRequest.objects.create(
            raised_by_employee_id=raised_by,
            category=category,
            subject=subject,
            text=text,
            status='open',
            created_at=timezone.now(),
            response='',
            resolved_by_employee_id='',
            resolved_at=None,
            subdivision_id=d.get('subdivision_id'),
        )
        return Response(SupportRequestSerializer(sr).data,
                        status=status.HTTP_201_CREATED)


class SupportRequestResolveView(APIView):
    def post(self, request, pk):
        try:
            sr = SupportRequest.objects.get(pk=pk)
        except SupportRequest.DoesNotExist:
            return Response({'detail': 'Not found'},
                            status=status.HTTP_404_NOT_FOUND)
        sr.status = 'resolved'
        sr.response = request.data.get('response') or 'Resolved'
        sr.resolved_by_employee_id = (request.data.get('resolved_by') or 'unknown')[:32]
        sr.resolved_at = timezone.now()
        sr.save(update_fields=['status', 'response',
                               'resolved_by_employee_id', 'resolved_at'])
        return Response(SupportRequestSerializer(sr).data)


class DashboardView(APIView):
    """Aggregated stats for the dashboard, scoped by ?subdivision= (id). With
    no subdivision it's the Head-Office (all) view and includes a per-subdivision
    roll-up. Line progress is capped (see below)."""

    def get(self, request):
        sd = request.query_params.get('subdivision')
        towers = Tower.objects.all()
        inspections = Inspection.objects.all()
        tickets = DefectTicket.objects.all()
        if sd:
            towers = towers.filter(subdivision_id=sd)
            inspections = inspections.filter(tower__subdivision_id=sd)
            tickets = tickets.filter(tower__subdivision_id=sd)

        tower_total = towers.count()
        inspected = inspections.values('tower_id').distinct().count()
        coverage = round(inspected / tower_total * 100) if tower_total else 0

        open_tickets = tickets.filter(status='open')
        closed_total = tickets.filter(status='closed').count()
        open_total = open_tickets.count()

        crit = {'critical': 0, 'major': 0, 'minor': 0}
        for r in open_tickets.values('criticality').annotate(n=Count('id')):
            if r['criticality'] in crit:
                crit[r['criticality']] = r['n']

        by_component = [
            {'item': r['item_label'], 'count': r['n']}
            for r in (open_tickets.values('item_label')
                      .annotate(n=Count('id')).order_by('-n')[:20])
        ]

        # Line-wise progress (capped): towers + inspected towers per line.
        tower_by_line = {r['line_id']: r['n'] for r in
                         towers.values('line_id').annotate(n=Count('id'))}
        insp_by_line = {r['tower__line_id']: r['n'] for r in
                        inspections.values('tower__line_id')
                        .annotate(n=Count('tower_id', distinct=True))}
        opendef_by_line = {r['tower__line_id']: r['n'] for r in
                           open_tickets.values('tower__line_id')
                           .annotate(n=Count('id'))}
        line_rows = []
        for line_id, tc in tower_by_line.items():
            if line_id is None:
                continue
            done = insp_by_line.get(line_id, 0)
            line_rows.append({
                'line_id': line_id,
                'tower_count': tc,
                'inspected': done,
                'pct': round(done / tc * 100) if tc else 0,
                'open_defects': opendef_by_line.get(line_id, 0),
            })
        # Prioritise lines with activity; cap the payload.
        line_rows.sort(key=lambda r: (r['inspected'], r['open_defects'],
                                      r['tower_count']), reverse=True)
        line_rows = line_rows[:100]
        names = {l.id: l.name for l in
                 Line.objects.filter(id__in=[r['line_id'] for r in line_rows])}
        for r in line_rows:
            r['name'] = names.get(r['line_id'], f"Line {r['line_id']}")

        payload = {
            'tower_total': tower_total,
            'inspected': inspected,
            'coverage_pct': coverage,
            'open_total': open_total,
            'closed_total': closed_total,
            'criticality': crit,
            'by_component': by_component,
            'lines': line_rows,
        }

        # Head-Office roll-up (only in the all-subdivisions view).
        if not sd:
            t_by_sd = {r['subdivision_id']: r['n'] for r in
                       Tower.objects.values('subdivision_id')
                       .annotate(n=Count('id'))}
            i_by_sd = {r['tower__subdivision_id']: r['n'] for r in
                       Inspection.objects.values('tower__subdivision_id')
                       .annotate(n=Count('tower_id', distinct=True))}
            o_by_sd = {r['tower__subdivision_id']: r['n'] for r in
                       DefectTicket.objects.filter(status='open')
                       .values('tower__subdivision_id').annotate(n=Count('id'))}
            c_by_sd = {r['tower__subdivision_id']: r['n'] for r in
                       DefectTicket.objects.filter(status='open',
                                                   criticality='critical')
                       .values('tower__subdivision_id').annotate(n=Count('id'))}
            subs = []
            for s in Subdivision.objects.all():
                tc = t_by_sd.get(s.id, 0)
                if not tc:
                    continue
                subs.append({
                    'id': s.id, 'name': s.name,
                    'tower_count': tc,
                    'inspected': i_by_sd.get(s.id, 0),
                    'open': o_by_sd.get(s.id, 0),
                    'critical': c_by_sd.get(s.id, 0),
                })
            payload['subdivisions'] = subs

        return Response(payload)
