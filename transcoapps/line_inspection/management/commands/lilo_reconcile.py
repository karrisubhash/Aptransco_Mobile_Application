"""Report / apply a LILO reconcile for a LiloEvent — a Super-Admin operation.

By default prints the proposed mapping (auto / review / new). With --apply it
applies the AUTO matches + NEW towers immediately (history-preserving in-place
revive of survivors); REVIEW pairs need a human and are left for the Super-Admin
LILO screen. Never run by the routine ArcGIS sync.

    python manage.py lilo_reconcile --event 3
    python manage.py lilo_reconcile --event 3 --apply
"""
from django.core.management.base import BaseCommand, CommandError
from django.utils import timezone

from line_inspection.models import LiloEvent
from line_inspection.services import lilo_matching as lm


class Command(BaseCommand):
    help = 'Report or apply the tower reconcile for a LILO event (Super-Admin).'

    def add_arguments(self, parser):
        parser.add_argument('--event', type=int, required=True)
        parser.add_argument('--apply', action='store_true',
                            help='Apply AUTO matches + NEW towers now; REVIEW pairs are left for the screen.')

    def handle(self, *args, **options):
        try:
            event = LiloEvent.objects.get(pk=options['event'])
        except LiloEvent.DoesNotExist:
            raise CommandError(f"LiloEvent #{options['event']} not found.")

        res = lm.propose_matches(event)
        c = res['counts']
        self.stdout.write(f"LILO #{event.pk} — old line {event.old_line.name!r}: "
                          f"auto={c['auto']} review={c['review']} new={c['new']} unmatched_old={c['unmatched_old']}")
        for p in res['pairs']:
            old = p['old_tower']
            target = (f"OLD T-{old.tower_number} ({p['distance_m']}m, num_match={p['number_match']})"
                      if old else "NEW")
            self.stdout.write(f"  [{p['method']:6s}] new T-{p['new_tower'].tower_number} -> {target}")

        if not options['apply']:
            self.stdout.write('(dry run — pass --apply to apply auto/new)')
            return

        decisions = {p['new_tower'].id: (p['old_tower'].id if p['method'] == 'auto' else None)
                     for p in res['pairs'] if p['method'] in ('auto', 'new')}
        summary = lm.apply_reconcile(event, decisions)
        if c['review'] == 0:
            event.applied_at = timezone.now()
            event.save(update_fields=['applied_at'])
            self.stdout.write(self.style.SUCCESS(
                f"Applied & closed: matched={summary['matched']} new={summary['new']}."))
        else:
            self.stdout.write(self.style.WARNING(
                f"Applied auto/new (matched={summary['matched']} new={summary['new']}); "
                f"{c['review']} review pair(s) remain — resolve on the LILO screen (event left open)."))
