"""Imports the raw SAP line master data (Excel export) into SapLine.

This creates NO mapping to ArcGIS Lines by itself — it's raw SAP data only.
Run map_sap_lines afterwards (or use the SAP<->ArcGIS mapping admin page)
to actually link Line.sap_line.

Re-run whenever a new dated SAP export arrives (--file <path>).
"""
import re

import pandas as pd
from django.conf import settings
from django.core.management.base import BaseCommand, CommandError

from line_inspection.models import SapLine

DEFAULT_FILE = settings.BASE_DIR / 'EHT LINES SAP DATA 06.07.2026.XLSX'
VOLTAGE_RE = re.compile(r'(\d+)\s*KV', re.IGNORECASE)


def _parse_voltage(*texts):
    for text in texts:
        match = VOLTAGE_RE.search(str(text or ''))
        if match:
            return f'{match.group(1)}kV'
    return ''


class Command(BaseCommand):
    help = 'Import the SAP line Excel export (Functional Location / Description) into SapLine.'

    def add_arguments(self, parser):
        parser.add_argument('--file', default=None, help='Path to the SAP line Excel export.')

    def handle(self, *args, **options):
        path = options['file'] or DEFAULT_FILE
        try:
            df = pd.read_excel(path)
        except FileNotFoundError:
            raise CommandError(f'SAP line file not found: {path}')

        required = {'Functional Location', 'Description of functional location'}
        if not required.issubset(df.columns):
            raise CommandError(f'Expected columns {required}, got {list(df.columns)}')

        created = updated = 0
        for _, row in df.iterrows():
            functional_location = str(row['Functional Location'] or '').strip()
            if not functional_location:
                continue
            description = str(row['Description of functional location'] or '').strip()
            raw_row = {k: (None if pd.isna(v) else v) for k, v in row.to_dict().items()}

            _, was_created = SapLine.objects.update_or_create(
                functional_location=functional_location,
                defaults={
                    'description': description,
                    'voltage': _parse_voltage(functional_location, description),
                    'raw_row': raw_row,
                },
            )
            created += was_created
            updated += not was_created

        self.stdout.write(self.style.SUCCESS(
            f'Imported {created + updated} SAP lines from {path} ({created} new, {updated} updated).'
        ))
