"""Loads the initial checklist catalog (25 items / 5 groups / defects /
follow-up questions / criticality rules) as editable DB rows.

Ported from the two POC iterations (transcoapps/gisdata/clearpoc.html and the
newer transcoapps/poc_v2.html, which added the 'Anti-climbing device' item,
the 'paint_absent' defect, and the multichoice-typed boardType question).
This is a one-time/idempotent data migration, not a permanent code
dependency — the catalog rows this creates are meant to be edited afterwards
(via the Phase 2 admin panel) as field engineers revise the questionnaire.
"""
from django.core.management.base import BaseCommand
from django.db import transaction

from line_inspection.models import (
    ChecklistItemGroup, ChecklistItem, Defect, FollowUpQuestion, CriticalityRule,
    CatalogVersion,
)

POS3 = ['Top', 'Middle', 'Bottom']
POS3EW = ['Top', 'Middle', 'Bottom', 'Earth wire']
INSULATOR_META = {
    'id': 'insType', 'label': 'Type of insulator',
    'options': ['Normal Disc', 'Fog Disc', 'SRC', 'Glass'], 'default': 'Normal Disc',
}
SP_TYPES = ['DA']
CP_TYPES = ['DB', 'DC', 'DD']
SP_REASON = 'Only on suspension (SP) towers'
CP_REASON = 'Only on tension (CP) towers — DB, DC, DD'

GROUPS = [
    {'key': 'civil', 'label': 'Coping & foundation'},
    {'key': 'tower', 'label': 'Tower parts'},
    {'key': 'hardware', 'label': 'Suspension / tension hardware'},
    {'key': 'conductor', 'label': 'Conductor & accessories'},
    {'key': 'earthing', 'label': 'Earthing'},
]

FOLLOW_UPS = [
    {'key': 'leg', 'question_text': 'Which leg / footing?', 'answer_type': 'choice',
     'options': ['Leg A', 'Leg B', 'Leg C', 'Leg D', 'More than one leg']},
    {'key': 'span', 'question_text': 'In which span?', 'answer_type': 'choice',
     'options': ['Back span (towards previous tower)', 'Forward span (towards next tower)']},
    {'key': 'towerLoc', 'question_text': 'Where on the tower is it?', 'answer_type': 'choice',
     'options': ['Below waist level', 'Above waist level', 'Cross-arm', 'Cage / boom', 'Peak', 'Leg member']},
    {'key': 'memberType', 'question_text': 'Which type of member?', 'answer_type': 'choice',
     'options': ['Main leg / corner member', 'Bracing / redundant member', 'Cross-arm member', 'Peak member']},
    {'key': 'boltType', 'question_text': 'Which bolts are affected?', 'answer_type': 'choice',
     'options': ['Member bolts & nuts', 'Step bolts', 'Both']},
    {'key': 'clampPart', 'question_text': 'Which part is missing?', 'answer_type': 'choice',
     'options': ['Bolt / nut', 'Keeper / retaining clip', 'Cotter pin', 'Clamp body', 'PG clamp']},
    {'key': 'hornEnd', 'question_text': 'Which horn is affected?', 'answer_type': 'choice',
     'options': ['Line-side horn', 'Tower-side horn', 'Both']},
    {'key': 'boardType', 'question_text': 'Which board / plate? (select all that apply)', 'answer_type': 'multichoice',
     'options': ['Danger board', 'Number plate', 'Phase plate', 'Circuit plate']},
    {'key': 'paintExtent', 'question_text': 'Extent of rusting / paint failure?', 'answer_type': 'choice',
     'options': ['Isolated spots', 'Less than 25% of members', '25% – 50% of members', 'More than 50% of members']},
    {'key': 'crackExtent', 'question_text': 'How severe is the damage?', 'answer_type': 'choice',
     'options': ['Just crack observed', 'Major structural crack / broken']},
    {'key': 'erosion', 'question_text': 'How much of the revetment is affected?', 'answer_type': 'choice',
     'options': ['Less than 25%', '25% – 50%', 'More than 50% / washed out']},
    {'key': 'treeKind', 'question_text': 'What kind of growth?', 'answer_type': 'choice',
     'options': ['Fast-growing trees (eucalyptus, casuarina…)', 'Slow-growing trees', 'Bamboo', 'Creepers on tower', 'Crop / bushes']},
    {'key': 'count', 'question_text': 'How many are affected?', 'answer_type': 'number', 'unit': 'nos'},
    {'key': 'discCount', 'question_text': 'How many discs are affected?', 'answer_type': 'number', 'unit': 'discs'},
    {'key': 'strandCount', 'question_text': 'How many strands are cut / damaged?', 'answer_type': 'number', 'unit': 'strands'},
    {'key': 'distance', 'question_text': 'Approximate distance from the tower?', 'answer_type': 'number', 'unit': 'm'},
    {'key': 'clearance', 'question_text': 'Measured / estimated clearance from conductor?', 'answer_type': 'number', 'unit': 'm'},
    {'key': 'jumperClr', 'question_text': 'Measured clearance of jumper to tower body?', 'answer_type': 'number', 'unit': 'm'},
    {'key': 'resistance', 'question_text': 'Measured tower-footing resistance?', 'answer_type': 'number', 'unit': 'Ω'},
    {'key': 'exposedLen', 'question_text': 'Length of counterpoise exposed / missing?', 'answer_type': 'number', 'unit': 'm'},
    {'key': 'theftHeight', 'question_text': 'Up to what height from ground is it missing?', 'answer_type': 'number', 'unit': 'm'},
    {'key': 'locationText', 'question_text': 'Describe the exact location', 'answer_type': 'text',
     'placeholder': 'e.g. B-phase cross-arm tip · 40 m into forward span…'},
]

# Each item: key, sno, group, label, plus optional positions/pos_meta/availability
# flags/applicable_tower_types/na_reason, plus its defects (each with an
# optional critRule expressed as a tiny list of CriticalityRule dict specs).
ITEMS = [
    {'key': 'coping', 'sno': 4, 'group': 'civil', 'label': 'Coping and Rivetment', 'defects': [
        {'key': 'coping_cracked', 'label': 'Coping cracked / spalled', 'ask': ['leg', 'crackExtent'], 'default_criticality': 'minor',
         'rules': [{'follow_up_key': 'crackExtent', 'operator': 'eq', 'threshold_value': 'Major structural crack / broken', 'resulting_criticality': 'major', 'priority': 0}]},
        {'key': 'revet_eroded', 'label': 'Revetment eroded / washed out / missing', 'ask': ['erosion'], 'default_criticality': 'major',
         'rules': [{'follow_up_key': 'erosion', 'operator': 'eq', 'threshold_value': 'Less than 25%', 'resulting_criticality': 'minor', 'priority': 0}]},
        {'key': 'coping_buried', 'label': 'Coping buried / soil accumulated', 'ask': ['leg'], 'default_criticality': 'minor'},
    ]},
    {'key': 'tower_condition', 'sno': 5, 'group': 'tower', 'label': 'Condition of tower', 'defects': [
        {'key': 'submerged', 'label': 'Submerged in water', 'ask': ['locationText'], 'default_criticality': 'major'},
        {'key': 'covered_growth', 'label': 'Covered with trees / creepers', 'ask': [], 'default_criticality': 'minor'},
    ]},
    {'key': 'members', 'sno': 6, 'group': 'tower', 'label': 'Tower members', 'defects': [
        {'key': 'members_missing', 'label': 'Members missing (theft)', 'ask': ['memberType', 'towerLoc', 'count'], 'default_criticality': 'major',
         'rules': [
             {'follow_up_key': 'memberType', 'operator': 'eq', 'threshold_value': 'Main leg / corner member', 'resulting_criticality': 'critical', 'priority': 0},
             {'follow_up_key': 'count', 'operator': 'gte', 'threshold_value': 6, 'resulting_criticality': 'critical', 'priority': 1},
         ]},
        {'key': 'members_bent', 'label': 'Members bent / damaged', 'ask': ['memberType', 'towerLoc', 'count'], 'default_criticality': 'major'},
        {'key': 'members_corroded', 'label': 'Members heavily corroded', 'ask': ['towerLoc'], 'default_criticality': 'minor'},
    ]},
    {'key': 'bolts', 'sno': 7, 'group': 'tower', 'label': 'Tower bolts and nuts, step bolts', 'defects': [
        {'key': 'bolts_missing', 'label': 'Bolts / nuts missing (theft)', 'ask': ['boltType', 'count', 'towerLoc'], 'default_criticality': 'minor',
         'rules': [{'follow_up_key': 'count', 'operator': 'gte', 'threshold_value': 10, 'resulting_criticality': 'major', 'priority': 0}]},
        {'key': 'bolts_loose', 'label': 'Bolts loose', 'ask': ['count', 'towerLoc'], 'default_criticality': 'minor'},
        {'key': 'bolts_corroded', 'label': 'Corroded', 'ask': ['towerLoc'], 'default_criticality': 'minor'},
    ]},
    {'key': 'boards', 'sno': 8, 'group': 'tower', 'label': 'Danger boards', 'defects': [
        {'key': 'board_missing', 'label': 'Board / plate missing', 'ask': ['boardType'], 'default_criticality': 'minor'},
        {'key': 'board_damaged', 'label': 'Damaged / illegible', 'ask': ['boardType'], 'default_criticality': 'minor'},
    ]},
    {'key': 'anti_climb', 'sno': 9, 'group': 'tower', 'label': 'Anti-climbing device', 'availability': True, 'defects': [
        {'key': 'ac_missing', 'label': 'Missing', 'ask': [], 'default_criticality': 'minor'},
        {'key': 'ac_damaged', 'label': 'Damaged / ineffective', 'ask': [], 'default_criticality': 'minor'},
    ]},
    {'key': 'painting', 'sno': 10, 'group': 'tower', 'label': 'Painting', 'defects': [
        {'key': 'paint_rusted', 'label': 'Members rusted / paint failed', 'ask': ['paintExtent'], 'default_criticality': 'minor',
         'rules': [{'follow_up_key': 'paintExtent', 'operator': 'eq', 'threshold_value': 'More than 50% of members', 'resulting_criticality': 'major', 'priority': 0}]},
        {'key': 'paint_faded', 'label': 'Paint faded', 'ask': [], 'default_criticality': 'minor'},
        {'key': 'paint_absent', 'label': 'Paint not available', 'ask': [], 'default_criticality': 'minor'},
    ]},
    {'key': 'insulators', 'sno': 11, 'group': 'hardware', 'label': 'Insulators', 'positions': POS3, 'pos_meta': INSULATOR_META, 'defects': [
        {'key': 'disc_broken', 'label': 'Disc broken / cracked', 'ask': ['discCount'], 'default_criticality': 'major',
         'rules': [{'follow_up_key': 'discCount', 'operator': 'gte', 'threshold_value': 2, 'resulting_criticality': 'critical', 'priority': 0}]},
        {'key': 'disc_punctured', 'label': 'Disc punctured', 'ask': ['discCount'], 'default_criticality': 'critical'},
        {'key': 'flashover_marks', 'label': 'Flashover marks on string', 'ask': [], 'default_criticality': 'major'},
        {'key': 'disc_polluted', 'label': 'Heavily polluted / dirty discs', 'ask': [], 'default_criticality': 'minor'},
        {'key': 'string_displaced', 'label': 'String tilted / displaced', 'ask': ['locationText'], 'default_criticality': 'major'},
    ]},
    {'key': 'susp_hw', 'sno': 12, 'group': 'hardware', 'label': 'Suspension hardware (clamps & fittings)',
     'applicable_tower_types': SP_TYPES, 'na_reason': SP_REASON, 'positions': POS3, 'defects': [
        {'key': 'hw_hotspot', 'label': 'Hot-spot signs / discolouration', 'ask': ['locationText'], 'default_criticality': 'critical'},
        {'key': 'hw_part_missing', 'label': 'Part missing', 'ask': ['clampPart', 'locationText'], 'default_criticality': 'major'},
        {'key': 'hw_loose', 'label': 'Loose bolts on clamp', 'ask': ['count'], 'default_criticality': 'major'},
        {'key': 'hw_corroded', 'label': 'Clamp corroded', 'ask': [], 'default_criticality': 'minor'},
    ]},
    {'key': 'tens_hw', 'sno': 13, 'group': 'hardware', 'label': 'Tension hardware (dead-end & PG clamps)',
     'applicable_tower_types': CP_TYPES, 'na_reason': CP_REASON, 'positions': POS3, 'defects': [
        {'key': 'thw_hotspot', 'label': 'Hot-spot at clamp / PG clamp', 'ask': ['locationText'], 'default_criticality': 'critical'},
        {'key': 'thw_part_missing', 'label': 'Part missing', 'ask': ['clampPart', 'locationText'], 'default_criticality': 'major'},
        {'key': 'thw_loose', 'label': 'Loose bolts', 'ask': ['count'], 'default_criticality': 'major'},
        {'key': 'thw_corroded', 'label': 'Corroded', 'ask': [], 'default_criticality': 'minor'},
    ]},
    {'key': 'wpins', 'sno': 14, 'group': 'hardware', 'label': 'W Pins and split pins (cotter pins)', 'positions': POS3, 'defects': [
        {'key': 'wpin_missing', 'label': 'W pin / split pin missing', 'ask': ['count', 'locationText'], 'default_criticality': 'major',
         'rules': [{'follow_up_key': 'count', 'operator': 'gte', 'threshold_value': 3, 'resulting_criticality': 'critical', 'priority': 0}]},
        {'key': 'wpin_unseated', 'label': 'Pin not properly seated', 'ask': ['count'], 'default_criticality': 'minor'},
        {'key': 'wpin_corroded', 'label': 'Pins corroded', 'ask': ['count'], 'default_criticality': 'minor'},
    ]},
    {'key': 'dampers', 'sno': 15, 'group': 'hardware', 'label': 'Vibration dampers', 'positions': POS3EW, 'defects': [
        {'key': 'damper_missing', 'label': 'Damper missing', 'ask': ['span', 'count'], 'default_criticality': 'major'},
        {'key': 'damper_slipped', 'label': 'Slipped from position', 'ask': ['span', 'distance'], 'default_criticality': 'minor'},
        {'key': 'damper_damaged', 'label': 'Damaged / weights hanging', 'ask': ['count'], 'default_criticality': 'minor'},
    ]},
    {'key': 'horns', 'sno': 16, 'group': 'hardware', 'label': 'Arcing horns', 'positions': POS3, 'defects': [
        {'key': 'horn_missing', 'label': 'Horn missing', 'ask': ['hornEnd'], 'default_criticality': 'major'},
        {'key': 'horn_bent', 'label': 'Bent / damaged', 'ask': ['hornEnd'], 'default_criticality': 'minor'},
        {'key': 'horn_gap', 'label': 'Incorrect horn gap', 'ask': [], 'default_criticality': 'major'},
    ]},
    {'key': 'armour', 'sno': 17, 'group': 'hardware', 'label': 'Armour rods',
     'applicable_tower_types': SP_TYPES, 'na_reason': SP_REASON, 'positions': POS3, 'defects': [
        {'key': 'armour_displaced', 'label': 'Displaced / slipped from clamp', 'ask': [], 'default_criticality': 'major'},
        {'key': 'armour_broken', 'label': 'Broken / spread ends', 'ask': ['count'], 'default_criticality': 'major'},
        {'key': 'armour_missing', 'label': 'Missing', 'ask': ['locationText'], 'default_criticality': 'major'},
    ]},
    {'key': 'birdguards', 'sno': 18, 'group': 'hardware', 'label': 'Bird guards',
     'applicable_tower_types': SP_TYPES, 'na_reason': SP_REASON, 'availability': True, 'positions': POS3, 'defects': [
        {'key': 'bg_missing', 'label': 'Missing', 'ask': ['count'], 'default_criticality': 'minor'},
        {'key': 'bg_damaged', 'label': 'Damaged', 'ask': ['count'], 'default_criticality': 'minor'},
    ]},
    {'key': 'conductor', 'sno': 19, 'group': 'conductor', 'label': 'Conductor', 'positions': POS3, 'defects': [
        {'key': 'strands_cut', 'label': 'Strands cut / damaged', 'ask': ['span', 'strandCount', 'distance'], 'default_criticality': 'major',
         'rules': [{'follow_up_key': 'strandCount', 'operator': 'gte', 'threshold_value': 3, 'resulting_criticality': 'critical', 'priority': 0}]},
        {'key': 'bird_caging', 'label': 'Bird caging / loose strands', 'ask': ['span', 'distance'], 'default_criticality': 'major'},
        {'key': 'sag_abnormal', 'label': 'Abnormal sag / low clearance', 'ask': ['span', 'clearance'], 'default_criticality': 'major',
         'rules': [{'follow_up_key': 'clearance', 'operator': 'lte', 'threshold_value': 6, 'resulting_criticality': 'critical', 'priority': 0}]},
        {'key': 'conductor_flash', 'label': 'Flashover / burn marks on conductor', 'ask': ['span', 'distance'], 'default_criticality': 'major'},
    ]},
    {'key': 'midspan', 'sno': 20, 'group': 'conductor', 'label': 'Mid span joints', 'positions': POS3, 'pos_availability': True, 'defects': [
        {'key': 'joint_hotspot', 'label': 'Hot-spot / discolouration at joint', 'ask': ['span'], 'default_criticality': 'critical'},
        {'key': 'joint_damaged', 'label': 'Joint damaged / deformed', 'ask': ['span'], 'default_criticality': 'major'},
    ]},
    {'key': 'sleeves', 'sno': 21, 'group': 'conductor', 'label': 'Repair sleeves', 'positions': POS3, 'pos_availability': True, 'defects': [
        {'key': 'sleeve_hotspot', 'label': 'Hot-spot / discolouration at sleeve', 'ask': ['span', 'distance'], 'default_criticality': 'critical'},
        {'key': 'sleeve_damaged', 'label': 'Sleeve damaged / displaced', 'ask': ['span', 'distance'], 'default_criticality': 'major'},
    ]},
    {'key': 'jumpers', 'sno': 22, 'group': 'conductor', 'label': 'Jumper, terminal dead end joints',
     'applicable_tower_types': CP_TYPES, 'na_reason': CP_REASON, 'positions': POS3, 'defects': [
        {'key': 'jumper_hotspot', 'label': 'Hot-spot at jumper / dead-end joint', 'ask': ['locationText'], 'default_criticality': 'critical'},
        {'key': 'jumper_clearance', 'label': 'Jumper loose / low clearance to tower', 'ask': ['jumperClr'], 'default_criticality': 'major',
         'rules': [{'follow_up_key': 'jumperClr', 'operator': 'lte', 'threshold_value': 1.5, 'resulting_criticality': 'critical', 'priority': 0}]},
        {'key': 'deadend_damaged', 'label': 'Dead-end joint damaged', 'ask': [], 'default_criticality': 'major'},
    ]},
    {'key': 'trees', 'sno': 23, 'group': 'conductor', 'label': 'Tree clearance (checked to bottom conductor)', 'defects': [
        {'key': 'tree_infringing', 'label': 'Inadequate clearance to conductor', 'ask': ['span', 'clearance', 'treeKind'], 'default_criticality': 'minor',
         'rules': [
             {'follow_up_key': 'clearance', 'operator': 'lte', 'threshold_value': 4, 'resulting_criticality': 'critical', 'priority': 0},
             {'follow_up_key': 'clearance', 'operator': 'lte', 'threshold_value': 6, 'resulting_criticality': 'major', 'priority': 1},
         ]},
        {'key': 'tree_growing', 'label': 'Growth approaching the line', 'ask': ['span', 'treeKind'], 'default_criticality': 'minor'},
        {'key': 'creepers', 'label': 'Creepers on tower', 'ask': [], 'default_criticality': 'minor'},
    ]},
    {'key': 'earthwire', 'sno': 24, 'group': 'earthing', 'label': 'Earth wire', 'defects': [
        {'key': 'ew_strands', 'label': 'Strands cut / damaged', 'ask': ['span', 'strandCount', 'distance'], 'default_criticality': 'major',
         'rules': [{'follow_up_key': 'strandCount', 'operator': 'gte', 'threshold_value': 3, 'resulting_criticality': 'critical', 'priority': 0}]},
        {'key': 'ew_corroded', 'label': 'Corroded', 'ask': ['span'], 'default_criticality': 'minor'},
        {'key': 'ew_sag', 'label': 'Abnormal sag', 'ask': ['span'], 'default_criticality': 'major'},
    ]},
    {'key': 'ew_hardware', 'sno': 25, 'group': 'earthing', 'label': 'Earth wire hardware (clamps & shackles)', 'defects': [
        {'key': 'ewh_hotspot', 'label': 'Hot-spot signs / discolouration', 'ask': ['locationText'], 'default_criticality': 'critical'},
        {'key': 'ewh_loose', 'label': 'Clamp / shackle loose or damaged', 'ask': ['locationText'], 'default_criticality': 'major'},
        {'key': 'ewh_missing', 'label': 'Part missing', 'ask': ['locationText'], 'default_criticality': 'major'},
        {'key': 'ewh_corroded', 'label': 'Corroded', 'ask': [], 'default_criticality': 'minor'},
    ]},
    {'key': 'earthbond', 'sno': 26, 'group': 'earthing', 'label': 'Earth bond', 'defects': [
        {'key': 'ebond_cut', 'label': 'Cut / broken', 'ask': ['locationText'], 'default_criticality': 'major'},
        {'key': 'ebond_loose', 'label': 'Loose connection', 'ask': ['locationText'], 'default_criticality': 'minor'},
        {'key': 'ebond_missing', 'label': 'Missing', 'ask': ['locationText'], 'default_criticality': 'major'},
    ]},
    {'key': 'earthstrip', 'sno': 27, 'group': 'earthing', 'label': 'Earth Strip', 'defects': [
        {'key': 'estrip_stolen', 'label': 'Cut / stolen', 'ask': ['leg', 'theftHeight'], 'default_criticality': 'major'},
        {'key': 'estrip_corroded', 'label': 'Corroded', 'ask': ['leg'], 'default_criticality': 'minor'},
        {'key': 'estrip_missing', 'label': 'Missing', 'ask': ['leg'], 'default_criticality': 'major'},
    ]},
    {'key': 'earthpit', 'sno': 28, 'group': 'earthing', 'label': 'Earth pit and counter poise earthing', 'availability': True, 'defects': [
        {'key': 'high_resistance', 'label': 'High footing resistance', 'ask': ['resistance'], 'default_criticality': 'minor',
         'rules': [
             {'follow_up_key': 'resistance', 'operator': 'gte', 'threshold_value': 20, 'resulting_criticality': 'critical', 'priority': 0},
             {'follow_up_key': 'resistance', 'operator': 'gte', 'threshold_value': 10, 'resulting_criticality': 'major', 'priority': 1},
         ]},
        {'key': 'counterpoise_exposed', 'label': 'Counterpoise exposed / cut', 'ask': ['leg', 'exposedLen'], 'default_criticality': 'major'},
        {'key': 'earthpit_damaged', 'label': 'Earth pit damaged / missing', 'ask': ['leg'], 'default_criticality': 'major'},
    ]},
]


class Command(BaseCommand):
    help = 'Seed/refresh the checklist catalog (groups, items, defects, follow-up questions, criticality rules).'

    @transaction.atomic
    def handle(self, *args, **options):
        for i, fu in enumerate(FOLLOW_UPS):
            FollowUpQuestion.objects.update_or_create(
                key=fu['key'],
                defaults={
                    'question_text': fu['question_text'],
                    'answer_type': fu['answer_type'],
                    'options': fu.get('options', []),
                    'unit': fu.get('unit', ''),
                    'placeholder': fu.get('placeholder', ''),
                },
            )

        groups_by_key = {}
        for i, g in enumerate(GROUPS):
            group, _ = ChecklistItemGroup.objects.update_or_create(
                key=g['key'], defaults={'label': g['label'], 'sort_order': i},
            )
            groups_by_key[g['key']] = group

        item_count = defect_count = rule_count = 0
        for i, spec in enumerate(ITEMS):
            item, _ = ChecklistItem.objects.update_or_create(
                key=spec['key'],
                defaults={
                    'group': groups_by_key[spec['group']],
                    'sno': spec['sno'],
                    'label': spec['label'],
                    'sort_order': i,
                    'positions': spec.get('positions', []),
                    'pos_meta': spec.get('pos_meta'),
                    'is_availability_gated': spec.get('availability', False),
                    'is_position_availability_gated': spec.get('pos_availability', False),
                    'applicable_tower_types': spec.get('applicable_tower_types', []),
                    'na_reason': spec.get('na_reason', ''),
                },
            )
            item_count += 1

            for j, defect_spec in enumerate(spec['defects']):
                defect, _ = Defect.objects.update_or_create(
                    item=item, key=defect_spec['key'],
                    defaults={
                        'label': defect_spec['label'],
                        'sort_order': j,
                        'ask': defect_spec.get('ask', []),
                        'default_criticality': defect_spec['default_criticality'],
                    },
                )
                defect_count += 1

                CriticalityRule.objects.filter(defect=defect).delete()
                for k, rule_spec in enumerate(defect_spec.get('rules', [])):
                    CriticalityRule.objects.create(
                        defect=defect,
                        follow_up_key=rule_spec['follow_up_key'],
                        operator=rule_spec['operator'],
                        threshold_value=rule_spec['threshold_value'],
                        resulting_criticality=rule_spec['resulting_criticality'],
                        priority=rule_spec.get('priority', k),
                    )
                    rule_count += 1

        CatalogVersion.bump()

        self.stdout.write(self.style.SUCCESS(
            f'Seeded {len(GROUPS)} groups, {item_count} items, {defect_count} defects, '
            f'{rule_count} criticality rules, {len(FOLLOW_UPS)} follow-up questions. '
            f'catalog_version is now {CatalogVersion.current()}.'
        ))
