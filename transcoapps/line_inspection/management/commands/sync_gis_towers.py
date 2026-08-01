"""Syncs towers, lines, and substations (132kV/220kV/400kV only) from ArcGIS
into our own Postgres tables (the `clear` schema, via line_inspection_db).

Uses line_inspection's own copy of the ArcGIS client
(line_inspection/services/arcgis_client.py, duplicated from gisapp's
version) — line_inspection must not depend on gisapp/gisdata at runtime.

Every ArcGIS column is captured (outFields='*') into raw_properties, in
addition to the handful of fields promoted to real columns for querying.
Rows no longer present upstream are marked is_active=False, never deleted,
so Inspections/DefectTickets already pointing at a Tower never orphan.

Tower layers run into the tens of thousands of features (e.g. ~34k for
towers-132kv alone), so writes are batched (bulk_create + update_conflicts)
and committed in short chunked transactions rather than one huge
per-row-query transaction — this is a shared production Postgres server,
and a single multi-hour transaction issuing one lookup query per row is
exactly what drops the connection under it.
"""
from django.core.management.base import BaseCommand, CommandError
from django.db import transaction, close_old_connections
from django.utils import timezone

from collections import defaultdict

from line_inspection.services.arcgis_client import (
    get_arcgis_layer_urls,
    get_property_value_case_insensitive,
    fetch_all_features,
    normalize_arcgis_date,
)
from line_inspection.models import Subdivision, Line, Tower, Substation

TOWER_LAYERS = ['towers-132kv', 'towers-220kv', 'towers-400kv']
LINE_LAYERS = ['lines-132kv', 'lines-220kv', 'lines-400kv']
SUBSTATION_LAYERS = ['substations-132kv', 'substations-220kv', 'substations-400kv']

VOLTAGE_BY_LAYER = {
    layer: layer.rsplit('-', 1)[1].replace('kv', 'kV')
    for layer in TOWER_LAYERS + LINE_LAYERS + SUBSTATION_LAYERS
}

BATCH_SIZE = 1000


def _prop(properties, *names):
    for name in names:
        value = get_property_value_case_insensitive(properties, name)
        if value not in (None, ''):
            return value
    return ''


def _point_lat_lng(feature):
    geometry = feature.get('geometry') or {}
    if geometry.get('type') == 'Point':
        coords = geometry.get('coordinates') or [None, None]
        if len(coords) >= 2:
            return coords[1], coords[0]
    return None, None


def _to_float(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _to_int(value):
    f = _to_float(value)
    return int(f) if f is not None else None


def _parse_circuit_count(tower_ckts_conductor, circuit_type):
    """Number of circuits on the structure: parse the SCT/DCT/MCT prefix and the
    1C/2C/4C token in tower_ckts_conductor (most reliable), else fall back to
    circuit_type (SC=1, DC=2, MC=4). Distinct from no_of_conductors_per_phase
    (the sub-conductor bundle size)."""
    text = (tower_ckts_conductor or '').upper()
    if 'BOOM' in text or 'GANTRY' in text:  # terminal structures, not line circuits
        return None
    if '4C' in text or 'MCT' in text:
        return 4
    if '2C' in text or 'DCT' in text:
        return 2
    if '1C' in text or 'SCT' in text:
        return 1
    ct = (circuit_type or '').upper()
    if 'MC' in ct:
        return 4
    if 'DC' in ct:
        return 2
    if 'SC' in ct:
        return 1
    return None


def _canonical_key(voltage, lat, lng):
    return f'{voltage}:{lat:.5f}:{lng:.5f}'


_CELL = 4  # rounding decimals for the spatial grid (~11 m)
_MATCH_THRESHOLD2 = 0.0003 ** 2  # ~33 m, squared (degrees)


def _assign_structure_keys(entries, voltage):
    """Group co-located real + VT rows into one physical structure.

    entries: list of {tower, lat, lng, is_virtual}. Real towers key to their own
    coordinates; a VT tower keys to the nearest REAL tower within ~33 m (verified
    linkage rule — VT rows are the same physical structure's other circuit); an
    orphan VT (no real nearby) keys to its own coordinates."""
    grid = defaultdict(list)  # (rlat, rlng) -> [(lat, lng, key)]
    for e in entries:
        if e['is_virtual'] or e['lat'] is None or e['lng'] is None:
            continue
        key = _canonical_key(voltage, e['lat'], e['lng'])
        e['tower'].structure_key = key
        grid[(round(e['lat'], _CELL), round(e['lng'], _CELL))].append((e['lat'], e['lng'], key))

    step = 10 ** -_CELL
    for e in entries:
        if not e['is_virtual']:
            continue
        lat, lng = e['lat'], e['lng']
        if lat is None or lng is None:
            e['tower'].structure_key = ''
            continue
        rlat, rlng = round(lat, _CELL), round(lng, _CELL)
        best_key, best_d2 = None, _MATCH_THRESHOLD2
        for dlat in (-1, 0, 1):
            for dlng in (-1, 0, 1):
                cell = (round(rlat + dlat * step, _CELL), round(rlng + dlng * step, _CELL))
                for clat, clng, key in grid.get(cell, []):
                    d2 = (clat - lat) ** 2 + (clng - lng) ** 2
                    if d2 <= best_d2:
                        best_d2, best_key = d2, key
        e['tower'].structure_key = best_key or _canonical_key(voltage, lat, lng)


class SubdivisionCache:
    """Avoids one SELECT/INSERT per feature for what is really only a
    handful of distinct subdivision names across tens of thousands of rows."""

    def __init__(self):
        self._by_name = {s.name: s for s in Subdivision.objects.all()}

    def get_or_create(self, properties):
        name = _prop(properties, 'subdivision', 'subdivison')
        if not name:
            return None, ''
        cached = self._by_name.get(name)
        if cached:
            return cached, name
        subdivision, _ = Subdivision.objects.get_or_create(
            name=name,
            defaults={
                'circle': _prop(properties, 'circle'),
                'division': _prop(properties, 'division'),
                'zone': _prop(properties, 'zone'),
            },
        )
        self._by_name[name] = subdivision
        return subdivision, name


def _chunked(iterable, size):
    chunk = []
    for item in iterable:
        chunk.append(item)
        if len(chunk) >= size:
            yield chunk
            chunk = []
    if chunk:
        yield chunk


class Command(BaseCommand):
    help = 'Sync 132/220/400kV towers, lines, and substations from ArcGIS into the clear schema.'

    def add_arguments(self, parser):
        parser.add_argument('--skip-towers', action='store_true')
        parser.add_argument('--skip-lines', action='store_true')
        parser.add_argument('--skip-substations', action='store_true')

    def handle(self, *args, **options):
        layer_urls = get_arcgis_layer_urls()
        now = timezone.now()

        if not options['skip_lines']:
            self._sync_lines(layer_urls, now)
        if not options['skip_towers']:
            self._sync_towers(layer_urls, now)
        if not options['skip_substations']:
            self._sync_substations(layer_urls, now)

    def _fetch(self, layer_id, layer_urls):
        if layer_id not in layer_urls:
            raise CommandError(f'Unknown ArcGIS layer id: {layer_id}')
        self.stdout.write(f'Fetching {layer_id} ...', ending='\n')
        self.stdout.flush()
        features, _service_info = fetch_all_features(layer_id, layer_urls[layer_id], extra_params={'outFields': '*'})
        self.stdout.write(f'  {len(features)} features')
        self.stdout.flush()
        return features

    def _write_batch(self, model, batch, unique_fields, update_fields, label):
        """Upsert one chunk in its own short transaction. On failure, drop the
        stale connection so Django reconnects cleanly on the next chunk
        instead of the whole run dying from one bad batch."""
        try:
            with transaction.atomic(using='line_inspection_db'):
                model.objects.using('line_inspection_db').bulk_create(
                    batch, update_conflicts=True, unique_fields=unique_fields, update_fields=update_fields,
                )
            return True
        except Exception as exc:
            close_old_connections()
            self.stderr.write(f'  batch of {len(batch)} {label} failed and was skipped: {exc}')
            return False

    def _sync_lines(self, layer_urls, now):
        subdivisions = SubdivisionCache()
        seen_ids = {layer: set() for layer in LINE_LAYERS}
        update_fields = [
            'name', 'voltage', 'line_length', 'circuit_type', 'date_of_commissioning',
            'zone', 'circle', 'division', 'subdivision_name', 'subdivision',
            'geometry', 'raw_properties', 'is_active', 'last_synced_at',
        ]

        for layer_id in LINE_LAYERS:
            rows = []
            for feature in self._fetch(layer_id, layer_urls):
                properties = feature.get('properties') or {}
                object_id = str(_prop(properties, 'OBJECTID', 'objectid'))
                if not object_id:
                    continue
                seen_ids[layer_id].add(object_id)
                subdivision, subdivision_name = subdivisions.get_or_create(properties)

                rows.append(Line(
                    source_layer=layer_id, arcgis_object_id=object_id,
                    name=_prop(properties, 'line_name'),
                    voltage=VOLTAGE_BY_LAYER[layer_id],
                    line_length=str(_prop(properties, 'line_length')),
                    circuit_type=str(_prop(properties, 'circuit_type')),
                    date_of_commissioning=str(_prop(properties, 'date_of_commissioning')),
                    zone=_prop(properties, 'zone'), circle=_prop(properties, 'circle'), division=_prop(properties, 'division'),
                    subdivision_name=subdivision_name, subdivision=subdivision,
                    geometry=feature.get('geometry'), raw_properties=properties, is_active=True,
                ))

            for chunk in _chunked(rows, BATCH_SIZE):
                self._write_batch(Line, chunk, ['source_layer', 'arcgis_object_id'], update_fields, 'lines')

        for layer_id in LINE_LAYERS:
            stale = Line.objects.filter(source_layer=layer_id, is_active=True).exclude(arcgis_object_id__in=seen_ids[layer_id])
            count = stale.update(is_active=False, last_synced_at=now)
            if count:
                self.stdout.write(f'  deactivated {count} lines no longer present in {layer_id}')

    def _sync_towers(self, layer_urls, now):
        subdivisions = SubdivisionCache()
        line_lookup = {(l.name, l.voltage): l for l in Line.objects.all()}
        seen_ids = {layer: set() for layer in TOWER_LAYERS}
        # NOTE: insulator_type / type_of_earthing are deliberately NOT in update_fields —
        # they are manually maintained (empty/absent in ArcGIS) and must survive re-syncs.
        update_fields = [
            'tower_number', 'tower_type', 'voltage', 'line_name', 'line', 'latitude', 'longitude',
            'cp_sp', 'tower_ckts_conductor', 'circuit_type', 'circuit_count', 'conductor_type',
            'no_of_conductors_per_phase', 'relay_setting_length_in_km', 'span_km', 'date_of_commissioning',
            'is_virtual', 'structure_key',
            'zone', 'circle', 'division', 'subdivision_name', 'subdivision',
            'geometry', 'raw_properties', 'is_active', 'last_synced_at',
        ]

        for layer_id in TOWER_LAYERS:
            voltage = VOLTAGE_BY_LAYER[layer_id]
            entries = []
            for feature in self._fetch(layer_id, layer_urls):
                properties = feature.get('properties') or {}
                object_id = str(_prop(properties, 'OBJECTID', 'objectid'))
                if not object_id:
                    continue
                seen_ids[layer_id].add(object_id)
                subdivision, subdivision_name = subdivisions.get_or_create(properties)

                lat, lng = _point_lat_lng(feature)
                if lat is None:
                    lat = _prop(properties, 'latitude')
                    lng = _prop(properties, 'longitude')
                lat, lng = _to_float(lat), _to_float(lng)

                line_name = _prop(properties, 'line_name')
                line = line_lookup.get((line_name, voltage)) if line_name else None

                tower_number = str(_prop(properties, 'tower_number')).strip()
                tcc = str(_prop(properties, 'tower_ckts_conductor'))
                circuit_type = str(_prop(properties, 'circuit_type'))

                tower = Tower(
                    source_layer=layer_id, arcgis_object_id=object_id,
                    tower_number=tower_number,
                    tower_type=str(_prop(properties, 'tower_type')),
                    voltage=voltage, line_name=line_name, line=line,
                    cp_sp=str(_prop(properties, 'cp_sp')),
                    tower_ckts_conductor=tcc,
                    circuit_type=circuit_type,
                    circuit_count=_parse_circuit_count(tcc, circuit_type),
                    conductor_type=str(_prop(properties, 'conductor_type')),
                    no_of_conductors_per_phase=_to_int(_prop(properties, 'no_of_conductors_per_phase')),
                    relay_setting_length_in_km=str(_prop(properties, 'relay_setting_length_in_km')),
                    span_km=_to_float(_prop(properties, 'span_km')),
                    date_of_commissioning=str(normalize_arcgis_date(_prop(properties, 'date_of_commissioning')) or ''),
                    is_virtual=tower_number.upper().startswith('VT'),
                    latitude=lat, longitude=lng,
                    zone=_prop(properties, 'zone'), circle=_prop(properties, 'circle'), division=_prop(properties, 'division'),
                    subdivision_name=subdivision_name, subdivision=subdivision,
                    geometry=feature.get('geometry'), raw_properties=properties, is_active=True,
                )
                entries.append({'tower': tower, 'lat': lat, 'lng': lng, 'is_virtual': tower.is_virtual})

            # Link co-located real + VT rows into physical structures before writing.
            _assign_structure_keys(entries, voltage)
            rows = [e['tower'] for e in entries]

            written = 0
            for chunk in _chunked(rows, BATCH_SIZE):
                if self._write_batch(Tower, chunk, ['source_layer', 'arcgis_object_id'], update_fields, 'towers'):
                    written += len(chunk)
            self.stdout.write(f'  wrote {written}/{len(rows)} {layer_id} towers')

        for layer_id in TOWER_LAYERS:
            stale = Tower.objects.filter(source_layer=layer_id, is_active=True).exclude(arcgis_object_id__in=seen_ids[layer_id])
            count = stale.update(is_active=False, last_synced_at=now)
            if count:
                self.stdout.write(f'  deactivated {count} towers no longer present in {layer_id}')

    def _sync_substations(self, layer_urls, now):
        subdivisions = SubdivisionCache()
        seen_ids = {layer: set() for layer in SUBSTATION_LAYERS}
        update_fields = [
            'name', 'voltage', 'latitude', 'longitude',
            'zone', 'circle', 'division', 'subdivision_name', 'subdivision',
            'geometry', 'raw_properties', 'is_active', 'last_synced_at',
        ]

        for layer_id in SUBSTATION_LAYERS:
            rows = []
            for feature in self._fetch(layer_id, layer_urls):
                properties = feature.get('properties') or {}
                object_id = str(_prop(properties, 'OBJECTID', 'objectid'))
                if not object_id:
                    continue
                seen_ids[layer_id].add(object_id)
                subdivision, subdivision_name = subdivisions.get_or_create(properties)

                lat, lng = _point_lat_lng(feature)
                if lat is None:
                    lat = _prop(properties, 'lat') or None
                    lng = _prop(properties, 'long_') or None

                rows.append(Substation(
                    source_layer=layer_id, arcgis_object_id=object_id,
                    name=_prop(properties, 'ss_name'), voltage=VOLTAGE_BY_LAYER[layer_id],
                    latitude=lat, longitude=lng,
                    zone=_prop(properties, 'zone'), circle=_prop(properties, 'circle'), division=_prop(properties, 'division'),
                    subdivision_name=subdivision_name, subdivision=subdivision,
                    geometry=feature.get('geometry'), raw_properties=properties, is_active=True,
                ))

            for chunk in _chunked(rows, BATCH_SIZE):
                self._write_batch(Substation, chunk, ['source_layer', 'arcgis_object_id'], update_fields, 'substations')

        for layer_id in SUBSTATION_LAYERS:
            stale = Substation.objects.filter(source_layer=layer_id, is_active=True).exclude(arcgis_object_id__in=seen_ids[layer_id])
            count = stale.update(is_active=False, last_synced_at=now)
            if count:
                self.stdout.write(f'  deactivated {count} substations no longer present in {layer_id}')
