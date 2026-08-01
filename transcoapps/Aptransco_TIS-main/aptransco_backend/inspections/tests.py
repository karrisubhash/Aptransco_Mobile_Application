import io
import tempfile

from django.core.files.uploadedfile import SimpleUploadedFile
from django.test import TestCase, override_settings
from django.urls import reverse
from PIL import Image

from .models import Inspection, InspectionImage
from .views import MAX_IMAGES_PER_INSPECTION

TEMP_MEDIA = tempfile.mkdtemp(prefix='aptransco_test_media_')


def make_image(name='photo.jpg', color=(255, 0, 0)):
    buffer = io.BytesIO()
    Image.new('RGB', (32, 32), color).save(buffer, format='JPEG')
    return SimpleUploadedFile(name, buffer.getvalue(), content_type='image/jpeg')


def submission(**overrides):
    data = {
        'transmission_line_id': 42,
        'line_name': '220kV Test Line',
        'tower_location': 'T-17',
        'voltage': '220kV',
        'component': 'Insulator',
        'defect': 'Crack',
        'latitude': 16.5,
        'longitude': 80.6,
        'timestamp': '2026-07-08T10:00:00Z',
        'images': [make_image()],
    }
    data.update(overrides)
    return data


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class InspectionCreateTests(TestCase):
    url = reverse('inspection-create')

    def test_creates_inspection_with_images(self):
        response = self.client.post(
            self.url, submission(images=[make_image('a.jpg'), make_image('b.jpg')])
        )
        self.assertEqual(response.status_code, 201)
        self.assertEqual(Inspection.objects.count(), 1)
        self.assertEqual(InspectionImage.objects.count(), 2)
        inspection = Inspection.objects.get()
        self.assertEqual(inspection.tower_location, 'T-17')
        self.assertEqual(
            inspection.captured_at.isoformat(), '2026-07-08T10:00:00+00:00'
        )
        payload_images = response.json()['images']
        self.assertEqual(len(payload_images), 2)
        for img in payload_images:
            self.assertTrue(img['thumbnail'], 'thumbnail missing from payload')
        for stored in InspectionImage.objects.all():
            self.assertTrue(stored.thumbnail.storage.exists(stored.thumbnail.name))

    def test_requires_component_or_defect(self):
        response = self.client.post(self.url, submission(component='', defect=''))
        self.assertEqual(response.status_code, 400)
        self.assertEqual(Inspection.objects.count(), 0)

    def test_requires_at_least_one_image(self):
        response = self.client.post(self.url, submission(images=[]))
        self.assertEqual(response.status_code, 400)
        self.assertIn('image', response.json()['detail'].lower())
        self.assertEqual(Inspection.objects.count(), 0)

    def test_rejects_too_many_images(self):
        images = [
            make_image(f'photo_{i}.jpg')
            for i in range(MAX_IMAGES_PER_INSPECTION + 1)
        ]
        response = self.client.post(self.url, submission(images=images))
        self.assertEqual(response.status_code, 400)
        self.assertEqual(Inspection.objects.count(), 0)

    def test_same_client_id_is_idempotent(self):
        first = self.client.post(self.url, submission(client_id='abc-123'))
        replay = self.client.post(self.url, submission(client_id='abc-123'))
        self.assertEqual(first.status_code, 201)
        self.assertEqual(replay.status_code, 200)
        self.assertEqual(first.json()['id'], replay.json()['id'])
        self.assertEqual(Inspection.objects.count(), 1)
        # The replay's images must not be appended to the original record.
        self.assertEqual(InspectionImage.objects.count(), 1)

    def test_distinct_client_ids_create_distinct_records(self):
        self.client.post(self.url, submission(client_id='id-1'))
        self.client.post(self.url, submission(client_id='id-2'))
        self.assertEqual(Inspection.objects.count(), 2)

    def test_missing_client_id_always_creates(self):
        self.client.post(self.url, submission())
        self.client.post(self.url, submission())
        self.assertEqual(Inspection.objects.count(), 2)

    def test_blank_client_ids_do_not_collide(self):
        first = self.client.post(self.url, submission(client_id=''))
        second = self.client.post(self.url, submission(client_id=''))
        self.assertEqual(first.status_code, 201)
        self.assertEqual(second.status_code, 201)
        self.assertEqual(Inspection.objects.count(), 2)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class InspectionStatusTests(TestCase):
    url = reverse('inspection-status')

    def test_requires_line_id(self):
        self.assertEqual(self.client.get(self.url).status_code, 400)

    def test_rejects_non_integer_line_id(self):
        response = self.client.get(self.url, {'transmission_line_id': 'abc'})
        self.assertEqual(response.status_code, 400)

    def test_reports_inspected_towers(self):
        Inspection.objects.create(
            transmission_line_id=7, tower_location='T-1', component='Peak'
        )
        Inspection.objects.create(
            transmission_line_id=7, tower_location='T-1', component='Peak'
        )
        Inspection.objects.create(
            transmission_line_id=7, tower_location='T-2', defect='Rust'
        )
        Inspection.objects.create(
            transmission_line_id=99, tower_location='T-1', defect='Rust'
        )

        response = self.client.get(self.url, {'transmission_line_id': 7})
        self.assertEqual(response.status_code, 200)
        towers = {
            t['tower_location']: t for t in response.json()['inspected_towers']
        }
        self.assertEqual(set(towers), {'T-1', 'T-2'})
        self.assertEqual(towers['T-1']['inspection_count'], 2)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class InspectionHistoryTests(TestCase):
    url = reverse('inspection-history')

    def setUp(self):
        self.older = Inspection.objects.create(
            transmission_line_id=7, tower_location='T-1', component='Peak'
        )
        self.newer = Inspection.objects.create(
            transmission_line_id=7, tower_location='T-2', defect='Rust'
        )
        InspectionImage.objects.create(inspection=self.older, image=make_image())

    def test_requires_line_id(self):
        self.assertEqual(self.client.get(self.url).status_code, 400)

    def test_rejects_non_integer_line_id(self):
        response = self.client.get(self.url, {'transmission_line_id': 'abc'})
        self.assertEqual(response.status_code, 400)

    def test_filters_by_line_newest_first(self):
        response = self.client.get(self.url, {'transmission_line_id': 7})
        self.assertEqual(response.status_code, 200)
        ids = [r['id'] for r in response.json()]
        self.assertEqual(ids, [self.newer.id, self.older.id])

    def test_filters_by_tower(self):
        response = self.client.get(
            self.url, {'transmission_line_id': 7, 'tower_location': 'T-1'}
        )
        records = response.json()
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]['id'], self.older.id)
        self.assertEqual(len(records[0]['images']), 1)


@override_settings(MEDIA_ROOT=TEMP_MEDIA)
class ThumbnailBackfillTests(TestCase):
    def test_generate_thumbnails_backfills_missing(self):
        from django.core.management import call_command

        inspection = Inspection.objects.create(
            transmission_line_id=7, tower_location='T-1', component='Peak'
        )
        legacy = InspectionImage.objects.create(
            inspection=inspection, image=make_image()
        )
        self.assertFalse(legacy.thumbnail)

        call_command('generate_thumbnails', stdout=io.StringIO())

        legacy.refresh_from_db()
        self.assertTrue(legacy.thumbnail)
        self.assertTrue(legacy.thumbnail.storage.exists(legacy.thumbnail.name))


class HealthTests(TestCase):
    def test_health_endpoint(self):
        response = self.client.get(reverse('health'))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {'status': 'ok'})
