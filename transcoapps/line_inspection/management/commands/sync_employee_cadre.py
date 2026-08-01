"""Syncs employee cadre/position details from the live SAP RFC service into
our own EmployeeCadreSnapshot table (the `clear` schema). Never queried live
per request — RoleAssignment eligibility checks read this local cache.

Run on a schedule (see run_sync_scheduler) — hourly by default.
"""
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from line_inspection.models import EmployeeCadreSnapshot
from line_inspection.services.sap_client import get_employee_cadre_details, SapClientError


class Command(BaseCommand):
    help = 'Sync employee cadre/position details from the live SAP service into EmployeeCadreSnapshot.'

    def add_arguments(self, parser):
        parser.add_argument(
            '--root-employee-id', default=None,
            help='Employee id to fetch the hierarchy/cadre details for (defaults to SAP_HIERARCHY_ROOT_EMPLOYEE_ID env var).',
        )

    def handle(self, *args, **options):
        try:
            employees = get_employee_cadre_details(root_employee_id=options['root_employee_id'])
        except SapClientError as exc:
            raise CommandError(str(exc))

        with transaction.atomic():
            seen_ids = set()
            for emp in employees:
                employee_id = str(emp.get('EMP_ID') or '').strip()
                if not employee_id:
                    continue
                seen_ids.add(employee_id)
                EmployeeCadreSnapshot.objects.update_or_create(
                    employee_id=employee_id,
                    defaults={
                        'employee_name': emp.get('EMP_NAME', '') or '',
                        'position_id': str(emp.get('EMP_POSITION') or emp.get('POSITION_ID') or ''),
                        'position_text': emp.get('EMP_POS_TEXT') or emp.get('POSITION_TEXT') or '',
                        'org_unit_id': str(emp.get('ORG_UNIT_ID') or ''),
                        'org_unit_text': emp.get('ORG_UNIT_TEXT') or emp.get('WORKING_LOC_DES') or '',
                        'emp_sub_grp': emp.get('EMP_SUB_GROUP') or emp.get('EMP_SUB_GRP') or '',
                        'emp_sub_grp_desc': emp.get('EMP_SUB_GRP_DESC') or '',
                        'mobile': str(emp.get('mobileno') or emp.get('MOBILE') or ''),
                        'mail': emp.get('mail') or emp.get('MAIL') or '',
                        'reporting_manager_id': str(emp.get('REPORTING_MANAGER_ID') or ''),
                        'reporting_manager_name': emp.get('REPORTING_MANAGER_NAME') or '',
                    },
                )

        self.stdout.write(self.style.SUCCESS(f'Synced cadre details for {len(seen_ids)} employees.'))
