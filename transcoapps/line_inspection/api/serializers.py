from django.conf import settings
from rest_framework import serializers

from .. import jurisdiction
from ..models import (
    ChecklistItemGroup, ChecklistItem, Defect, FollowUpQuestion, CriticalityRule,
    Line, Tower, Subdivision, Inspection, ItemResult, DefectEntry, DefectTicket, SupportRequest,
)


def absolute_photo_url(image_field, context):
    """Absolute URL for an ImageField, built explicitly as /media/<name> (our
    MEDIA_URL has no leading slash) so the Flutter app's `mediaUrl()` — which
    strips `/api` and appends `/media/<path>` — resolves to the same host path.
    Returns None when there's no photo."""
    if not image_field:
        return None
    request = context.get('request')
    path = f'/media/{image_field.name}'
    return request.build_absolute_uri(path) if request else path


# ---------------------------------------------------------------------------
# Checklist catalog (read-only — edited via the admin panel, not the API)
# ---------------------------------------------------------------------------

class CriticalityRuleSerializer(serializers.ModelSerializer):
    class Meta:
        model = CriticalityRule
        fields = ['follow_up_key', 'operator', 'threshold_value', 'resulting_criticality', 'priority']


class DefectSerializer(serializers.ModelSerializer):
    criticality_rules = CriticalityRuleSerializer(many=True, read_only=True)

    class Meta:
        model = Defect
        fields = ['id', 'key', 'label', 'ask', 'default_criticality', 'criticality_rules']


class ChecklistItemSerializer(serializers.ModelSerializer):
    defects = DefectSerializer(many=True, read_only=True)
    # Mobile catalog needs the owning group key + sort order (the Flutter model
    # reads `group_key` to bucket items). Additive — web consumers ignore them.
    group_key = serializers.CharField(source='group.key', read_only=True)

    class Meta:
        model = ChecklistItem
        fields = [
            'id', 'key', 'sno', 'label', 'sort_order', 'group_key', 'positions', 'pos_meta',
            'is_availability_gated', 'is_position_availability_gated',
            'applicable_tower_types', 'na_reason', 'defects',
        ]


class MobileCriticalityRuleSerializer(serializers.ModelSerializer):
    """Flattened criticality rule for the mobile catalog's top-level
    `criticality_rules[]` — carries `defect_key` so the client can match a rule
    to its defect (the nested DefectSerializer.criticality_rules omits it)."""
    defect_key = serializers.CharField(source='defect.key', read_only=True)

    class Meta:
        model = CriticalityRule
        fields = ['defect_key', 'follow_up_key', 'operator', 'threshold_value', 'resulting_criticality', 'priority']


class ChecklistItemGroupSerializer(serializers.ModelSerializer):
    items = ChecklistItemSerializer(many=True, read_only=True)

    class Meta:
        model = ChecklistItemGroup
        fields = ['id', 'key', 'label', 'sort_order', 'items']


class FollowUpQuestionSerializer(serializers.ModelSerializer):
    class Meta:
        model = FollowUpQuestion
        # `id` is part of the contract like every other catalog serializer — the
        # mobile catalog model parses it, so omitting it broke form open.
        fields = ['id', 'key', 'question_text', 'answer_type', 'options', 'unit', 'placeholder']


# ---------------------------------------------------------------------------
# GIS master data (read-only, jurisdiction-filtered by the views)
# ---------------------------------------------------------------------------

class SubdivisionSerializer(serializers.ModelSerializer):
    class Meta:
        model = Subdivision
        fields = ['id', 'name', 'circle', 'division', 'zone']


class LineSerializer(serializers.ModelSerializer):
    subdivision_name = serializers.CharField(source='subdivision.name', default='', read_only=True)

    class Meta:
        model = Line
        fields = ['id', 'name', 'voltage', 'subdivision_name', 'circle', 'division', 'is_active']


class TowerSerializer(serializers.ModelSerializer):
    class Meta:
        model = Tower
        fields = [
            'id', 'tower_number', 'tower_type', 'voltage', 'line_id', 'line_name',
            'latitude', 'longitude', 'is_active',
        ]


class MobileTowerSerializer(serializers.ModelSerializer):
    """Tower shape the Flutter app's LiTower expects — adds line_id +
    subdivision_name (a direct Tower field, ArcGIS text) to the base tower."""
    can_inspect = serializers.SerializerMethodField()

    class Meta:
        model = Tower
        fields = [
            'id', 'tower_number', 'tower_type', 'voltage', 'line_name', 'line_id',
            'latitude', 'longitude', 'subdivision_name', 'is_active', 'can_inspect',
        ]

    def get_can_inspect(self, obj):
        """Whether this viewer may actually *save* an inspection on this tower.

        Tower lists are oversight-scoped (viewing.py) and deliberately wider than
        the own-assignment capture scope `_create_inspection` enforces, so a tower
        can be visible yet not inspectable — an employee with no RoleAssignment
        rows sees their subtree but can edit nothing. Reporting it here lets the
        app refuse the form up front instead of letting an inspector walk out,
        complete the checklist and only discover at sync time that the save is
        refused. Purely advisory: `jurisdiction.can_inspect_tower` remains the
        authority on submit, and this must never be stricter than that — a false
        here would make the app refuse a form the server would have accepted.
        """
        editable = self._editable_tower_ids()
        # Unknown viewer (e.g. direct serialization with no request): say nothing
        # rather than invent a restriction the write path may not apply.
        return True if editable is None else obj.id in editable

    def _editable_tower_ids(self):
        """The viewer's capture-scope tower ids, resolved once per response.

        None means "no capture restriction to report" — which is the answer
        whenever recording is open (settings.LINE_INSPECTION_OPEN_INSPECT), so
        the app stops pre-emptively blocking towers the write path now accepts.
        """
        if not hasattr(self, '_editable_ids_cache'):
            if getattr(settings, 'LINE_INSPECTION_OPEN_INSPECT', False):
                self._editable_ids_cache = None
            else:
                employee_id = getattr(
                    getattr(self.context.get('request'), 'user', None), 'employee_id', None)
                self._editable_ids_cache = None if not employee_id else set(
                    jurisdiction.visible_towers(employee_id).values_list('id', flat=True))
        return self._editable_ids_cache


# ---------------------------------------------------------------------------
# Inspections — write (nested create) and read (history)
# ---------------------------------------------------------------------------

class DefectEntryInputSerializer(serializers.Serializer):
    defect = serializers.CharField()  # Defect.key, scoped to the parent item
    answers = serializers.DictField(required=False, default=dict)
    criticality = serializers.ChoiceField(choices=['minor', 'major', 'critical'], required=False, allow_null=True)
    note = serializers.CharField(required=False, allow_blank=True, default='')


class ItemResultInputSerializer(serializers.Serializer):
    item = serializers.CharField()  # ChecklistItem.key
    position = serializers.CharField(required=False, allow_blank=True, default='')
    status = serializers.ChoiceField(choices=['na', 'not_provided', 'normal', 'defect'])
    meta = serializers.DictField(required=False, default=dict)
    entries = DefectEntryInputSerializer(many=True, required=False, default=list)


class InspectionCreateSerializer(serializers.Serializer):
    client_id = serializers.CharField(required=False, allow_null=True, allow_blank=True)
    tower = serializers.IntegerField()
    date = serializers.DateField()
    # Ground Patrolling vs PMI — optional; the Flutter app supplies it, the web
    # dashboard never creates inspections. Older/omitted -> null (unknown type).
    inspection_type = serializers.ChoiceField(choices=['ground_patrol', 'pmi'], required=False, allow_null=True)
    remarks = serializers.CharField(required=False, allow_blank=True, default='')
    item_results = ItemResultInputSerializer(many=True)

    def validate_client_id(self, value):
        return value or None


# --- Mobile multipart submit (numeric ids + photo_key + GPS proof) ----------

class MobileDefectEntryInputSerializer(serializers.Serializer):
    defect_id = serializers.IntegerField()
    answers = serializers.DictField(required=False, default=dict)
    criticality = serializers.ChoiceField(choices=['minor', 'major', 'critical'], required=False, allow_null=True)
    suggested_criticality = serializers.CharField(required=False, allow_blank=True, allow_null=True, default='')
    note = serializers.CharField(required=False, allow_blank=True, default='')
    photo_key = serializers.CharField(required=False, allow_blank=True, allow_null=True)


class MobileItemResultInputSerializer(serializers.Serializer):
    item_id = serializers.IntegerField()
    position = serializers.CharField(required=False, allow_blank=True, default='')
    status = serializers.ChoiceField(choices=['na', 'not_provided', 'normal', 'defect'])
    meta = serializers.DictField(required=False, default=dict)
    photo_key = serializers.CharField(required=False, allow_blank=True, allow_null=True)
    entries = MobileDefectEntryInputSerializer(many=True, required=False, default=list)


class MobileInspectionCreateSerializer(serializers.Serializer):
    """The JSON `payload` field of the multipart submit from the Flutter app.
    Resolves items/defects by numeric DB id (the app sends catalog ids), carries
    photo_key references (matched to the multipart file parts), and the GPS
    proof-of-presence fields."""
    client_id = serializers.CharField(required=False, allow_null=True, allow_blank=True)
    tower_id = serializers.IntegerField()
    catalog_version = serializers.IntegerField(required=False)
    date = serializers.DateField(required=False)
    inspection_type = serializers.ChoiceField(choices=['ground_patrol', 'pmi'], required=False, allow_null=True)
    remarks = serializers.CharField(required=False, allow_blank=True, default='')
    items = MobileItemResultInputSerializer(many=True)

    # GPS proof of presence
    inspector_lat = serializers.FloatField(required=False, allow_null=True)
    inspector_lng = serializers.FloatField(required=False, allow_null=True)
    gps_accuracy_m = serializers.FloatField(required=False, allow_null=True)
    presence_flag = serializers.ChoiceField(
        choices=['in_range', 'out_of_range', 'no_fix'], required=False, allow_blank=True, allow_null=True)
    override_reason = serializers.CharField(required=False, allow_blank=True, default='')

    def validate_client_id(self, value):
        return value or None


class DefectEntrySerializer(serializers.ModelSerializer):
    defect_id = serializers.IntegerField(source='defect.id', read_only=True)
    defect_key = serializers.CharField(source='defect.key', read_only=True)
    defect_label = serializers.CharField(source='defect.label', read_only=True)
    photo = serializers.SerializerMethodField()

    class Meta:
        model = DefectEntry
        fields = ['id', 'defect_id', 'defect_key', 'defect_label', 'answers', 'suggested_criticality', 'criticality', 'note', 'photo']

    def get_photo(self, obj):
        return absolute_photo_url(obj.photo, self.context)


class ItemResultSerializer(serializers.ModelSerializer):
    item_id = serializers.IntegerField(source='item.id', read_only=True)
    item_key = serializers.CharField(source='item.key', read_only=True)
    item_label = serializers.CharField(source='item.label', read_only=True)
    sno = serializers.IntegerField(source='item.sno', read_only=True)
    group_key = serializers.CharField(source='item.group.key', read_only=True)
    entries = DefectEntrySerializer(many=True, read_only=True)
    photo = serializers.SerializerMethodField()

    class Meta:
        model = ItemResult
        fields = ['id', 'item_id', 'item_key', 'item_label', 'sno', 'group_key', 'position', 'status', 'meta', 'photo', 'entries']

    def get_photo(self, obj):
        return absolute_photo_url(obj.photo, self.context)


class InspectionSerializer(serializers.ModelSerializer):
    tower_id = serializers.IntegerField(source='tower.id', read_only=True)
    tower_number = serializers.CharField(source='tower.tower_number', read_only=True)
    tower_type = serializers.CharField(source='tower.tower_type', read_only=True)
    line_name = serializers.CharField(source='tower.line_name', read_only=True)
    item_results = ItemResultSerializer(many=True, read_only=True)

    class Meta:
        model = Inspection
        fields = [
            'id', 'client_id', 'tower', 'tower_id', 'tower_number', 'tower_type', 'line_name',
            'inspector_employee_id', 'catalog_version', 'date', 'inspection_type', 'remarks',
            'worst_criticality', 'saved_at', 'created_at',
            # GPS proof of presence (Phase 4)
            'inspector_lat', 'inspector_lng', 'gps_accuracy_m', 'gps_distance_m',
            'presence_flag', 'override_reason',
            'item_results',
        ]


class MobileInspectionSummarySerializer(serializers.ModelSerializer):
    """Compact row for the mobile inspections list — includes a defect_count
    (annotated by the view) plus tower/line labels."""
    tower_id = serializers.IntegerField(source='tower.id', read_only=True)
    tower_number = serializers.CharField(source='tower.tower_number', read_only=True)
    tower_type = serializers.CharField(source='tower.tower_type', read_only=True)
    line_name = serializers.CharField(source='tower.line_name', read_only=True)
    defect_count = serializers.IntegerField(read_only=True)

    class Meta:
        model = Inspection
        fields = [
            'id', 'tower_id', 'tower_number', 'tower_type', 'line_name', 'date',
            'inspector_employee_id', 'worst_criticality', 'defect_count', 'saved_at', 'created_at',
        ]


# ---------------------------------------------------------------------------
# Tickets / support requests
# ---------------------------------------------------------------------------

class DefectTicketSerializer(serializers.ModelSerializer):
    tower_id = serializers.IntegerField(source='tower.id', read_only=True)
    tower_number = serializers.CharField(source='tower.tower_number', read_only=True)
    line_name = serializers.CharField(source='tower.line_name', read_only=True)

    class Meta:
        model = DefectTicket
        fields = [
            'id', 'tower', 'tower_id', 'tower_number', 'line_name', 'item_label', 'position', 'defect_label',
            'answers', 'criticality', 'status', 'source', 'drone_metadata',
            'raised_at', 'raised_by_employee_id', 'closed_at', 'closed_by_employee_id', 'close_note',
        ]
        read_only_fields = [f for f in fields if f != 'close_note']


class SupportRequestSerializer(serializers.ModelSerializer):
    # Expose the FK id + name for the app; accept subdivision_id on create.
    subdivision_id = serializers.IntegerField(required=False, allow_null=True)
    subdivision_name = serializers.CharField(source='subdivision.name', default='', read_only=True)

    class Meta:
        model = SupportRequest
        fields = [
            'id', 'subdivision', 'subdivision_id', 'subdivision_name', 'raised_by_employee_id',
            'category', 'subject', 'text', 'status', 'created_at', 'response',
            'resolved_by_employee_id', 'resolved_at',
        ]
        read_only_fields = [
            'subdivision', 'raised_by_employee_id', 'status', 'created_at', 'response',
            'resolved_by_employee_id', 'resolved_at',
        ]
