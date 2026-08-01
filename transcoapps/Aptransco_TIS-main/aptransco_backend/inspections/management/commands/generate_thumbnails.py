from django.core.management.base import BaseCommand
from django.db.models import Q

from inspections.models import InspectionImage
from inspections.thumbnails import build_thumbnail


class Command(BaseCommand):
    help = (
        'Backfill thumbnails for inspection images uploaded before '
        'thumbnail generation existed.'
    )

    def handle(self, *args, **options):
        missing = InspectionImage.objects.filter(
            Q(thumbnail='') | Q(thumbnail__isnull=True)
        )
        total = missing.count()
        done = failed = 0

        for image in missing.iterator():
            try:
                with image.image.open('rb') as source:
                    thumb = build_thumbnail(source, name_hint=image.image.name)
            except (OSError, ValueError):
                thumb = None

            if thumb is None:
                failed += 1
                self.stderr.write(f'FAILED: image id={image.id} ({image.image.name})')
                continue

            image.thumbnail.save(thumb.name, thumb, save=True)
            done += 1

        self.stdout.write(
            self.style.SUCCESS(
                f'Thumbnails: {done} generated, {failed} failed, {total} were missing.'
            )
        )
