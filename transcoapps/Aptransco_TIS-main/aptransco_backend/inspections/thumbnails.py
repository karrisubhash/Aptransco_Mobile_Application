import io
import logging
import os

from django.core.files.base import ContentFile
from PIL import Image, ImageOps

logger = logging.getLogger('inspections')

THUMBNAIL_MAX_DIM = 400
THUMBNAIL_QUALITY = 80


def build_thumbnail(image_file, name_hint='photo'):
    """Returns a small JPEG ContentFile for [image_file], or None when the
    source can't be processed — a missing thumbnail must never block the
    upload itself (clients fall back to the full image).
    """
    try:
        image_file.seek(0)
        img = Image.open(image_file)
        # Bake the EXIF rotation in: the thumbnail is re-encoded, which
        # would otherwise strip the orientation tag and flip the preview.
        img = ImageOps.exif_transpose(img)
        img.thumbnail((THUMBNAIL_MAX_DIM, THUMBNAIL_MAX_DIM), Image.LANCZOS)
        if img.mode not in ('RGB', 'L'):
            img = img.convert('RGB')

        buffer = io.BytesIO()
        img.save(buffer, format='JPEG', quality=THUMBNAIL_QUALITY, optimize=True)

        base = os.path.splitext(os.path.basename(name_hint))[0] or 'photo'
        return ContentFile(buffer.getvalue(), name=f'{base}_thumb.jpg')
    except Exception:
        logger.warning('Thumbnail generation failed for %s', name_hint, exc_info=True)
        return None
    finally:
        try:
            image_file.seek(0)
        except (OSError, ValueError):
            pass
