"""line_inspection domain models.

All tables for this app live in the shared Postgres server's `clear` schema
(see transcoapps/settings.py: DATABASES['line_inspection_db'] + the
LineInspectionRouter in db_router.py) — no other schema on that server is
read or written by this app.

Sections:
  1. GIS master data synced from ArcGIS (Subdivision/Line/Tower/Substation)
  2. Checklist catalog — DB-backed and editable, not hardcoded Python, since
     the questionnaire is not yet finalised and will be revised after field
     engineers review the app.
  3. Cadre / role / jurisdiction — no django.contrib.auth. Identity is a bare
     SAP employee_id resolved via Keycloak; authorization is our own
     RoleAssignment model, gated by FieldEECadrePosition eligibility.
  4. Transactional inspection data.
"""
import secrets
from datetime import timedelta

from django.db import models
from django.utils import timezone


# ---------------------------------------------------------------------------
# 1. GIS master data (synced from ArcGIS — see management/commands/sync_gis_towers.py)
# ---------------------------------------------------------------------------

class Subdivision(models.Model):
    name = models.CharField(max_length=255, unique=True)
    circle = models.CharField(max_length=255, blank=True)
    division = models.CharField(max_length=255, blank=True)
    zone = models.CharField(max_length=255, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    updated_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return self.name


VOLTAGE_CHOICES = [
    ('132kV', '132kV'),
    ('220kV', '220kV'),
    ('400kV', '400kV'),
]

# Worst-case status of a tower/inspection. Defined here (not further down) so
# the Tower denormalized status cache can reference it. 'none' == never inspected.
WORST_CHOICES = [
    ('none', 'Not inspected'),
    ('ok', 'Normal'),
    ('minor', 'Minor'),
    ('major', 'Major'),
    ('critical', 'Critical'),
]

# Each tower is inspected twice a year: Ground Patrolling (routine, non-detailed)
# and Pre-Monsoon Inspection (PMI, detailed). Nullable everywhere for now — the
# Flutter app (Phase 4) will start stamping it; existing rows stay NULL (unknown).
INSPECTION_TYPE_CHOICES = [
    ('ground_patrol', 'Ground Patrolling'),
    ('pmi', 'Pre-Monsoon Inspection'),
]

# Phase 4 — GPS proof-of-presence outcome stamped on each Inspection. Presence is
# the utmost criterion for field inspection: the mobile app enforces a 50 m gate
# with an audited override, and the server records which case applied.
PRESENCE_FLAG_CHOICES = [
    ('in_range', 'In range (<=50 m)'),
    ('out_of_range', 'Out of range (overridden)'),
    ('no_fix', 'No GPS fix (overridden)'),
]
PRESENCE_RADIUS_M = 50.0


class SapLine(models.Model):
    """Raw SAP line master data (see management/commands/import_sap_lines.py).
    Importing this creates NO mapping by itself — Line.sap_line is populated
    separately by map_sap_lines.py / the SAP<->ArcGIS mapping admin page."""
    functional_location = models.CharField(max_length=64, unique=True)  # SAP "Functional Location" code
    description = models.CharField(max_length=255, blank=True)  # SAP "Description of functional location"
    voltage = models.CharField(max_length=16, blank=True)  # parsed from functional_location/description, not an enum (raw SAP data)
    raw_row = models.JSONField(default=dict, blank=True)
    imported_at = models.DateTimeField(auto_now=True)

    def __str__(self):
        return f'{self.functional_location} — {self.description}'


class Line(models.Model):
    source_layer = models.CharField(max_length=64)  # e.g. 'lines-220kv'
    arcgis_object_id = models.CharField(max_length=64)
    name = models.CharField(max_length=255, blank=True)
    voltage = models.CharField(max_length=16, choices=VOLTAGE_CHOICES)
    line_length = models.CharField(max_length=64, blank=True)
    circuit_type = models.CharField(max_length=255, blank=True)
    date_of_commissioning = models.CharField(max_length=64, blank=True)

    zone = models.CharField(max_length=255, blank=True)
    circle = models.CharField(max_length=255, blank=True)
    division = models.CharField(max_length=255, blank=True)
    subdivision_name = models.CharField(max_length=255, blank=True)
    subdivision = models.ForeignKey(Subdivision, on_delete=models.SET_NULL, null=True, blank=True, related_name='lines')

    # Populated by map_sap_lines.py (auto-match) or manually via the SAP<->ArcGIS mapping page.
    # OneToOneField enforces one-to-one SAP<->ArcGIS line mapping. In Postgres a nullable unique
    # column allows unlimited NULLs, so the many still-unmapped lines are fine; it only forbids
    # mapping the same SapLine to two Lines. Surrogate `id` stays the PK (SAP codes can change
    # / lines get LILO-split, so the natural key must stay non-PK).
    sap_line = models.OneToOneField(SapLine, on_delete=models.SET_NULL, null=True, blank=True, related_name='line')

    geometry = models.JSONField(null=True, blank=True)  # raw GeoJSON geometry
    raw_properties = models.JSONField(default=dict, blank=True)  # every ArcGIS field, untouched

    is_active = models.BooleanField(default=True)
    first_synced_at = models.DateTimeField(auto_now_add=True)
    last_synced_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=['source_layer', 'arcgis_object_id'], name='uniq_line_source_object'),
        ]
        indexes = [models.Index(fields=['name'])]

    def __str__(self):
        return self.name or f'Line #{self.arcgis_object_id}'


class Tower(models.Model):
    source_layer = models.CharField(max_length=64)  # e.g. 'towers-132kv'
    arcgis_object_id = models.CharField(max_length=64)
    tower_number = models.CharField(max_length=64, blank=True)
    tower_type = models.CharField(max_length=64, blank=True)  # real domain values, not assumed
    voltage = models.CharField(max_length=16, choices=VOLTAGE_CHOICES)

    # --- Asset master, promoted from the ArcGIS tower layers (see Gunadala export) ---
    cp_sp = models.CharField(max_length=32, blank=True)                     # CP / SP / Boom (structure role)
    tower_ckts_conductor = models.CharField(max_length=128, blank=True)     # e.g. 'DCT, 2C, ACFR Panther'
    circuit_type = models.CharField(max_length=32, blank=True)              # SC / DC / MC / 'DC/SC'
    circuit_count = models.SmallIntegerField(null=True, blank=True)         # parsed 1/2/4 (SCT/DCT/MCT · 1C/2C/4C)
    conductor_type = models.CharField(max_length=64, blank=True)            # ArcGIS 'conductor_type' (Excel "Type of conductor")
    no_of_conductors_per_phase = models.IntegerField(null=True, blank=True)  # bundle size per phase (not the circuit count)
    relay_setting_length_in_km = models.CharField(max_length=32, blank=True)
    span_km = models.FloatField(null=True, blank=True)                      # only reliably populated on 132kV
    date_of_commissioning = models.CharField(max_length=64, blank=True)

    # Manually maintained — empty/absent in ArcGIS, so never written by the sync.
    insulator_type = models.CharField(max_length=128, blank=True)
    type_of_earthing = models.CharField(max_length=128, blank=True)

    # Virtual-tower / physical-structure model: a VT row is another circuit strung on the
    # same physical structure as a real tower, linked by coordinate co-location. structure_key
    # groups every real + co-located VT row into one physical structure; only real towers
    # (is_virtual=False) are inspected. See management/commands/sync_gis_towers.py.
    is_virtual = models.BooleanField(default=False)
    structure_key = models.CharField(max_length=64, blank=True)

    # Ordered position of this tower along its line (the "tower schedule"), assigned by
    # management/commands/build_tower_schedule.py (geometry projection, tower_number fallback).
    # line_offset_m = perpendicular distance from the line polyline (QA / branch detection).
    # Ranges (LineTowerAssignment) reference boundary towers, not this raw value, so a rebuild
    # can't drift an assigned stretch.
    line_sequence = models.PositiveIntegerField(null=True, blank=True)
    line_offset_m = models.FloatField(null=True, blank=True)

    line_name = models.CharField(max_length=255, blank=True)  # as returned by ArcGIS (text, not FK)
    line = models.ForeignKey(Line, on_delete=models.SET_NULL, null=True, blank=True, related_name='towers')

    latitude = models.FloatField(null=True, blank=True)
    longitude = models.FloatField(null=True, blank=True)

    zone = models.CharField(max_length=255, blank=True)
    circle = models.CharField(max_length=255, blank=True)
    division = models.CharField(max_length=255, blank=True)
    subdivision_name = models.CharField(max_length=255, blank=True)
    subdivision = models.ForeignKey(Subdivision, on_delete=models.SET_NULL, null=True, blank=True, related_name='towers')

    geometry = models.JSONField(null=True, blank=True)
    raw_properties = models.JSONField(default=dict, blank=True)

    is_active = models.BooleanField(default=True)
    first_synced_at = models.DateTimeField(auto_now_add=True)
    last_synced_at = models.DateTimeField(auto_now=True)

    # Phase 3 denormalized inspection-status cache, maintained in
    # api.views._create_inspection (advanced only when a newer inspection lands).
    # Lets the map/rollup hot paths colour and count ~67k towers without a
    # per-tower Inspection subquery. Rebuildable from Inspection at any time.
    last_inspection_at = models.DateTimeField(null=True, blank=True)
    last_worst_criticality = models.CharField(max_length=16, choices=WORST_CHOICES, default='none')
    last_inspection_type = models.CharField(max_length=16, choices=INSPECTION_TYPE_CHOICES, null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=['source_layer', 'arcgis_object_id'], name='uniq_tower_source_object'),
        ]
        indexes = [
            models.Index(fields=['tower_number']),
            models.Index(fields=['line_name']),
            models.Index(fields=['last_inspection_at']),
            models.Index(fields=['voltage', 'is_active']),
            models.Index(fields=['structure_key']),
            models.Index(fields=['line', 'line_sequence']),
        ]

    def __str__(self):
        return f'{self.line_name} · Tower {self.tower_number}'


class Substation(models.Model):
    source_layer = models.CharField(max_length=64)  # e.g. 'substations-400kv'
    arcgis_object_id = models.CharField(max_length=64)
    name = models.CharField(max_length=255, blank=True)
    voltage = models.CharField(max_length=16, choices=VOLTAGE_CHOICES)

    latitude = models.FloatField(null=True, blank=True)
    longitude = models.FloatField(null=True, blank=True)

    zone = models.CharField(max_length=255, blank=True)
    circle = models.CharField(max_length=255, blank=True)
    division = models.CharField(max_length=255, blank=True)
    subdivision_name = models.CharField(max_length=255, blank=True)
    subdivision = models.ForeignKey(Subdivision, on_delete=models.SET_NULL, null=True, blank=True, related_name='substations')

    geometry = models.JSONField(null=True, blank=True)
    raw_properties = models.JSONField(default=dict, blank=True)

    is_active = models.BooleanField(default=True)
    first_synced_at = models.DateTimeField(auto_now_add=True)
    last_synced_at = models.DateTimeField(auto_now=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=['source_layer', 'arcgis_object_id'], name='uniq_substation_source_object'),
        ]
        indexes = [models.Index(fields=['name'])]

    def __str__(self):
        return self.name or f'Substation #{self.arcgis_object_id}'


# ---------------------------------------------------------------------------
# 2. Checklist catalog — DB-backed & editable (not finalised; will change
#    after field engineers review the app, so this must not require a code
#    deploy to edit).
# ---------------------------------------------------------------------------

class CatalogVersion(models.Model):
    """Singleton counter bumped whenever any catalog table below changes, and
    stamped onto each Inspection so historical records stay traceable to the
    catalog shape that produced them."""
    version = models.PositiveIntegerField(default=1)
    updated_at = models.DateTimeField(auto_now=True)

    @classmethod
    def current(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        return obj.version

    @classmethod
    def bump(cls):
        obj, _ = cls.objects.get_or_create(pk=1)
        obj.version += 1
        obj.save(update_fields=['version', 'updated_at'])
        return obj.version


class ChecklistItemGroup(models.Model):
    key = models.SlugField(max_length=64, unique=True)
    label = models.CharField(max_length=255)
    sort_order = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ['sort_order']

    def __str__(self):
        return self.label


class ChecklistItem(models.Model):
    group = models.ForeignKey(ChecklistItemGroup, on_delete=models.PROTECT, related_name='items')
    key = models.SlugField(max_length=64, unique=True)
    sno = models.PositiveIntegerField()
    label = models.CharField(max_length=255)
    sort_order = models.PositiveIntegerField(default=0)

    # positions e.g. ["Top", "Middle", "Bottom"] or ["Top","Middle","Bottom","Earth wire"]; [] = not positional
    positions = models.JSONField(default=list, blank=True)
    pos_meta = models.JSONField(null=True, blank=True)  # e.g. {"id": "insType", "label": ..., "options": [...], "default": ...}

    is_availability_gated = models.BooleanField(default=False)
    is_position_availability_gated = models.BooleanField(default=False)

    # tower_type values this item applies to, e.g. ["DA"]; [] / null = applies to all tower types.
    # Data-driven on purpose: editing this list changes N/A logic without a code change.
    applicable_tower_types = models.JSONField(default=list, blank=True)
    na_reason = models.CharField(max_length=255, blank=True)

    class Meta:
        ordering = ['sort_order']

    def __str__(self):
        return f'{self.sno}. {self.label}'

    def applies_to(self, tower_type):
        if not self.applicable_tower_types:
            return True
        return tower_type in self.applicable_tower_types


CRITICALITY_CHOICES = [
    ('minor', 'Minor'),
    ('major', 'Major'),
    ('critical', 'Critical'),
]


class Defect(models.Model):
    item = models.ForeignKey(ChecklistItem, on_delete=models.PROTECT, related_name='defects')
    key = models.SlugField(max_length=64)
    label = models.CharField(max_length=255)
    sort_order = models.PositiveIntegerField(default=0)
    ask = models.JSONField(default=list, blank=True)  # ordered list of FollowUpQuestion keys
    default_criticality = models.CharField(max_length=16, choices=CRITICALITY_CHOICES)

    class Meta:
        ordering = ['sort_order']
        constraints = [
            models.UniqueConstraint(fields=['item', 'key'], name='uniq_defect_item_key'),
        ]

    def __str__(self):
        return f'{self.item.key}:{self.key}'


ANSWER_TYPE_CHOICES = [
    ('choice', 'Single choice'),
    ('multichoice', 'Multiple choice'),
    ('number', 'Number'),
    ('text', 'Free text'),
]


class FollowUpQuestion(models.Model):
    key = models.SlugField(max_length=64, unique=True)
    question_text = models.CharField(max_length=500)
    answer_type = models.CharField(max_length=16, choices=ANSWER_TYPE_CHOICES)
    options = models.JSONField(default=list, blank=True)  # for choice/multichoice
    unit = models.CharField(max_length=32, blank=True)  # for number, e.g. 'm', 'discs', 'strands'
    placeholder = models.CharField(max_length=255, blank=True)  # for text

    def __str__(self):
        return self.key


CRITICALITY_OPERATOR_CHOICES = [
    ('gte', '>='),
    ('lte', '<='),
    ('eq', '=='),
    ('in', 'in'),
    ('contains_any', 'contains any of'),
    ('contains_all', 'contains all of'),
]


class CriticalityRule(models.Model):
    """Data-driven replacement for the POC's hardcoded critRule() JS
    functions — e.g. "if discCount >= 2 -> critical". Evaluated in ascending
    `priority` order; the first matching rule wins, else Defect.default_criticality
    applies."""
    defect = models.ForeignKey(Defect, on_delete=models.CASCADE, related_name='criticality_rules')
    follow_up_key = models.CharField(max_length=64)
    operator = models.CharField(max_length=16, choices=CRITICALITY_OPERATOR_CHOICES)
    threshold_value = models.JSONField()  # number, string, or list depending on operator/answer type
    resulting_criticality = models.CharField(max_length=16, choices=CRITICALITY_CHOICES)
    priority = models.PositiveIntegerField(default=0)

    class Meta:
        ordering = ['priority']

    def __str__(self):
        return f'{self.defect}: {self.follow_up_key} {self.operator} {self.threshold_value} -> {self.resulting_criticality}'


# ---------------------------------------------------------------------------
# 3. Cadre / role / jurisdiction — no django.contrib.auth.
# ---------------------------------------------------------------------------

class EmployeeCadreSnapshot(models.Model):
    """Synced periodically from the live SAP employee-cadre-details service
    (see services/sap_client.py + management/commands/sync_employee_cadre.py).
    Never live-queried per request."""
    employee_id = models.CharField(max_length=32, unique=True)
    employee_name = models.CharField(max_length=255, blank=True)
    position_id = models.CharField(max_length=32, blank=True)
    position_text = models.CharField(max_length=255, blank=True)
    org_unit_id = models.CharField(max_length=32, blank=True)
    org_unit_text = models.CharField(max_length=255, blank=True)
    emp_sub_grp = models.CharField(max_length=32, blank=True)
    emp_sub_grp_desc = models.CharField(max_length=255, blank=True)
    mobile = models.CharField(max_length=32, blank=True)
    mail = models.CharField(max_length=255, blank=True)
    reporting_manager_id = models.CharField(max_length=32, blank=True)
    reporting_manager_name = models.CharField(max_length=255, blank=True)
    synced_at = models.DateTimeField(auto_now=True)

    class Meta:
        indexes = [models.Index(fields=['reporting_manager_id'])]

    def __str__(self):
        return f'{self.employee_id} — {self.employee_name}'


class SuperAdmin(models.Model):
    """A very small set of people who decide who counts as an Admin (grants/
    revokes FieldEECadrePosition). Seeded via `manage.py grant_super_admin`
    (CLI-only bootstrap, since an empty permissions table would otherwise
    lock everyone out); managed thereafter through the admin panel itself
    only in the sense that a Super Admin can grant another Super Admin."""
    employee_id = models.CharField(max_length=32, unique=True)
    granted_at = models.DateTimeField(auto_now_add=True)
    notes = models.TextField(blank=True)

    def __str__(self):
        return self.employee_id


class FieldEECadrePosition(models.Model):
    """Admin-curated allow-list of the specific EE position IDs authorized to
    assign inspection roles — not every EE is a field engineer. Candidates
    are surfaced automatically (emp_sub_grp in DE/EE + position_text
    containing "O&M") on the Super-Admin-only management screen, which
    grants/revokes rows here."""
    position_id = models.CharField(max_length=32, unique=True)
    position_text = models.CharField(max_length=255, blank=True)
    notes = models.TextField(blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f'{self.position_id} — {self.position_text}'


ROLE_CHOICES = [
    ('FIELD_INSPECTOR', 'Field Inspector'),
]


class RoleAssignment(models.Model):
    employee_id = models.CharField(max_length=32)
    role = models.CharField(max_length=32, choices=ROLE_CHOICES)
    subdivision = models.ForeignKey(Subdivision, on_delete=models.PROTECT, null=True, blank=True, related_name='role_assignments')
    lines = models.ManyToManyField(Line, blank=True, related_name='role_assignments')

    assigned_by_employee_id = models.CharField(max_length=32)
    assigned_at = models.DateTimeField(auto_now_add=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        indexes = [models.Index(fields=['employee_id', 'is_active'])]

    def __str__(self):
        return f'{self.employee_id}: {self.role}'


class LineTowerAssignment(models.Model):
    """A from-tower -> to-tower stretch of a line assigned to a User, for when a
    whole line isn't one person's. Complements RoleAssignment (whole-line/
    subdivision grants) — it does NOT replace it. Range membership is the line's
    towers whose line_sequence is between the two boundary towers' sequences;
    boundaries are stored as Towers (not raw indices) so rebuilding the schedule
    can't drift an assigned stretch. jurisdiction.py unions these in."""
    employee_id = models.CharField(max_length=32)
    line = models.ForeignKey(Line, on_delete=models.CASCADE, related_name='tower_ranges')
    from_tower = models.ForeignKey(Tower, on_delete=models.PROTECT, related_name='range_starts')
    to_tower = models.ForeignKey(Tower, on_delete=models.PROTECT, related_name='range_ends')

    assigned_by_employee_id = models.CharField(max_length=32)
    assigned_at = models.DateTimeField(auto_now_add=True)
    is_active = models.BooleanField(default=True)

    class Meta:
        indexes = [
            models.Index(fields=['employee_id', 'is_active']),
            models.Index(fields=['line', 'is_active']),
        ]

    def __str__(self):
        return f'{self.employee_id}: {self.line_id} [{self.from_tower_id}..{self.to_tower_id}]'


# ---------------------------------------------------------------------------
# 4. Transactional inspection data.
# ---------------------------------------------------------------------------

class Inspection(models.Model):
    # Client-generated idempotency key (UUID v4), matching the pattern already
    # proven in the reference Flutter app's backend: same client_id on retry
    # returns the existing record (200) instead of duplicating (201 for new).
    client_id = models.CharField(max_length=64, unique=True, null=True, blank=True)
    tower = models.ForeignKey(Tower, on_delete=models.PROTECT, related_name='inspections')
    inspector_employee_id = models.CharField(max_length=32)
    catalog_version = models.PositiveIntegerField()
    date = models.DateField()
    # Ground Patrolling vs PMI (see INSPECTION_TYPE_CHOICES). Nullable — the
    # mobile app will populate it; the web dashboard never creates inspections.
    inspection_type = models.CharField(max_length=16, choices=INSPECTION_TYPE_CHOICES, null=True, blank=True)
    remarks = models.TextField(blank=True)
    worst_criticality = models.CharField(max_length=16, choices=WORST_CHOICES, default='none')
    saved_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    # Phase 4 — GPS proof of presence. The mobile Inspection tab captures the
    # inspector's device fix at submit time; the server recomputes gps_distance_m
    # against the tower's stored coordinates (never blindly trusting the client)
    # and stamps presence_flag. An out-of-range/no-fix capture is allowed only
    # with a non-empty override_reason (the audited-override policy). All nullable
    # so historical/web-created rows stay valid.
    inspector_lat = models.FloatField(null=True, blank=True)
    inspector_lng = models.FloatField(null=True, blank=True)
    gps_accuracy_m = models.FloatField(null=True, blank=True)
    gps_distance_m = models.FloatField(null=True, blank=True)
    presence_flag = models.CharField(max_length=16, choices=PRESENCE_FLAG_CHOICES, blank=True)
    override_reason = models.TextField(blank=True)

    class Meta:
        indexes = [models.Index(fields=['tower', 'saved_at'])]

    def __str__(self):
        return f'Inspection #{self.pk} — {self.tower}'


ITEM_STATUS_CHOICES = [
    ('na', 'Not applicable'),
    ('not_provided', 'Not available'),
    ('normal', 'Normal'),
    ('defect', 'Defect'),
]


class ItemResult(models.Model):
    inspection = models.ForeignKey(Inspection, on_delete=models.CASCADE, related_name='item_results')
    item = models.ForeignKey(ChecklistItem, on_delete=models.PROTECT, related_name='item_results')
    position = models.CharField(max_length=32, blank=True)  # '' for non-positional items
    status = models.CharField(max_length=16, choices=ITEM_STATUS_CHOICES)
    meta = models.JSONField(default=dict, blank=True)  # e.g. {"insType": "Fog Disc"}
    photo = models.ImageField(upload_to='line_inspection/item_photos/%Y/%m/', null=True, blank=True)

    class Meta:
        constraints = [
            models.UniqueConstraint(fields=['inspection', 'item', 'position'], name='uniq_itemresult_inspection_item_position'),
        ]

    def __str__(self):
        return f'{self.inspection_id}: {self.item.key}{f" ({self.position})" if self.position else ""}'


class DefectEntry(models.Model):
    item_result = models.ForeignKey(ItemResult, on_delete=models.CASCADE, related_name='entries')
    defect = models.ForeignKey(Defect, on_delete=models.PROTECT, related_name='entries')
    answers = models.JSONField(default=dict, blank=True)  # {followUpKey: scalar | [scalar, ...]}
    suggested_criticality = models.CharField(max_length=16, choices=CRITICALITY_CHOICES, blank=True)
    criticality = models.CharField(max_length=16, choices=CRITICALITY_CHOICES)
    note = models.TextField(blank=True)
    photo = models.ImageField(upload_to='line_inspection/defect_photos/%Y/%m/', null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f'{self.item_result}: {self.defect.key} ({self.criticality})'


def attach_defect_counts(inspections):
    """Evaluate [inspections] and set `defect_count` on each row, using one extra
    query for the whole page. Returns the evaluated list.

    Replaces `.annotate(Count('item_results__entries'))` on the list endpoints,
    which costs much more than it looks: the GROUP BY runs over every inspection
    the filter matches *before* the ORDER BY and the LIMIT, so returning one
    screen of a supervisor's history meant grouping the whole of it. Counting only
    the rows actually being returned keeps the work proportional to the page.
    """
    rows = list(inspections)
    if not rows:
        return rows
    counts = {
        r['item_result__inspection_id']: r['n']
        for r in (DefectEntry.objects
                  .filter(item_result__inspection_id__in=[i.pk for i in rows])
                  .values('item_result__inspection_id')
                  .annotate(n=models.Count('id')))
    }
    for row in rows:
        row.defect_count = counts.get(row.pk, 0)
    return rows


TICKET_STATUS_CHOICES = [
    ('open', 'Open'),
    ('closed', 'Closed'),
]

TICKET_SOURCE_CHOICES = [
    ('human_inspection', 'Human inspection'),
    ('drone_inspection', 'Drone inspection'),
]


class DefectTicket(models.Model):
    inspection = models.ForeignKey(Inspection, on_delete=models.PROTECT, related_name='tickets')
    tower = models.ForeignKey(Tower, on_delete=models.PROTECT, related_name='tickets')

    item = models.ForeignKey(ChecklistItem, on_delete=models.PROTECT, related_name='tickets')
    item_label = models.CharField(max_length=255)  # snapshotted so tickets stay readable if catalog wording changes
    position = models.CharField(max_length=32, blank=True)
    defect = models.ForeignKey(Defect, on_delete=models.PROTECT, related_name='tickets')
    defect_label = models.CharField(max_length=255)
    answers = models.JSONField(default=dict, blank=True)
    criticality = models.CharField(max_length=16, choices=CRITICALITY_CHOICES)

    status = models.CharField(max_length=16, choices=TICKET_STATUS_CHOICES, default='open')

    # Drone inspection is being built in parallel — schema only for now, no ingestion yet.
    source = models.CharField(max_length=32, choices=TICKET_SOURCE_CHOICES, default='human_inspection')
    drone_metadata = models.JSONField(null=True, blank=True)

    raised_at = models.DateTimeField()
    raised_by_employee_id = models.CharField(max_length=32)
    closed_at = models.DateTimeField(null=True, blank=True)
    closed_by_employee_id = models.CharField(max_length=32, blank=True)
    close_note = models.TextField(blank=True)

    class Meta:
        indexes = [models.Index(fields=['status', 'criticality']), models.Index(fields=['tower'])]

    def __str__(self):
        return f'Ticket #{self.pk} — {self.tower} — {self.defect_label} ({self.status})'


SUPPORT_STATUS_CHOICES = [
    ('open', 'Open'),
    ('resolved', 'Resolved'),
]


class SupportRequest(models.Model):
    subdivision = models.ForeignKey(Subdivision, on_delete=models.PROTECT, null=True, blank=True, related_name='support_requests')
    raised_by_employee_id = models.CharField(max_length=32)
    category = models.CharField(max_length=255)
    subject = models.CharField(max_length=255)
    text = models.TextField()
    status = models.CharField(max_length=16, choices=SUPPORT_STATUS_CHOICES, default='open')
    created_at = models.DateTimeField(auto_now_add=True)
    response = models.TextField(blank=True)
    resolved_by_employee_id = models.CharField(max_length=32, blank=True)
    resolved_at = models.DateTimeField(null=True, blank=True)

    def __str__(self):
        return f'Request #{self.pk}: {self.subject}'


# ---------------------------------------------------------------------------
# 5. LILO (Loop-In Loop-Out) — line-reorganisation lineage & audit.
#    A rare (~20-30/year), Super-Admin-only event: an existing line is split in
#    two when a new substation is looped into it. Physical towers keep their
#    coordinates (their true identity), so surviving towers are re-linked IN
#    PLACE — preserving inspection history / schedule / range assignments — by a
#    reviewable reconcile (services/lilo_matching.py + the Super-Admin LILO
#    screen). The routine ArcGIS sync is NOT modified; these records exist only
#    for the explicit, on-demand reconcile and its audit trail.
# ---------------------------------------------------------------------------

class LiloEvent(models.Model):
    """A recorded LILO: the pre-LILO line and the line(s) it became. Created by a
    Super Admin; `applied_at` is set once the tower reconcile has been applied."""
    old_line = models.ForeignKey(Line, on_delete=models.PROTECT, related_name='lilo_events_as_old')
    new_lines = models.ManyToManyField(Line, blank=True, related_name='lilo_events_as_new')
    split_tower = models.ForeignKey(Tower, on_delete=models.SET_NULL, null=True, blank=True, related_name='lilo_split_events')
    lilo_date = models.DateField(null=True, blank=True)
    notes = models.TextField(blank=True)
    performed_by_employee_id = models.CharField(max_length=32)
    created_at = models.DateTimeField(auto_now_add=True)
    applied_at = models.DateTimeField(null=True, blank=True)

    def __str__(self):
        return f'LILO #{self.pk}: old line {self.old_line_id} ({"applied" if self.applied_at else "draft"})'


LILO_REMAP_METHOD_CHOICES = [
    ('auto', 'Auto (high-confidence match)'),
    ('manual', 'Manual (operator override)'),
    ('new', 'New tower (no match)'),
]


class LiloTowerRemap(models.Model):
    """Audit of one tower decision within a LiloEvent apply: the surviving Tower
    PK that was kept (so history stays attached), the old/new ArcGIS object ids,
    the coordinate distance, and how the decision was made."""
    event = models.ForeignKey(LiloEvent, on_delete=models.CASCADE, related_name='remaps')
    surviving_tower = models.ForeignKey(Tower, on_delete=models.PROTECT, related_name='lilo_remaps')
    old_object_id = models.CharField(max_length=64, blank=True)
    new_object_id = models.CharField(max_length=64, blank=True)
    distance_m = models.FloatField(null=True, blank=True)
    method = models.CharField(max_length=16, choices=LILO_REMAP_METHOD_CHOICES)
    created_at = models.DateTimeField(auto_now_add=True)

    def __str__(self):
        return f'Remap {self.old_object_id or "-"}->{self.new_object_id or "-"} ({self.method})'


# ---------------------------------------------------------------------------
# 6. Mobile auth (Phase 4) — a DB-backed, revocable bearer token issued to the
#    Flutter field app after the legacy checkCred service verifies the
#    employee's credentials. No django.contrib.auth: the token resolves straight
#    to a bare employee_id, exactly like the web session and Keycloak paths.
#    Uses the `Token` Authorization scheme so it never collides with the dormant
#    Keycloak `Bearer` path (see api/authentication.py).
# ---------------------------------------------------------------------------

def _default_token_expiry():
    # Long-lived on purpose — field engineers may stay offline for days between
    # syncs. Revocation is explicit (logout) or by expiry, not by a short TTL.
    return timezone.now() + timedelta(days=30)


class MobileAuthToken(models.Model):
    key = models.CharField(max_length=64, unique=True, db_index=True)
    employee_id = models.CharField(max_length=32, db_index=True)  # already zfill(8) from checkcred
    display_name = models.CharField(max_length=255, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)
    last_used_at = models.DateTimeField(null=True, blank=True)
    expires_at = models.DateTimeField(null=True, blank=True, default=_default_token_expiry)
    is_active = models.BooleanField(default=True)
    revoked_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        indexes = [models.Index(fields=['employee_id', 'is_active'])]

    @staticmethod
    def generate_key():
        return secrets.token_urlsafe(48)

    @property
    def is_valid(self):
        if not self.is_active:
            return False
        return not (self.expires_at and self.expires_at < timezone.now())

    def revoke(self):
        self.is_active = False
        self.revoked_at = timezone.now()
        self.save(update_fields=['is_active', 'revoked_at'])

    def __str__(self):
        return f'MobileAuthToken({self.employee_id}, active={self.is_active})'
