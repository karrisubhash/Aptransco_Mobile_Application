import logging

from PIL import Image as PILImage
from django.db import IntegrityError, transaction
from django.db.models import Count, Max
from rest_framework import generics, status
from rest_framework.exceptions import ValidationError
from rest_framework.parsers import FormParser, MultiPartParser
from rest_framework.response import Response
from rest_framework.views import APIView
from .models import Inspection, InspectionImage
from .serializers import InspectionSerializer
from .thumbnails import build_thumbnail

logger = logging.getLogger('inspections')

MAX_IMAGES_PER_INSPECTION = 12
MAX_IMAGE_SIZE_BYTES = 15 * 1024 * 1024  # 15 MB per photo


class HealthView(APIView):
    """Cheap liveness/readiness probe — also exercises the database."""

    def get(self, request):
        Inspection.objects.exists()
        return Response({'status': 'ok'})


class InspectionCreateView(APIView):
    parser_classes = [MultiPartParser, FormParser]

    def post(self, request):
        serializer = InspectionSerializer(
            data=request.data, context={'request': request}
        )
        serializer.is_valid(raise_exception=True)

        images = request.FILES.getlist('images')
        error = self._validate_images(images)
        if error is not None:
            return Response({'detail': error}, status=status.HTTP_400_BAD_REQUEST)

        # Idempotent replay: if this client_id was already saved (the client
        # timed out and retried, or the offline queue re-synced), return the
        # existing record instead of creating a duplicate.
        client_id = serializer.validated_data.get('client_id')
        if client_id:
            existing = Inspection.objects.filter(client_id=client_id).first()
            if existing is not None:
                logger.info('Replayed inspection client_id=%s id=%s', client_id, existing.id)
                return self._respond(request, existing, status.HTTP_200_OK)

        try:
            with transaction.atomic():
                inspection = serializer.save()
                InspectionImage.objects.bulk_create(
                    InspectionImage(
                        inspection=inspection,
                        image=image_file,
                        thumbnail=build_thumbnail(
                            image_file, name_hint=image_file.name
                        ),
                    )
                    for image_file in images
                )
        except IntegrityError:
            # Two retries of the same client_id raced past the check above;
            # the one that lost the race returns the winner's record.
            existing = Inspection.objects.filter(client_id=client_id).first()
            if client_id and existing is not None:
                return self._respond(request, existing, status.HTTP_200_OK)
            raise

        logger.info(
            'Created inspection id=%s line=%s tower=%s images=%d',
            inspection.id, inspection.transmission_line_id,
            inspection.tower_location, len(images),
        )
        return self._respond(request, inspection, status.HTTP_201_CREATED)

    @staticmethod
    def _validate_images(images):
        if not images:
            return 'At least one image is required.'
        if len(images) > MAX_IMAGES_PER_INSPECTION:
            return (
                f'Too many images: {len(images)} '
                f'(maximum {MAX_IMAGES_PER_INSPECTION} per inspection).'
            )
        for image_file in images:
            if image_file.size > MAX_IMAGE_SIZE_BYTES:
                return (
                    f'Image "{image_file.name}" is too large '
                    f'(maximum {MAX_IMAGE_SIZE_BYTES // (1024 * 1024)} MB).'
                )
            # Confirm the bytes are actually a decodable image. Neither the
            # serializer (its `images` field is read-only) nor bulk_create
            # runs ImageField validation, so without this check a renamed
            # non-image file would be stored as a "photo" and later served
            # to the app as a broken image.
            try:
                image_file.seek(0)
                PILImage.open(image_file).verify()
            except Exception:
                return f'File "{image_file.name}" is not a valid image.'
            finally:
                image_file.seek(0)
        return None

    @staticmethod
    def _respond(request, inspection, http_status):
        output_serializer = InspectionSerializer(
            inspection, context={'request': request}
        )
        return Response(output_serializer.data, status=http_status)


class TowerInspectionHistoryView(generics.ListAPIView):
    serializer_class = InspectionSerializer

    def get_queryset(self):
        # Without this requirement a bare request would serialize the entire
        # inspections table (every record and image URL) in one response.
        raw_line_id = self.request.query_params.get('transmission_line_id')
        if raw_line_id is None:
            raise ValidationError({'detail': 'transmission_line_id is required'})
        try:
            line_id = int(raw_line_id)
        except ValueError:
            raise ValidationError(
                {'detail': 'transmission_line_id must be an integer'}
            )

        queryset = (
            Inspection.objects.prefetch_related('images')
            .filter(transmission_line_id=line_id)
            .order_by('-created_at')
        )
        tower_location = self.request.query_params.get('tower_location')
        if tower_location is not None:
            queryset = queryset.filter(tower_location=tower_location)
        return queryset


class InspectionStatusView(APIView):
    """Returns which towers on a transmission line already have inspections,
    so the app can show inspected/not-inspected status instead of just
    tracking the local offline-upload queue."""

    def get(self, request):
        line_id = request.query_params.get('transmission_line_id')
        if not line_id:
            return Response(
                {'detail': 'transmission_line_id is required'}, status=400
            )
        try:
            line_id = int(line_id)
        except ValueError:
            return Response(
                {'detail': 'transmission_line_id must be an integer'}, status=400
            )

        towers = (
            Inspection.objects.filter(transmission_line_id=line_id)
            .values('tower_location')
            .annotate(
                last_inspected_at=Max('created_at'),
                inspection_count=Count('id'),
            )
            .order_by('tower_location')
        )
        return Response(
            {
                'transmission_line_id': line_id,
                'inspected_towers': list(towers),
            }
        )