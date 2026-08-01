"""Serializers for the line-inspection API.

The catalog serializers are read-only and shaped to match the Flutter form's
needs (nested groups -> items -> defects, plus flat follow-up + rule banks).
The write path is handled imperatively in the view, not here.
"""
from rest_framework import serializers

from .models import (
    CatalogVersion, ChecklistItemGroup, ChecklistItem, Defect,
    FollowUpQuestion, CriticalityRule, Line, Tower, Subdivision,
    Inspection, ItemResult, DefectEntry, DefectTicket, SupportRequest,
)


# ------------------------------- catalog -----------------------------------
class DefectSerializer(serializers.ModelSerializer):
    class Meta:
        model = Defect
        fields = ['id', 'key', 'label', 'sort_order', 'ask', 'default_criticality']


class ChecklistItemSerializer(serializers.ModelSerializer):
    defects = DefectSerializer(many=True, read_only=True)
    group_key = serializers.CharField(source='group.key', read_only=True)

    class Meta:
        model = ChecklistItem
        fields = [
            'id', 'key', 'sno', 'label', 'sort_order', 'positions', 'pos_meta',
            'is_availability_gated', 'is_position_availability_gated',
            'applicable_tower_types', 'na_reason', 'group_key', 'defects',
        ]


class ChecklistItemGroupSerializer(serializers.ModelSerializer):
    # group.items.all() hits the prefetch cache set up in CatalogView, so this
    # stays a single extra query for the whole catalog.
    items = ChecklistItemSerializer(many=True, read_only=True)

    class Meta:
        model = ChecklistItemGroup
        fields = ['id', 'key', 'label', 'sort_order', 'items']


class FollowUpQuestionSerializer(serializers.ModelSerializer):
    class Meta:
        model = FollowUpQuestion
        fields = ['id', 'key', 'question_text', 'answer_type', 'options',
                  'unit', 'placeholder']


class CriticalityRuleSerializer(serializers.ModelSerializer):
    defect_key = serializers.CharField(source='defect.key', read_only=True)

    class Meta:
        model = CriticalityRule
        fields = ['id', 'defect_key', 'follow_up_key', 'operator',
                  'threshold_value', 'resulting_criticality', 'priority']


# ------------------------------- assets ------------------------------------
class LineSerializer(serializers.ModelSerializer):
    class Meta:
        model = Line
        fields = ['id', 'name', 'voltage', 'subdivision_name', 'is_active']


class TowerSerializer(serializers.ModelSerializer):
    class Meta:
        model = Tower
        fields = ['id', 'tower_number', 'tower_type', 'voltage', 'line_name',
                  'latitude', 'longitude', 'line_id', 'subdivision_name']


class SubdivisionSerializer(serializers.ModelSerializer):
    class Meta:
        model = Subdivision
        fields = ['id', 'name', 'circle', 'division', 'zone']


# --------------------------- inspection records ----------------------------
class InspectionListSerializer(serializers.ModelSerializer):
    tower_number = serializers.CharField(source='tower.tower_number', read_only=True)
    tower_type = serializers.CharField(source='tower.tower_type', read_only=True)
    line_name = serializers.CharField(source='tower.line_name', read_only=True)
    defect_count = serializers.IntegerField(read_only=True)  # annotated in view

    class Meta:
        model = Inspection
        fields = ['id', 'tower_id', 'tower_number', 'tower_type', 'line_name',
                  'date', 'inspector_employee_id', 'worst_criticality',
                  'defect_count', 'saved_at', 'created_at']


class DefectEntryDetailSerializer(serializers.ModelSerializer):
    defect_label = serializers.CharField(source='defect.label', read_only=True)
    defect_key = serializers.CharField(source='defect.key', read_only=True)

    class Meta:
        model = DefectEntry
        fields = ['id', 'defect_id', 'defect_key', 'defect_label', 'answers',
                  'criticality', 'suggested_criticality', 'note', 'photo']


class ItemResultDetailSerializer(serializers.ModelSerializer):
    item_label = serializers.CharField(source='item.label', read_only=True)
    item_key = serializers.CharField(source='item.key', read_only=True)
    sno = serializers.IntegerField(source='item.sno', read_only=True)
    group_key = serializers.CharField(source='item.group.key', read_only=True)
    entries = DefectEntryDetailSerializer(many=True, read_only=True)

    class Meta:
        model = ItemResult
        fields = ['id', 'item_id', 'item_key', 'item_label', 'sno', 'group_key',
                  'position', 'status', 'meta', 'photo', 'entries']


class InspectionDetailSerializer(serializers.ModelSerializer):
    tower_number = serializers.CharField(source='tower.tower_number', read_only=True)
    tower_type = serializers.CharField(source='tower.tower_type', read_only=True)
    line_name = serializers.CharField(source='tower.line_name', read_only=True)
    item_results = ItemResultDetailSerializer(many=True, read_only=True)

    class Meta:
        model = Inspection
        fields = ['id', 'tower_id', 'tower_number', 'tower_type', 'line_name',
                  'date', 'inspector_employee_id', 'catalog_version', 'remarks',
                  'worst_criticality', 'saved_at', 'created_at', 'item_results']


# ------------------------------- tickets -----------------------------------
class TicketSerializer(serializers.ModelSerializer):
    tower_number = serializers.CharField(source='tower.tower_number', read_only=True)
    line_name = serializers.CharField(source='tower.line_name', read_only=True)

    class Meta:
        model = DefectTicket
        fields = ['id', 'tower_id', 'tower_number', 'line_name', 'item_label',
                  'position', 'defect_label', 'answers', 'criticality', 'status',
                  'source', 'raised_at', 'raised_by_employee_id', 'closed_at',
                  'closed_by_employee_id', 'close_note']


# --------------------------- support requests ------------------------------
class SupportRequestSerializer(serializers.ModelSerializer):
    subdivision_name = serializers.CharField(
        source='subdivision.name', read_only=True, default='')

    class Meta:
        model = SupportRequest
        fields = ['id', 'raised_by_employee_id', 'category', 'subject', 'text',
                  'status', 'created_at', 'response', 'resolved_by_employee_id',
                  'resolved_at', 'subdivision_id', 'subdivision_name']
