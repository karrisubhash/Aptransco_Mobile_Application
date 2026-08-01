from django.db import models

class Inspection(models.Model):
    class Status(models.TextChoices):
        PENDING = 'pending', 'Pending'
        REVIEWED = 'reviewed', 'Reviewed'
        FLAGGED = 'flagged', 'Flagged'

    # Client-generated idempotency key. The app sends the same UUID on every
    # retry of one inspection (including offline-queue re-syncs), so a request
    # that timed out after the server had already saved doesn't create a
    # duplicate record. Null for legacy rows / clients that don't send one.
    client_id = models.CharField(
        max_length=64, unique=True, null=True, blank=True, default=None
    )

    transmission_line_id = models.IntegerField()
    line_name = models.CharField(max_length=200, blank=True, default='')
    tower_location = models.CharField(max_length=100)
    voltage = models.CharField(max_length=20, blank=True, default='')
    component = models.CharField(max_length=100, blank=True, default='')
    defect = models.CharField(max_length=100, blank=True, default='')
    latitude = models.FloatField(null=True, blank=True)
    longitude = models.FloatField(null=True, blank=True)
    captured_at = models.DateTimeField(null=True, blank=True)
    created_at = models.DateTimeField(auto_now_add=True)

    status = models.CharField(max_length=10, choices=Status.choices, default=Status.PENDING)
    review_notes = models.TextField(blank=True, default='')
    reviewed_at = models.DateTimeField(null=True, blank=True)

    class Meta:
        ordering = ['-created_at']
        indexes = [
            # The status + history endpoints both filter on line (and
            # optionally tower) then sort/aggregate by created_at.
            models.Index(
                fields=['transmission_line_id', 'tower_location'],
                name='insp_line_tower_idx',
            ),
            models.Index(fields=['-created_at'], name='insp_created_idx'),
        ]

    def __str__(self):
        return f"{self.tower_location} - {self.component} - {self.defect}"


class InspectionImage(models.Model):
    inspection = models.ForeignKey(
        Inspection, related_name='images', on_delete=models.CASCADE
    )
    image = models.ImageField(upload_to='inspections/')
    # Small (≤400px) JPEG generated at upload time. History/gallery grids in
    # the app render 72px tiles — serving the full-resolution original for
    # those wastes ~95% of the bandwidth. Null on rows that predate this
    # field until `manage.py generate_thumbnails` backfills them; clients
    # fall back to the full image when absent.
    thumbnail = models.ImageField(
        upload_to='inspections/thumbs/', null=True, blank=True
    )

    def __str__(self):
        return f"Image for {self.inspection_id}"
