"""Auto-maps ArcGIS Lines to SAP Lines (SapLine) by name-similarity scoring.

High-confidence matches are written directly to Line.sap_line. Anything
ambiguous is left unmatched for manual review on the SAP<->ArcGIS mapping
admin page, which uses the same scoring (services/sap_matching.py) to show
ranked suggestions.
"""
from django.core.management.base import BaseCommand
from django.db import transaction

from line_inspection.models import Line, SapLine
from line_inspection.services.sap_matching import find_best_matches, is_high_confidence


class Command(BaseCommand):
    help = 'Auto-match unmapped ArcGIS Lines to SAP Lines by name similarity; write high-confidence matches.'

    def add_arguments(self, parser):
        parser.add_argument('--dry-run', action='store_true', help="Report matches without writing them.")

    def handle(self, *args, **options):
        sap_lines = list(SapLine.objects.all())
        claimed_sap_line_ids = set(Line.objects.exclude(sap_line=None).values_list('sap_line_id', flat=True))

        matched = ambiguous = 0
        with transaction.atomic():
            for line in Line.objects.filter(sap_line__isnull=True, is_active=True):
                candidates = [sl for sl in sap_lines if sl.id not in claimed_sap_line_ids]
                best = find_best_matches(line, candidates, top_n=1)
                if not best:
                    continue

                sap_line, score, reason = best[0]
                if is_high_confidence(score):
                    matched += 1
                    self.stdout.write(f'  {line.name!r} -> {sap_line.functional_location} ({reason}, score={score:.2f})')
                    if not options['dry_run']:
                        line.sap_line = sap_line
                        line.save(update_fields=['sap_line'])
                        claimed_sap_line_ids.add(sap_line.id)
                else:
                    ambiguous += 1

        self.stdout.write(self.style.SUCCESS(
            f'{matched} lines auto-matched, {ambiguous} left for manual review'
            f'{" (dry run — nothing written)" if options["dry_run"] else ""}.'
        ))
