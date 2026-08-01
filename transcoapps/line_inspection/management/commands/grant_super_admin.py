"""CLI-only bootstrap: grants Super Admin rights to an employee id.

Needed because an empty SuperAdmin table would otherwise lock everyone out
of the admin panel (nobody could grant the first one through the UI).
Idempotent — safe to re-run.
"""
from django.core.management.base import BaseCommand

from line_inspection.models import SuperAdmin


class Command(BaseCommand):
    help = 'Grant Super Admin rights to an employee id (bootstrap / CLI-only escape hatch).'

    def add_arguments(self, parser):
        parser.add_argument('--employee-id', required=True)
        parser.add_argument('--notes', default='')

    def handle(self, *args, **options):
        employee_id = options['employee_id'].strip()
        obj, created = SuperAdmin.objects.get_or_create(
            employee_id=employee_id, defaults={'notes': options['notes']},
        )
        if created:
            self.stdout.write(self.style.SUCCESS(f'Granted Super Admin to {employee_id}.'))
        else:
            self.stdout.write(f'{employee_id} is already a Super Admin.')
