"""Flag deactivated towers that still carry inspection history / active range
assignments AND have a co-located active tower — i.e. a likely undeclared LILO
or road-works shift where history would be stranded. Read-only; flags only.
On-demand (Super-Admin / scheduled), never run by the routine ArcGIS sync.

    python manage.py detect_tower_churn            # whole system
    python manage.py detect_tower_churn --line 42  # one line's deactivated towers
"""
from django.core.management.base import BaseCommand

from line_inspection.models import Line
from line_inspection.services import lilo_matching as lm


class Command(BaseCommand):
    help = 'Flag stranded-history towers with a co-located active twin (possible undeclared LILO/shift).'

    def add_arguments(self, parser):
        parser.add_argument('--line', type=int, default=None, help='Scope to one line id.')

    def handle(self, *args, **options):
        line = Line.objects.filter(pk=options['line']).first() if options['line'] else None
        flags = lm.detect_churn(line=line)
        if not flags:
            self.stdout.write('No stranded-history towers with co-located active twins found.')
            return
        self.stdout.write(f'{len(flags)} possible churn flag(s):')
        for f in flags:
            s, t = f['stranded'], f['twin']
            self.stdout.write(f"  stranded T-{s.tower_number} ({s.line_name}) <-> "
                              f"active T-{t.tower_number} ({t.line_name}) · {f['distance_m']} m")
