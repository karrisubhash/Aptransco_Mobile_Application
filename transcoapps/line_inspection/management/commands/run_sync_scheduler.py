"""Long-running scheduler that periodically re-runs the ArcGIS and
employee-cadre syncs. No extra scheduling library — a plain sleep loop is
enough for this and keeps the dependency list small. Intended to be launched
as a standalone background process (e.g. via Windows Task Scheduler / a
service wrapper), not as part of the web server request cycle.

    python manage.py run_sync_scheduler
    python manage.py run_sync_scheduler --gis-interval-minutes 120 --cadre-interval-minutes 60
"""
import time
import traceback

from django.core.management import call_command
from django.core.management.base import BaseCommand
from django.utils import timezone


class Command(BaseCommand):
    help = 'Run sync_gis_towers and sync_employee_cadre on a repeating interval, forever.'

    def add_arguments(self, parser):
        parser.add_argument('--gis-interval-minutes', type=int, default=60)
        parser.add_argument('--cadre-interval-minutes', type=int, default=60)
        parser.add_argument('--run-once', action='store_true', help='Run each sync once and exit (for testing).')

    def handle(self, *args, **options):
        gis_interval = options['gis_interval_minutes'] * 60
        cadre_interval = options['cadre_interval_minutes'] * 60
        next_gis_run = 0
        next_cadre_run = 0

        while True:
            now = time.monotonic()

            if now >= next_gis_run:
                self._run('sync_gis_towers')
                next_gis_run = now + gis_interval

            if now >= next_cadre_run:
                self._run('sync_employee_cadre')
                next_cadre_run = now + cadre_interval

            if options['run_once']:
                return

            time.sleep(min(gis_interval, cadre_interval, 60))

    def _run(self, command_name):
        self.stdout.write(f'[{timezone.now().isoformat()}] running {command_name} ...')
        try:
            call_command(command_name)
        except Exception:
            self.stderr.write(f'{command_name} failed:\n{traceback.format_exc()}')
