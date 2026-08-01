from django import forms

from .models import (
    ChecklistItemGroup, ChecklistItem, Defect, FollowUpQuestion, CriticalityRule,
    FieldEECadrePosition, RoleAssignment, SapLine, Subdivision, Line,
)


class FieldEECadrePositionForm(forms.ModelForm):
    class Meta:
        model = FieldEECadrePosition
        fields = ['position_id', 'position_text', 'notes']
        widgets = {
            # posid/postext are interlinked in SAP — auto-filled by
            # manage_admins.html's JS via the lookup-position endpoint
            # instead of an Admin typing it by hand.
            'position_text': forms.TextInput(attrs={
                'readonly': 'readonly',
                'placeholder': 'Auto-filled from SAP once you enter a position id',
            }),
        }


class RoleAssignmentForm(forms.ModelForm):
    class Meta:
        model = RoleAssignment
        fields = ['employee_id', 'subdivision', 'lines']
        widgets = {
            'employee_id': forms.HiddenInput(),
            'lines': forms.SelectMultiple(attrs={'size': 10}),
        }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        # Both fields are re-rendered as searchable comboboxes in
        # role_assignment_form.html — these querysets are what that JS
        # treats as the full candidate set, so they must exclude
        # soft-deleted lines and stay name-sorted for the search UI.
        self.fields['subdivision'].queryset = Subdivision.objects.order_by('name')
        self.fields['lines'].queryset = Line.objects.filter(is_active=True).order_by('name')


class ChecklistItemGroupForm(forms.ModelForm):
    class Meta:
        model = ChecklistItemGroup
        fields = ['key', 'label', 'sort_order']


class ChecklistItemForm(forms.ModelForm):
    applicable_tower_types = forms.MultipleChoiceField(required=False, widget=forms.CheckboxSelectMultiple)

    class Meta:
        model = ChecklistItem
        fields = [
            'group', 'key', 'sno', 'label', 'sort_order', 'positions',
            'is_availability_gated', 'is_position_availability_gated',
            'applicable_tower_types', 'na_reason',
        ]
        widgets = {
            'positions': forms.TextInput(attrs={'placeholder': 'Top,Middle,Bottom (comma-separated, blank = not positional)'}),
        }

    def __init__(self, *args, tower_type_choices=(), **kwargs):
        super().__init__(*args, **kwargs)
        self.fields['applicable_tower_types'].choices = [(t, t) for t in tower_type_choices]

    def clean_positions(self):
        raw = self.data.get('positions', '')
        if isinstance(raw, list):
            return raw
        return [p.strip() for p in raw.split(',') if p.strip()]


class DefectForm(forms.ModelForm):
    ask = forms.CharField(required=False, help_text='Comma-separated FollowUpQuestion keys, in order')

    class Meta:
        model = Defect
        fields = ['item', 'key', 'label', 'sort_order', 'ask', 'default_criticality']

    def clean_ask(self):
        return [k.strip() for k in self.cleaned_data['ask'].split(',') if k.strip()]


class FollowUpQuestionForm(forms.ModelForm):
    options = forms.CharField(required=False, help_text='Comma-separated options (for choice/multichoice only)')

    class Meta:
        model = FollowUpQuestion
        fields = ['key', 'question_text', 'answer_type', 'options', 'unit', 'placeholder']

    def clean_options(self):
        return [o.strip() for o in self.cleaned_data['options'].split(',') if o.strip()]


class CriticalityRuleForm(forms.ModelForm):
    class Meta:
        model = CriticalityRule
        fields = ['defect', 'follow_up_key', 'operator', 'threshold_value', 'resulting_criticality', 'priority']
        help_texts = {
            'threshold_value': 'A plain number or string, e.g. 2 or "Main leg / corner member" (JSON — quote text values).',
        }


class SapLineForm(forms.ModelForm):
    class Meta:
        model = SapLine
        fields = ['functional_location', 'description', 'voltage']


class LineMappingForm(forms.Form):
    sap_line = forms.ModelChoiceField(queryset=SapLine.objects.all(), required=False)
