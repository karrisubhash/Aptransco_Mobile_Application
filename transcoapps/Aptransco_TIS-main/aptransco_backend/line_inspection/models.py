"""Read/write models over the externally-owned ``clear`` schema.

Every model here is ``managed = False`` — the tables are created and migrated
by a separate project. We only map the columns this API needs. The set below
covers the inspection form: the questionnaire catalog, the asset tables used
by the line/tower selectors, and the records an inspection writes.

Criticality values used across the schema: ``ok`` / ``minor`` / ``major`` /
``critical`` (plus ``none`` for "not inspected", used only in the UI).
"""
from django.db import models


# ---------------------------------------------------------------------------
# Questionnaire catalog (read-only): groups -> items -> defects, plus the
# follow-up question bank and the declarative criticality rules.
# ---------------------------------------------------------------------------
class CatalogVersion(models.Model):
    version = models.IntegerField()
    updated_at = models.DateTimeField()

    class Meta:
        managed = False
        db_table = 'line_inspection_catalogversion'


class ChecklistItemGroup(models.Model):
    key = models.CharField(max_length=64, unique=True)
    label = models.CharField(max_length=255)
    sort_order = models.IntegerField()

    class Meta:
        managed = False
        db_table = 'line_inspection_checklistitemgroup'
        ordering = ['sort_order']


class ChecklistItem(models.Model):
    key = models.CharField(max_length=64, unique=True)
    sno = models.IntegerField()
    label = models.CharField(max_length=255)
    sort_order = models.IntegerField()
    positions = models.JSONField()                 # e.g. ["Top","Middle","Bottom"]
    pos_meta = models.JSONField(null=True)         # optional per-position select
    is_availability_gated = models.BooleanField()
    is_position_availability_gated = models.BooleanField()
    applicable_tower_types = models.JSONField()    # [] = all; else e.g. ["DA"]
    na_reason = models.CharField(max_length=255)
    group = models.ForeignKey(
        ChecklistItemGroup, on_delete=models.DO_NOTHING,
        db_column='group_id', related_name='items',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_checklistitem'
        ordering = ['sort_order']


class Defect(models.Model):
    key = models.CharField(max_length=64)
    label = models.CharField(max_length=255)
    sort_order = models.IntegerField()
    ask = models.JSONField()                       # ordered follow-up keys
    default_criticality = models.CharField(max_length=16)
    item = models.ForeignKey(
        ChecklistItem, on_delete=models.DO_NOTHING,
        db_column='item_id', related_name='defects',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_defect'
        ordering = ['sort_order']


class FollowUpQuestion(models.Model):
    key = models.CharField(max_length=64, unique=True)
    question_text = models.CharField(max_length=500)
    answer_type = models.CharField(max_length=16)  # choice|multichoice|number|text
    options = models.JSONField()
    unit = models.CharField(max_length=32)
    placeholder = models.CharField(max_length=255)

    class Meta:
        managed = False
        db_table = 'line_inspection_followupquestion'
        ordering = ['key']


class CriticalityRule(models.Model):
    follow_up_key = models.CharField(max_length=64)
    operator = models.CharField(max_length=16)     # eq|gte|lte|...
    threshold_value = models.JSONField()
    resulting_criticality = models.CharField(max_length=16)
    priority = models.IntegerField()
    defect = models.ForeignKey(
        Defect, on_delete=models.DO_NOTHING,
        db_column='defect_id', related_name='criticality_rules',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_criticalityrule'
        ordering = ['priority']


# ---------------------------------------------------------------------------
# Asset tables (read-only) used by the line + Loc No selectors and to give the
# form its tower context (type drives which items apply).
# ---------------------------------------------------------------------------
class Subdivision(models.Model):
    name = models.CharField(max_length=255, unique=True)
    circle = models.CharField(max_length=255)
    division = models.CharField(max_length=255)
    zone = models.CharField(max_length=255)

    class Meta:
        managed = False
        db_table = 'line_inspection_subdivision'
        ordering = ['name']


class Line(models.Model):
    name = models.CharField(max_length=255)
    voltage = models.CharField(max_length=16)
    line_length = models.CharField(max_length=64)
    circuit_type = models.CharField(max_length=255)
    zone = models.CharField(max_length=255)
    circle = models.CharField(max_length=255)
    division = models.CharField(max_length=255)
    subdivision_name = models.CharField(max_length=255)
    is_active = models.BooleanField()
    subdivision = models.ForeignKey(
        Subdivision, on_delete=models.DO_NOTHING,
        db_column='subdivision_id', null=True, related_name='lines',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_line'
        ordering = ['name']


class Tower(models.Model):
    tower_number = models.CharField(max_length=64)
    tower_type = models.CharField(max_length=64)
    voltage = models.CharField(max_length=16)
    line_name = models.CharField(max_length=255)
    latitude = models.FloatField(null=True)
    longitude = models.FloatField(null=True)
    zone = models.CharField(max_length=255)
    circle = models.CharField(max_length=255)
    division = models.CharField(max_length=255)
    subdivision_name = models.CharField(max_length=255)
    is_active = models.BooleanField()
    line = models.ForeignKey(
        Line, on_delete=models.DO_NOTHING,
        db_column='line_id', null=True, related_name='towers',
    )
    subdivision = models.ForeignKey(
        Subdivision, on_delete=models.DO_NOTHING,
        db_column='subdivision_id', null=True, related_name='towers',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_tower'
        ordering = ['tower_number']


# ---------------------------------------------------------------------------
# Inspection records (written by the form). An inspection has one ItemResult
# per checklist item (per position for positional items); each recorded defect
# is a DefectEntry and is also raised as a DefectTicket.
# ---------------------------------------------------------------------------
class Inspection(models.Model):
    inspector_employee_id = models.CharField(max_length=32)
    catalog_version = models.IntegerField()
    date = models.DateField()
    remarks = models.TextField(default='')
    worst_criticality = models.CharField(max_length=16)
    saved_at = models.DateTimeField(null=True)
    created_at = models.DateTimeField()
    client_id = models.CharField(max_length=64, null=True, unique=True)
    tower = models.ForeignKey(
        Tower, on_delete=models.DO_NOTHING,
        db_column='tower_id', related_name='inspections',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_inspection'


class ItemResult(models.Model):
    position = models.CharField(max_length=32, default='')
    status = models.CharField(max_length=16)       # normal|defect|na|not_provided
    meta = models.JSONField(default=dict)
    photo = models.CharField(max_length=100, null=True)
    inspection = models.ForeignKey(
        Inspection, on_delete=models.DO_NOTHING,
        db_column='inspection_id', related_name='item_results',
    )
    item = models.ForeignKey(
        ChecklistItem, on_delete=models.DO_NOTHING,
        db_column='item_id', related_name='+',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_itemresult'


class DefectEntry(models.Model):
    answers = models.JSONField(default=dict)
    suggested_criticality = models.CharField(max_length=16)
    criticality = models.CharField(max_length=16)
    note = models.TextField(default='')
    photo = models.CharField(max_length=100, null=True)
    created_at = models.DateTimeField()
    defect = models.ForeignKey(
        Defect, on_delete=models.DO_NOTHING,
        db_column='defect_id', related_name='+',
    )
    item_result = models.ForeignKey(
        ItemResult, on_delete=models.DO_NOTHING,
        db_column='item_result_id', related_name='entries',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_defectentry'


class DefectTicket(models.Model):
    item_label = models.CharField(max_length=255)
    position = models.CharField(max_length=32, default='')
    defect_label = models.CharField(max_length=255)
    answers = models.JSONField(default=dict)
    criticality = models.CharField(max_length=16)
    status = models.CharField(max_length=16, default='open')
    source = models.CharField(max_length=32, default='inspection')
    drone_metadata = models.JSONField(null=True)
    raised_at = models.DateTimeField()
    raised_by_employee_id = models.CharField(max_length=32)
    closed_at = models.DateTimeField(null=True)
    closed_by_employee_id = models.CharField(max_length=32, default='')
    close_note = models.TextField(default='')
    defect = models.ForeignKey(
        Defect, on_delete=models.DO_NOTHING,
        db_column='defect_id', related_name='+',
    )
    item = models.ForeignKey(
        ChecklistItem, on_delete=models.DO_NOTHING,
        db_column='item_id', related_name='+',
    )
    inspection = models.ForeignKey(
        Inspection, on_delete=models.DO_NOTHING,
        db_column='inspection_id', related_name='tickets',
    )
    tower = models.ForeignKey(
        Tower, on_delete=models.DO_NOTHING,
        db_column='tower_id', related_name='tickets',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_defectticket'


class SupportRequest(models.Model):
    """A dispute / change request raised by a field user, resolved by admin."""
    raised_by_employee_id = models.CharField(max_length=32)
    category = models.CharField(max_length=255)
    subject = models.CharField(max_length=255)
    text = models.TextField(default='')
    status = models.CharField(max_length=16, default='open')  # open | resolved
    created_at = models.DateTimeField()
    response = models.TextField(default='')
    resolved_by_employee_id = models.CharField(max_length=32, default='')
    resolved_at = models.DateTimeField(null=True)
    subdivision = models.ForeignKey(
        Subdivision, on_delete=models.DO_NOTHING,
        db_column='subdivision_id', null=True, related_name='support_requests',
    )

    class Meta:
        managed = False
        db_table = 'line_inspection_supportrequest'
