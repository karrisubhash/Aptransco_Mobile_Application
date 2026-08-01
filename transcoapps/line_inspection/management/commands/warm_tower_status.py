"""Rebuild the Tower.last_* denormalized inspection-status cache from the
Inspection table. Idempotent — run once after deploying the Phase 3 cache
fields (migration 0003), and any time the cache is suspected stale. Day to day
the cache is kept current by api.views._create_inspection; this is the bulk
backfill / repair path."""
from django.core.management.base import BaseCommand

from line_inspection.models import Tower, Inspection


class Command(BaseCommand):
    help = "Rebuild Tower.last_* inspection-status cache from Inspection rows."

    def handle(self, *args, **options):
        tower_ids = list(Inspection.objects.values_list('tower_id', flat=True).distinct())
        if not tower_ids:
            self.stdout.write('No inspections found — nothing to warm.')
            return

        # Latest inspection (any type) per tower via Postgres DISTINCT ON.
        latest = (
            Inspection.objects.filter(tower_id__in=tower_ids)
            .order_by('tower_id', '-saved_at', '-id')
            .distinct('tower_id')
            .values('tower_id', 'saved_at', 'worst_criticality', 'inspection_type')
        )
        by_tower = {row['tower_id']: row for row in latest}

        towers = list(Tower.objects.filter(id__in=by_tower.keys()))
        for tower in towers:
            row = by_tower[tower.id]
            tower.last_inspection_at = row['saved_at']
            tower.last_worst_criticality = row['worst_criticality']
            tower.last_inspection_type = row['inspection_type']

        Tower.objects.bulk_update(
            towers, ['last_inspection_at', 'last_worst_criticality', 'last_inspection_type'], batch_size=500
        )
        self.stdout.write(self.style.SUCCESS(f'Warmed status cache for {len(towers)} inspected towers.'))
