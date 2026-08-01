import json
import math

from django.db import transaction
from django.db.models import Count, Q
from django.utils import timezone
from rest_framework import generics, status
from rest_framework.negotiation import DefaultContentNegotiation
from rest_framework.exceptions import PermissionDenied, ValidationError
from rest_framework.permissions import AllowAny, IsAuthenticated
from rest_framework.response import Response
from rest_framework.views import APIView

from .. import exports
from .. import jurisdiction
from .. import viewing
from .. import status as tower_status
from .. import auth
from ..auth import is_admin
from ..models import (
    ChecklistItemGroup, FollowUpQuestion, Line, Tower, Subdivision, Inspection, ItemResult, DefectEntry,
    ChecklistItem, Defect, DefectTicket, SupportRequest, CatalogVersion, CriticalityRule,
    MobileAuthToken, PRESENCE_RADIUS_M, TICKET_STATUS_CHOICES, attach_defect_counts,
)
from ..services import keycloak_client, checkcred_client
from ..services.keycloak_client import KeycloakClientError
from ..services.checkcred_client import CheckCredError
from ..services.criticality import suggest_criticality, worst_of
from .authentication import (
    SessionEmployeeAuthentication, MobileTokenAuthentication, KeycloakBearerAuthentication,
)
from .serializers import (
    ChecklistItemGroupSerializer, FollowUpQuestionSerializer, MobileCriticalityRuleSerializer,
    LineSerializer, TowerSerializer, MobileTowerSerializer, SubdivisionSerializer,
    InspectionCreateSerializer, MobileInspectionCreateSerializer, InspectionSerializer,
    MobileInspectionSummarySerializer, DefectTicketSerializer, SupportRequestSerializer,
)

# The mobile `Token` class is first so DRF's 401-vs-403 decision uses its
# `authenticate_header` ('Token') — a bad/revoked/expired token then returns
# 401 (which the app treats as "session expired → re-login") rather than 403.
# Each class declines a header that isn't its scheme, so they still coexist:
# a browser request with only a session cookie falls through to the session
# class, and a Keycloak `Bearer` token to the Keycloak class.
AUTH_CLASSES = [MobileTokenAuthentication, SessionEmployeeAuthentication, KeycloakBearerAuthentication]


def _haversine_m(lat1, lng1, lat2, lng2):
    """Great-circle distance in metres between two lat/lng points."""
    r = 6371000.0
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(a)))


def _identity_profile(employee_id):
    """The role/scope block returned by login and /auth/me/, reusing the same
    resolution the web session + context processor use."""
    return {
        'employee_id': employee_id,
        'is_admin': auth.is_admin(employee_id),
        'is_super_admin': auth.is_super_admin(employee_id),
        'cadre': viewing.display_label(employee_id),
        'tier': viewing.cadre_tier(employee_id),
        'is_management': viewing.is_management(employee_id),
    }


class HealthView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request):
        return Response({'status': 'ok'})


class PingView(APIView):
    """Reachability probe the Flutter app hits before login (no auth)."""
    authentication_classes = []
    permission_classes = [AllowAny]

    def get(self, request):
        return Response({'ok': True, 'time': timezone.now().isoformat()})


# ---------------------------------------------------------------------------
# Mobile auth (Phase 4) — DB-backed revocable token issued after the legacy
# checkCred service verifies the employee's credentials. Keycloak stays dormant.
# ---------------------------------------------------------------------------

class MobileLoginView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]

    def post(self, request):
        user_id = str(request.data.get('user_id') or '').strip()
        passwd = str(request.data.get('passwd') or '')
        try:
            identity = checkcred_client.verify_credentials(user_id, passwd)
        except CheckCredError as exc:
            return Response({'error': str(exc)}, status=401)

        token = MobileAuthToken.objects.create(
            key=MobileAuthToken.generate_key(),
            employee_id=identity['employee_id'],
            display_name=identity.get('display_name') or identity['employee_id'],
        )
        profile = _identity_profile(identity['employee_id'])
        profile.update({'token': token.key, 'display_name': token.display_name})
        return Response(profile, status=status.HTTP_201_CREATED)


class MobileLogoutView(APIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if isinstance(request.auth, MobileAuthToken):
            request.auth.revoke()
        return Response({'ok': True})


class MobileMeView(APIView):
    """Lets the app re-hydrate identity/role on launch from a stored token."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        profile = _identity_profile(request.user.employee_id)
        if isinstance(request.auth, MobileAuthToken):
            profile['display_name'] = request.auth.display_name
        return Response(profile)


# ---------------------------------------------------------------------------
# Keycloak auth (thin wrappers over services/keycloak_client.py — same
# contract shape as gisapp's, so the Phase 4 Flutter app integration is a
# drop-in against this API instead)
# ---------------------------------------------------------------------------

class KeycloakExchangeView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]

    def post(self, request):
        code = str(request.data.get('code') or '').strip()
        redirect_uri = str(request.data.get('redirect_uri') or '').strip()
        if not code or not redirect_uri:
            return Response({'error': 'code and redirect_uri are required.'}, status=400)
        try:
            return Response(keycloak_client.exchange_code(code, redirect_uri))
        except KeycloakClientError as exc:
            return Response({'error': str(exc)}, status=401)


class KeycloakRefreshView(APIView):
    authentication_classes = []
    permission_classes = [AllowAny]

    def post(self, request):
        refresh_token = str(request.data.get('refresh_token') or '').strip()
        if not refresh_token:
            return Response({'error': 'refresh_token is required.'}, status=400)
        try:
            return Response(keycloak_client.refresh(refresh_token))
        except KeycloakClientError as exc:
            return Response({'error': str(exc)}, status=401)


# ---------------------------------------------------------------------------
# Checklist catalog (read-only)
# ---------------------------------------------------------------------------

class CatalogView(APIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        groups = ChecklistItemGroup.objects.prefetch_related('items__defects__criticality_rules').all()
        version_row = CatalogVersion.objects.filter(pk=1).first()
        rules = CriticalityRule.objects.select_related('defect').all()
        version = CatalogVersion.current()
        return Response({
            # Mobile keys: `version` + `updated_at` + top-level `criticality_rules`.
            'version': version,
            'updated_at': version_row.updated_at.isoformat() if version_row else None,
            'criticality_rules': MobileCriticalityRuleSerializer(rules, many=True).data,
            # Kept for back-compat with any existing consumer of the old shape.
            'catalog_version': version,
            'groups': ChecklistItemGroupSerializer(groups, many=True).data,
            'follow_up_questions': FollowUpQuestionSerializer(FollowUpQuestion.objects.all(), many=True).data,
        })


# ---------------------------------------------------------------------------
# GIS master data — jurisdiction-filtered, never client-trusted filters
# ---------------------------------------------------------------------------

MAX_LIST = 500


class SubdivisionListView(APIView):
    """Subdivisions in the viewer's oversight scope (management sees all) — the
    mobile login/scope picker."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        employee_id = request.user.employee_id
        # Kept as an explicit branch rather than folded into oversight_lines:
        # deriving it from the lines would silently drop a subdivision that has no
        # active line yet, and the scope picker should still offer it.
        if viewing.is_management(employee_id):
            qs = Subdivision.objects.all()
        else:
            sub_ids = viewing.oversight_lines(employee_id).values_list('subdivision_id', flat=True)
            qs = Subdivision.objects.filter(id__in=[s for s in sub_ids if s])
        return Response(SubdivisionSerializer(qs.order_by('name'), many=True).data)


class LineListView(generics.ListAPIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]
    serializer_class = LineSerializer

    def get_queryset(self):
        # Field app: reads are oversight-scoped (== own jurisdiction for a leaf
        # AEE/DEE; widened for supervisors). The write path stays own-scope.
        # *_including_ranges so a line held only by a from/to-tower range grant
        # still appears here — Home's map fetches each line's towers off this
        # list, and LineTowerListView narrows a range-only line back down to
        # just the granted stretch, so listing it here is safe.
        qs = viewing.oversight_lines_including_ranges(
            self.request.user.employee_id).select_related('subdivision')
        search = self.request.query_params.get('search')
        if search:
            qs = qs.filter(name__icontains=search)
        subdivision = self.request.query_params.get('subdivision')
        if subdivision:
            qs = qs.filter(subdivision_id=subdivision)
        return qs.order_by('name')[:MAX_LIST]


class TowerListView(generics.ListAPIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]
    serializer_class = MobileTowerSerializer

    def get_queryset(self):
        qs = viewing.oversight_towers(self.request.user.employee_id)
        line_id = self.request.query_params.get('line')
        if line_id:
            qs = qs.filter(line_id=line_id)
        return qs.order_by('line_sequence', 'tower_number')


class LineTowerListView(generics.ListAPIView):
    """GET /lines/<line_id>/towers/ — towers on one line, oversight-scoped."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]
    serializer_class = MobileTowerSerializer

    def get_queryset(self):
        return (viewing.oversight_towers(self.request.user.employee_id)
                .filter(line_id=self.kwargs['line_id'])
                .order_by('line_sequence', 'tower_number'))


# ---------------------------------------------------------------------------
# Map data — reporting-hierarchy OVERSIGHT scope (viewing.py), NOT the
# own-assignment jurisdiction scope above. Security invariant: every queryset
# starts from viewing.oversight_* and is only NARROWED by bbox/line, so a
# forged bbox can never surface a tower outside the viewer's reporting subtree.
# ---------------------------------------------------------------------------

MAX_MAP_TOWERS = 5000


def _parse_bbox(raw):
    """'xmin,ymin,xmax,ymax' (lng,lat,lng,lat) -> tuple of floats, or None."""
    if not raw:
        return None
    parts = raw.split(',')
    if len(parts) != 4:
        return None
    try:
        return tuple(float(p) for p in parts)
    except ValueError:
        return None


class MapLineListView(APIView):
    """GeoJSON of the lines in the viewer's oversight scope — small (<=1,212),
    loaded once for the overview and fitBounds. Each feature carries a tower
    rollup computed from the denormalized Tower cache (no Inspection join)."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        lines = list(viewing.oversight_lines(request.user.employee_id).select_related('subdivision'))
        line_ids = [line.id for line in lines]

        counts = {}
        for row in (Tower.objects.filter(line_id__in=line_ids, is_active=True, is_virtual=False)
                    .values('line_id', 'last_worst_criticality')):
            bucket = counts.setdefault(row['line_id'], {'total': 0, 'inspected': 0})
            bucket['total'] += 1
            if row['last_worst_criticality'] != 'none':
                bucket['inspected'] += 1

        features = []
        for line in lines:
            if not line.geometry:
                continue
            bucket = counts.get(line.id, {'total': 0, 'inspected': 0})
            features.append({
                'type': 'Feature',
                'geometry': line.geometry,
                'properties': {
                    'id': line.id, 'name': line.name, 'voltage': line.voltage,
                    'subdivision': line.subdivision.name if line.subdivision_id else '',
                    'total_towers': bucket['total'], 'inspected_towers': bucket['inspected'],
                },
            })
        return Response({'type': 'FeatureCollection', 'features': features})


class MapTowerListView(APIView):
    """GeoJSON of towers in the viewer's oversight scope, narrowed by bbox
    and/or line, capped at MAX_MAP_TOWERS with a `truncated` flag. Status colour
    comes from the denormalized Tower cache; when an inspection_type filter is
    given, per-cycle status is recomputed from the Inspection table (the
    Ground-Patrol vs PMI provision)."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        qs = viewing.oversight_towers(request.user.employee_id, geocoded_only=True)

        line_id = request.query_params.get('line')
        if line_id:
            qs = qs.filter(line_id=line_id)

        bbox = _parse_bbox(request.query_params.get('bbox'))
        if bbox:
            xmin, ymin, xmax, ymax = bbox
            qs = qs.filter(longitude__gte=xmin, longitude__lte=xmax,
                           latitude__gte=ymin, latitude__lte=ymax)

        status_filter = request.query_params.get('status')
        inspection_type = request.query_params.get('inspection_type')

        if inspection_type:
            capped_ids = list(qs.values_list('id', flat=True)[:MAX_MAP_TOWERS + 1])
            truncated = len(capped_ids) > MAX_MAP_TOWERS
            capped_ids = capped_ids[:MAX_MAP_TOWERS]
            status_by_tower = tower_status.latest_inspection_status(capped_ids, inspection_type=inspection_type)
            rows = qs.filter(id__in=capped_ids).values(
                'id', 'tower_number', 'tower_type', 'voltage', 'line_id', 'latitude', 'longitude')
            features = []
            for row in rows:
                st = status_by_tower.get(row['id'], 'none')
                if status_filter and st != status_filter:
                    continue
                features.append(self._feature(row, st))
            return Response({'type': 'FeatureCollection', 'truncated': truncated, 'features': features})

        if status_filter:
            qs = qs.filter(last_worst_criticality=status_filter)
        rows = list(qs.values(
            'id', 'tower_number', 'tower_type', 'voltage', 'line_id', 'latitude', 'longitude',
            'last_worst_criticality')[:MAX_MAP_TOWERS + 1])
        truncated = len(rows) > MAX_MAP_TOWERS
        features = [self._feature(row, row['last_worst_criticality']) for row in rows[:MAX_MAP_TOWERS]]
        return Response({'type': 'FeatureCollection', 'truncated': truncated, 'features': features})

    @staticmethod
    def _feature(row, st):
        return {
            'type': 'Feature',
            'geometry': {'type': 'Point', 'coordinates': [row['longitude'], row['latitude']]},
            'properties': {
                'id': row['id'], 'tower_number': row['tower_number'], 'tower_type': row['tower_type'],
                'voltage': row['voltage'], 'line_id': row['line_id'], 'status': st,
            },
        }


class TowerDetailView(APIView):
    """Tower master detail + every circuit/line strung on the same physical
    structure (via structure_key). Scoped to the viewer's oversight towers
    (real only). Backs the map pop-up's 'circuits on this structure' list."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        tower = viewing.oversight_towers(request.user.employee_id).filter(pk=pk).select_related('line').first()
        if not tower:
            return Response({'error': 'Not found or outside your jurisdiction.'}, status=404)
        circuits = [
            {'id': line.id, 'name': line.name, 'voltage': line.voltage, 'circuit_type': line.circuit_type}
            for line in viewing.circuits_at(tower)
        ]
        return Response({
            'id': tower.id, 'tower_number': tower.tower_number, 'tower_type': tower.tower_type,
            'cp_sp': tower.cp_sp, 'voltage': tower.voltage, 'is_virtual': tower.is_virtual,
            'tower_ckts_conductor': tower.tower_ckts_conductor, 'circuit_type': tower.circuit_type,
            'circuit_count': tower.circuit_count, 'conductor_type': tower.conductor_type,
            'no_of_conductors_per_phase': tower.no_of_conductors_per_phase,
            'insulator_type': tower.insulator_type, 'type_of_earthing': tower.type_of_earthing,
            'line_name': tower.line_name, 'line_id': tower.line_id,
            'subdivision_name': tower.subdivision_name, 'structure_key': tower.structure_key,
            'latitude': tower.latitude, 'longitude': tower.longitude,
            'last_worst_criticality': tower.last_worst_criticality,
            'last_inspection_at': tower.last_inspection_at,
            'circuits': circuits,
        })


# ---------------------------------------------------------------------------
# Inspections
# ---------------------------------------------------------------------------

def _resolve_item(ref):
    """A checklist item by numeric pk (mobile payload) or slug key (JSON API)."""
    if isinstance(ref, int) or (isinstance(ref, str) and ref.isdigit()):
        return ChecklistItem.objects.filter(pk=int(ref)).first()
    return ChecklistItem.objects.filter(key=ref).first()


def _resolve_defect(item, ref):
    if isinstance(ref, int) or (isinstance(ref, str) and ref.isdigit()):
        return Defect.objects.filter(item=item, pk=int(ref)).first()
    return Defect.objects.filter(item=item, key=ref).first()


def _assign_photo(instance, photo_key, files):
    """Attach an uploaded file part (named by photo_key) to an ImageField."""
    if not photo_key or not files:
        return
    upload = files.get(photo_key)
    if upload is not None:
        instance.photo = upload
        instance.save(update_fields=['photo'])


def _create_inspection(employee_id, data, files=None):
    """Atomic nested create: Inspection + ItemResults + DefectEntries, then
    auto-raises one DefectTicket per entry. Accepts BOTH the JSON API shape
    (`tower`/`item_results` with slug `item`/`defect` keys) and the mobile
    multipart shape (`tower_id`/`items` with numeric `item_id`/`defect_id` +
    `photo_key` + GPS proof). Raises ValidationError on any unresolvable
    item/defect so the whole thing rolls back cleanly."""
    files = files or {}
    tower_pk = data.get('tower', data.get('tower_id'))
    tower = Tower.objects.filter(pk=tower_pk).first()
    if not tower:
        raise ValidationError({'tower': 'Tower not found.'})
    if tower.is_virtual:
        raise ValidationError({'tower': 'Virtual (VT) towers are not inspected — inspect the real co-located tower.'})
    # Open to any authenticated employee by default — see
    # settings.LINE_INSPECTION_OPEN_INSPECT. This only ever refuses when that
    # flag is turned off; ticket close keeps its own scoping below.
    if not jurisdiction.can_inspect_tower(employee_id, tower):
        raise PermissionDenied("You don't have jurisdiction over this tower.")

    items = data.get('item_results', data.get('items')) or []

    # GPS proof of presence: recompute distance server-side against the tower's
    # stored coordinates (never trust a client-sent distance) and stamp the flag.
    # Only GPS-aware (mobile) submits carry a fix or a presence_flag; the legacy
    # JSON create path sends neither and is exempt from the presence gate.
    lat = data.get('inspector_lat')
    lng = data.get('inspector_lng')
    override_reason = (data.get('override_reason') or '').strip()
    gps_aware = lat is not None or lng is not None or bool(data.get('presence_flag'))
    distance_m = None
    if gps_aware:
        if lat is not None and lng is not None and tower.latitude is not None and tower.longitude is not None:
            distance_m = _haversine_m(lat, lng, tower.latitude, tower.longitude)
        if lat is None or lng is None:
            presence_flag = 'no_fix'
        elif distance_m is not None and distance_m <= PRESENCE_RADIUS_M:
            presence_flag = 'in_range'
        else:
            presence_flag = 'out_of_range'
        if presence_flag != 'in_range' and not override_reason:
            raise ValidationError({'override_reason':
                'An out-of-range or no-GPS inspection requires an override reason (presence is required).'})
    else:
        presence_flag = ''

    now = timezone.now()
    with transaction.atomic():
        inspection = Inspection.objects.create(
            client_id=data.get('client_id'),
            tower=tower,
            inspector_employee_id=employee_id,
            catalog_version=data.get('catalog_version') or CatalogVersion.current(),
            date=data.get('date') or now.date(),
            inspection_type=data.get('inspection_type'),
            remarks=data.get('remarks', ''),
            saved_at=now,
            inspector_lat=lat,
            inspector_lng=lng,
            gps_accuracy_m=data.get('gps_accuracy_m'),
            gps_distance_m=distance_m,
            presence_flag=presence_flag,
            override_reason=override_reason,
        )

        all_criticalities = []
        new_tickets = []
        for item_data in items:
            item_ref = item_data.get('item', item_data.get('item_id'))
            item = _resolve_item(item_ref)
            if not item:
                raise ValidationError({'items': f"Unknown checklist item: {item_ref}"})

            item_result = ItemResult.objects.create(
                inspection=inspection, item=item, position=item_data.get('position', ''),
                status=item_data['status'], meta=item_data.get('meta', {}),
            )
            _assign_photo(item_result, item_data.get('photo_key'), files)

            for entry_data in item_data.get('entries', []):
                defect_ref = entry_data.get('defect', entry_data.get('defect_id'))
                defect = _resolve_defect(item, defect_ref)
                if not defect:
                    raise ValidationError({'items': f"Unknown defect {defect_ref} for item {item.key}"})

                answers = entry_data.get('answers', {})
                suggested = suggest_criticality(defect, answers)
                final = entry_data.get('criticality') or suggested

                entry = DefectEntry.objects.create(
                    item_result=item_result, defect=defect, answers=answers,
                    suggested_criticality=suggested, criticality=final, note=entry_data.get('note', ''),
                )
                _assign_photo(entry, entry_data.get('photo_key'), files)
                all_criticalities.append(final)
                new_tickets.append(DefectTicket(
                    inspection=inspection, tower=tower, item=item, item_label=item.label,
                    position=item_data.get('position', ''), defect=defect, defect_label=defect.label,
                    answers=answers, criticality=final, status='open', source='human_inspection',
                    raised_at=now, raised_by_employee_id=employee_id,
                ))

        inspection.worst_criticality = worst_of(all_criticalities) if all_criticalities else 'ok'
        inspection.save(update_fields=['worst_criticality'])
        DefectTicket.objects.bulk_create(new_tickets)

        # Phase 3: advance the tower's denormalized status cache in the same
        # transaction so the map/rollups reflect this inspection immediately.
        tower_status.bump_tower_cache(tower, now, inspection.worst_criticality, inspection.inspection_type)

    return inspection


class InspectionCreateView(APIView):
    """POST /inspection/api/inspections/ — same client_id idempotency
    contract as the reference Flutter app's backend: same client_id on
    retry returns the existing record (200), a new one creates (201)."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def post(self, request):
        serializer = InspectionCreateSerializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        client_id = data.get('client_id')
        if client_id:
            existing = Inspection.objects.filter(client_id=client_id).first()
            if existing:
                return Response(InspectionSerializer(existing).data, status=status.HTTP_200_OK)

        inspection = _create_inspection(request.user.employee_id, data)
        return Response(InspectionSerializer(inspection, context={'request': request}).data,
                        status=status.HTTP_201_CREATED)


def _submit_result(inspection):
    """Compact submit response the Flutter app expects."""
    return {
        'id': inspection.id,
        'tower_id': inspection.tower_id,
        'worst_criticality': inspection.worst_criticality,
        'date': inspection.date,
        'client_id': inspection.client_id,
        'saved_at': inspection.saved_at,
        'tickets_raised': inspection.tickets.count(),
    }


class LineInspectionSubmitView(APIView):
    """POST /line-inspections/ (multipart) — the mobile submit. One text field
    `payload` (JSON) + zero-or-more file parts named by each item/entry
    `photo_key` (photo_0, photo_1, …). Idempotent on client_id (200 replay /
    201 new). Reuses the same atomic core as the JSON create endpoint."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def post(self, request):
        if 'multipart' in (request.content_type or '') and 'payload' in request.data:
            try:
                payload = json.loads(request.data['payload'])
            except (TypeError, ValueError):
                return Response({'error': 'Invalid payload JSON.'}, status=400)
        else:
            payload = request.data  # allow a plain JSON body too

        serializer = MobileInspectionCreateSerializer(data=payload)
        serializer.is_valid(raise_exception=True)
        data = serializer.validated_data

        client_id = data.get('client_id')
        if client_id:
            existing = Inspection.objects.filter(client_id=client_id).first()
            if existing:
                return Response(_submit_result(existing), status=status.HTTP_200_OK)

        inspection = _create_inspection(request.user.employee_id, data, files=request.FILES)
        return Response(_submit_result(inspection), status=status.HTTP_201_CREATED)


class InspectionListView(generics.ListAPIView):
    """JSON-API history (legacy path) — own-jurisdiction scope."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]
    serializer_class = InspectionSerializer

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx

    def get_queryset(self):
        visible_tower_ids = jurisdiction.visible_towers(self.request.user.employee_id).values_list('id', flat=True)
        qs = Inspection.objects.filter(tower_id__in=visible_tower_ids).order_by('-saved_at')
        tower_id = self.request.query_params.get('tower')
        if tower_id:
            qs = qs.filter(tower_id=tower_id)
        return qs.prefetch_related('item_results__entries')


def _mobile_inspection_scope(request):
    """Oversight-scoped inspection queryset for the mobile list/detail, narrowed
    by ?subdivision / ?line / ?tower / ?inspector.

    Every filter here only ever NARROWS the oversight scope, so none of them can
    surface an inspection the viewer may not see.

    `?inspector` is optional and off by default. The History tab deliberately
    does NOT pass it: `inspector_employee_id` records who captured an
    inspection, and supervisors do not capture — their subordinates do — so
    filtering on it hid a whole level's work from the DEE/EE/SE responsible for
    it while the dashboard rollup kept counting it. It stays available for
    callers that genuinely want one employee's own rows."""
    tower_ids = viewing.oversight_towers(request.user.employee_id).values_list('id', flat=True)
    qs = Inspection.objects.filter(tower_id__in=tower_ids)
    subdivision = request.query_params.get('subdivision')
    if subdivision:
        qs = qs.filter(tower__line__subdivision_id=subdivision)
    line = request.query_params.get('line')
    if line:
        qs = qs.filter(tower__line_id=line)
    tower = request.query_params.get('tower')
    if tower:
        qs = qs.filter(tower_id=tower)
    inspector = (request.query_params.get('inspector') or '').strip()
    if inspector:
        # Case-insensitive: the id reaches this column via SAP and the login
        # payload, and a difference in case must not silently return nothing.
        qs = qs.filter(inspector_employee_id__iexact=inspector)
    return qs


class MobileInspectionListView(APIView):
    """GET /line-inspections/list/ — oversight-scoped summaries with defect_count."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        # Page first, count second (attach_defect_counts): annotating the count
        # inside this query grouped the viewer's whole history before the LIMIT
        # could discard it.
        rows = attach_defect_counts(
            _mobile_inspection_scope(request)
            .select_related('tower')
            .order_by('-saved_at')[:MAX_LIST]
        )
        return Response(MobileInspectionSummarySerializer(rows, many=True).data)


class MobileInspectionDetailView(APIView):
    """GET /line-inspections/<pk>/ — full detail, oversight-scoped."""
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request, pk):
        tower_ids = viewing.oversight_towers(request.user.employee_id).values_list('id', flat=True)
        inspection = (Inspection.objects.filter(pk=pk, tower_id__in=tower_ids)
                      .select_related('tower').prefetch_related('item_results__entries').first())
        if not inspection:
            return Response({'detail': 'Not found or outside your jurisdiction.'}, status=404)
        return Response(InspectionSerializer(inspection, context={'request': request}).data)


# ---------------------------------------------------------------------------
# Defect tickets
# ---------------------------------------------------------------------------

def _mobile_ticket_scope(request):
    """Oversight-scoped, newest-first ticket queryset narrowed by
    ?status / ?subdivision / ?line / ?tower — unsliced.

    Extracted from the list view so the Tickets tab's export renders the *same*
    backlog the tab is showing: two copies of this filter chain would eventually
    disagree, and a download that quietly differs from the screen it was taken
    from is worse than no download. Like the inspection scope above, every filter
    only ever narrows, so none of them can surface a ticket the viewer may not
    see.
    """
    tower_ids = viewing.oversight_towers(request.user.employee_id).values_list('id', flat=True)
    qs = DefectTicket.objects.filter(tower_id__in=tower_ids).select_related('tower').order_by('-raised_at')
    status_param = request.query_params.get('status')
    if status_param:
        qs = qs.filter(status=status_param)
    subdivision = request.query_params.get('subdivision')
    if subdivision:
        qs = qs.filter(tower__line__subdivision_id=subdivision)
    line = request.query_params.get('line')
    if line:
        qs = qs.filter(tower__line_id=line)
    tower = request.query_params.get('tower')
    if tower:
        qs = qs.filter(tower_id=tower)
    return qs


class DefectTicketListView(generics.ListAPIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]
    serializer_class = DefectTicketSerializer

    def get_queryset(self):
        return _mobile_ticket_scope(self.request)[:1000]


class DefectTicketCloseView(APIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        ticket = DefectTicket.objects.filter(pk=pk).first()
        if not ticket:
            return Response({'error': 'Not found.'}, status=404)
        employee_id = request.user.employee_id
        # Closing is a supervisory sign-off ("attended and rectified"), not field
        # capture, so it follows the reporting hierarchy rather than the narrow
        # own-assignment scope that gates recording an inspection:
        #
        #   * admins            — any ticket (they grant jurisdiction to others)
        #   * own assignment    — an AEE closes defects on the towers they hold
        #   * oversight         — a DEE/EE/SE closes defects raised by the people
        #                         reporting to them, on towers in their subtree
        #
        # Without the third clause a supervisor could see a defect (the ticket
        # list is oversight-scoped) but never sign it off, because tickets are
        # stamped with whoever submitted the inspection and supervisors do not
        # capture inspections. The own-assignment clause is kept alongside
        # oversight rather than replaced by it, so nobody loses a permission they
        # already had — see viewing.oversees_tower on the edge cases that differ.
        #
        # NB: recording an inspection deliberately does NOT widen this way — it is
        # presence-gated fieldwork. See _create_inspection.
        if not (
            is_admin(employee_id)
            or jurisdiction.can_edit_tower(employee_id, ticket.tower)
            or viewing.oversees_tower(employee_id, ticket.tower)
        ):
            raise PermissionDenied("You don't have jurisdiction over this ticket's tower.")
        if ticket.status == 'closed':
            return Response(DefectTicketSerializer(ticket).data)

        ticket.status = 'closed'
        ticket.closed_at = timezone.now()
        ticket.closed_by_employee_id = request.user.employee_id
        ticket.close_note = request.data.get('close_note', 'Attended and rectified')
        ticket.save(update_fields=['status', 'closed_at', 'closed_by_employee_id', 'close_note'])
        return Response(DefectTicketSerializer(ticket).data)


# ---------------------------------------------------------------------------
# Report downloads (History / Tickets → Excel, PDF)
# ---------------------------------------------------------------------------

class FileDownloadNegotiation(DefaultContentNegotiation):
    """Content negotiation for the endpoints whose `?format=` names a *file*
    type rather than a renderer.

    DRF reserves `?format=` for renderer selection (`URL_FORMAT_OVERRIDE`), and
    its `filter_renderers` raises `Http404` when no registered renderer matches
    the value. There is no renderer called `xlsx` or `pdf`, so
    `?format=xlsx` returned **404 before the view ever ran** — every download
    from the app would have failed while the endpoint looked correct in
    isolation.

    The parameter keeps its name because the web register export already spells
    it `format` (`dashboard_views.register_view`), and one convention across the
    two surfaces is worth more than deferring to a DRF default that does not
    apply here. So negotiation yields instead: the renderer is chosen from the
    Accept header alone. That only ever decides how the JSON *error* bodies are
    rendered — a successful download returns a plain `HttpResponse`, which
    bypasses rendering entirely.
    """

    def filter_renderers(self, renderers, format):
        return renderers


def _export_format(request):
    """The requested `?format=`, validated. Defaults to xlsx.

    Raises [ValidationError] rather than quietly substituting a default, so a
    typo in the format returns a readable 400 instead of the wrong file type.
    """
    fmt = (request.query_params.get('format') or 'xlsx').lower()
    if fmt not in exports.FORMATS:
        raise ValidationError({
            'format': f"Unsupported format '{fmt}'. Use one of: "
                      f"{', '.join(sorted(exports.FORMATS))}.",
        })
    return fmt


def _export_scope_label(employee_id):
    """The provenance line on a report: who pulled it, and the jurisdiction it
    covers. Matches the app's own scope bar wording (`jurisdictionLabel`), so a
    downloaded report names the same scope the screen it came from did."""
    cadre = viewing.display_label(employee_id)
    who = f'{employee_id} · {cadre}' if cadre else str(employee_id)
    if viewing.is_management(employee_id):
        return f'{who} · all towers (management scope)'
    return f'{who} · your oversight scope'


def _named(model, pk, field='name'):
    """A referenced row's label for the report header, falling back to the raw id
    when it cannot be resolved — a header line must never be the thing that fails
    an export."""
    if not pk:
        return ''
    row = model.objects.filter(pk=pk).values_list(field, flat=True).first()
    return row or f'#{pk}'


class MobileInspectionExportView(APIView):
    """GET /line-inspections/export/?format=xlsx|pdf — the History tab's download.

    Renders exactly what `/line-inspections/list/` returns (same scope helper,
    same `-saved_at` order) as a tabular report. It takes the same
    ?subdivision/?line/?tower/?inspector filters, so a narrowed tab exports a
    narrowed report.

    **Server records only.** Inspections still sitting in the app's offline
    outbox have not reached this process, so they cannot appear in the file. The
    app says so before it starts a download while anything is pending, rather
    than letting a report look like a complete day's work when it is not.
    """
    content_negotiation_class = FileDownloadNegotiation
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        fmt = _export_format(request)
        employee_id = request.user.employee_id
        report = exports.inspection_report(
            _mobile_inspection_scope(request).order_by('-saved_at'),
            scope_label=_export_scope_label(employee_id),
            filters=[
                ('Subdivision', _named(Subdivision, request.query_params.get('subdivision'))),
                ('Line', _named(Line, request.query_params.get('line'))),
                ('Tower', _named(Tower, request.query_params.get('tower'), 'tower_number')),
                ('Inspector', (request.query_params.get('inspector') or '').strip()),
            ],
        )
        return exports.attachment(report, fmt)


class DefectTicketExportView(APIView):
    """GET /tickets/export/?format=xlsx|pdf — the Tickets tab's download.

    Shares `_mobile_ticket_scope` with the list endpoint, so the file holds the
    same backlog under the same ?status/?subdivision/?line/?tower filters the tab
    is showing. Ordered newest-first (the server's order) rather than by the
    triage order the tab sorts into on screen: a report that will be filtered and
    sorted again in Excel is more useful in a stable chronological order, and the
    criticality is a column the reader can sort on themselves.
    """
    content_negotiation_class = FileDownloadNegotiation
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        fmt = _export_format(request)
        employee_id = request.user.employee_id
        status_param = (request.query_params.get('status') or '').strip()
        report = exports.ticket_report(
            _mobile_ticket_scope(request),
            scope_label=_export_scope_label(employee_id),
            filters=[
                ('Status', dict(TICKET_STATUS_CHOICES).get(status_param, status_param) or 'All'),
                ('Subdivision', _named(Subdivision, request.query_params.get('subdivision'))),
                ('Line', _named(Line, request.query_params.get('line'))),
                ('Tower', _named(Tower, request.query_params.get('tower'), 'tower_number')),
            ],
        )
        return exports.attachment(report, fmt)


# ---------------------------------------------------------------------------
# Support requests
# ---------------------------------------------------------------------------

class SupportRequestListCreateView(generics.ListCreateAPIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]
    serializer_class = SupportRequestSerializer

    def get_serializer_context(self):
        ctx = super().get_serializer_context()
        ctx['request'] = self.request
        return ctx

    def get_queryset(self):
        # Own requests, plus (for an admin/supervisor) requests raised in a
        # subdivision within their oversight scope.
        employee_id = self.request.user.employee_id
        own = Q(raised_by_employee_id=employee_id)
        sub_ids = list(viewing.oversight_lines(employee_id).values_list('subdivision_id', flat=True))
        sub_ids = [s for s in sub_ids if s]
        scope = own | Q(subdivision_id__in=sub_ids) if sub_ids else own
        qs = SupportRequest.objects.filter(scope).select_related('subdivision')
        subdivision = self.request.query_params.get('subdivision')
        if subdivision:
            qs = qs.filter(subdivision_id=subdivision)
        return qs.order_by('-created_at')

    def create(self, request, *args, **kwargs):
        serializer = self.get_serializer(data=request.data)
        serializer.is_valid(raise_exception=True)
        employee_id = request.user.employee_id
        data = serializer.validated_data
        # Content-match dedup (matches the reference backend / the app's retry
        # semantics): an existing OPEN request with the same subject+text from
        # this employee returns 200 rather than duplicating.
        existing = SupportRequest.objects.filter(
            raised_by_employee_id=employee_id, status='open',
            subject=data.get('subject', ''), text=data.get('text', ''),
        ).first()
        if existing:
            return Response(SupportRequestSerializer(existing, context={'request': request}).data,
                            status=status.HTTP_200_OK)
        obj = serializer.save(raised_by_employee_id=employee_id)
        return Response(SupportRequestSerializer(obj, context={'request': request}).data,
                        status=status.HTTP_201_CREATED)


class SupportRequestResolveView(APIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def post(self, request, pk):
        support_request = SupportRequest.objects.filter(pk=pk).first()
        if not support_request:
            return Response({'error': 'Not found.'}, status=404)
        support_request.status = 'resolved'
        support_request.response = request.data.get('response', 'Done')
        support_request.resolved_by_employee_id = request.user.employee_id
        support_request.resolved_at = timezone.now()
        support_request.save(update_fields=['status', 'response', 'resolved_by_employee_id', 'resolved_at'])
        return Response(SupportRequestSerializer(support_request, context={'request': request}).data)


# ---------------------------------------------------------------------------
# Mobile dashboard (Home-tab KPIs) — reuses the Tower.last_* cache + ticket
# aggregation, in the shape the Flutter DashboardData model expects.
# ---------------------------------------------------------------------------

class MobileDashboardView(APIView):
    authentication_classes = AUTH_CLASSES
    permission_classes = [IsAuthenticated]

    def get(self, request):
        employee_id = request.user.employee_id
        subdivision = request.query_params.get('subdivision')

        # All-tower for management viewers, own subtree otherwise — the branch
        # lives in viewing.oversight_towers now, so this total can no longer
        # disagree with the line list and the map that the same app screen reads.
        towers = viewing.oversight_towers(employee_id)
        if subdivision:
            towers = towers.filter(line__subdivision_id=subdivision)

        agg = towers.aggregate(
            total=Count('id'),
            inspected=Count('id', filter=Q(last_inspection_at__isnull=False)),
            minor=Count('id', filter=Q(last_worst_criticality='minor')),
            major=Count('id', filter=Q(last_worst_criticality='major')),
            critical=Count('id', filter=Q(last_worst_criticality='critical')),
        )
        total = agg['total'] or 0
        inspected = agg['inspected'] or 0

        tickets = DefectTicket.objects.filter(tower__in=towers)
        # Both totals in one pass. Two .count() calls meant running the tower
        # scope subquery twice to answer the same question.
        ticket_totals = tickets.aggregate(
            open=Count('id', filter=Q(status='open')),
            closed=Count('id', filter=Q(status='closed')),
        )
        open_total = ticket_totals['open'] or 0
        closed_total = ticket_totals['closed'] or 0

        by_component = list(
            tickets.filter(status='open').values('item_label')
            .annotate(count=Count('id')).order_by('-count')[:10]
        )

        # Per-line rollup from the tower cache + open-ticket counts.
        line_rows = (towers.exclude(line_id__isnull=True).values('line_id', 'line__name').annotate(
            tower_count=Count('id'),
            inspected=Count('id', filter=Q(last_inspection_at__isnull=False)),
        ).order_by('line__name'))
        open_by_line = {
            r['tower__line_id']: r['open'] for r in
            tickets.filter(status='open').values('tower__line_id').annotate(open=Count('id'))
        }
        lines = [{
            'line_id': r['line_id'], 'name': r['line__name'] or '',
            'tower_count': r['tower_count'], 'inspected': r['inspected'],
            'pct': round(r['inspected'] / r['tower_count'] * 100) if r['tower_count'] else 0,
            'open_defects': open_by_line.get(r['line_id'], 0),
        } for r in line_rows]

        payload = {
            'tower_total': total,
            'inspected': inspected,
            'coverage_pct': round(inspected / total * 100) if total else 0,
            'open_total': open_total,
            'closed_total': closed_total,
            'criticality': {'critical': agg['critical'] or 0, 'major': agg['major'] or 0, 'minor': agg['minor'] or 0},
            'by_component': [{'item': r['item_label'], 'count': r['count']} for r in by_component],
            'lines': lines,
        }

        # HQ/management view (no subdivision filter) also gets a per-subdivision roll.
        if not subdivision and viewing.is_management(employee_id):
            sub_rows = (towers.exclude(subdivision_id__isnull=True)
                        .values('subdivision_id', 'subdivision__name').annotate(
                            tower_count=Count('id'),
                            inspected=Count('id', filter=Q(last_inspection_at__isnull=False)),
                            critical=Count('id', filter=Q(last_worst_criticality='critical')),
                        ).order_by('subdivision__name'))
            open_by_sub = {
                r['tower__subdivision_id']: r['open'] for r in
                tickets.filter(status='open').values('tower__subdivision_id').annotate(open=Count('id'))
            }
            payload['subdivisions'] = [{
                'id': r['subdivision_id'], 'name': r['subdivision__name'] or '',
                'tower_count': r['tower_count'], 'inspected': r['inspected'],
                'open': open_by_sub.get(r['subdivision_id'], 0), 'critical': r['critical'],
            } for r in sub_rows]

        return Response(payload)
