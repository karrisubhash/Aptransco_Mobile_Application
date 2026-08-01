"""Assign Tower.line_sequence (ordered position along each line) + line_offset_m.

Primary ordering: geometric projection of each tower onto its line's GeoJSON
LineString (distance along the line). Fallback (per line): numeric tower_number
sort, used when the line has no usable geometry OR is physically branched
(duplicate tower_numbers → Tap/LILO corridors, where a single along-line order is
ambiguous). Idempotent / re-runnable. See line_inspection/schedule.py.

    python manage.py build_tower_schedule
"""
from django.core.management.base import BaseCommand
from django.db import transaction

from line_inspection.models import Line, Tower
from line_inspection import schedule as sched

BATCH = 1000


class Command(BaseCommand):
    help = 'Compute Tower.line_sequence (tower schedule order) for every active line.'

    def handle(self, *args, **options):
        line_ids = list(Line.objects.filter(is_active=True).values_list('id', flat=True))
        self.stdout.write(f'Scheduling towers for {len(line_ids)} active lines ...')

        updated, geom_lines, fallback_lines = [], 0, 0
        for line in Line.objects.filter(id__in=line_ids).iterator():
            mode, ordered = sched.compute_line_order(line)   # shared logic; see schedule.py
            if mode == 'empty':
                continue
            if mode == 'geometry':
                geom_lines += 1
            else:
                fallback_lines += 1

            for seq, (t, offset) in enumerate(ordered, start=1):
                t.line_sequence = seq
                t.line_offset_m = round(offset, 2) if offset is not None else None
                updated.append(t)

            if len(updated) >= BATCH:
                self._flush(updated)
                updated = []

        if updated:
            self._flush(updated)

        self.stdout.write(self.style.SUCCESS(
            f'Done. {geom_lines} lines ordered by geometry, {fallback_lines} by tower_number fallback.'))

    def _flush(self, towers):
        with transaction.atomic(using='line_inspection_db'):
            Tower.objects.bulk_update(towers, ['line_sequence', 'line_offset_m'], batch_size=BATCH)
