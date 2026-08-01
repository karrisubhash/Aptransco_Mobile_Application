"""ArcGIS token/query client — a standalone copy of gisapp/arcgis_client.py.

Deliberately duplicated rather than imported: line_inspection must not
depend on any other app in this Django project at runtime (some
deployments won't have gisapp installed at all). Pull fixes from
gisapp/arcgis_client.py over by hand if that copy changes.
"""
import json
import time
import requests
import os as _os

ARCGIS_BASE_URL = "https://gis.aptransco.gov.in"
ARCGIS_TOKEN_URL = f"{ARCGIS_BASE_URL}/portal/sharing/rest/generateToken"
ARCGIS_CREDENTIALS = {
    "username": _os.environ.get("ARCGIS_USERNAME", ""),
    "password": _os.environ.get("ARCGIS_PASSWORD", ""),
}
_ARCGIS_TOKEN_CACHE = {
    "token": None,
    "expiry": 0,
}


def get_arcgis_token():
    if not ARCGIS_CREDENTIALS["username"] or not ARCGIS_CREDENTIALS["password"]:
        raise Exception("ArcGIS credentials are not configured.")

    now = time.time()
    token = _ARCGIS_TOKEN_CACHE.get("token")
    expiry = _ARCGIS_TOKEN_CACHE.get("expiry", 0)
    if token and now < expiry:
        return token

    payload = {
        "f": "json",
        "username": ARCGIS_CREDENTIALS["username"],
        "password": ARCGIS_CREDENTIALS["password"],
        "client": "referer",
        "referer": ARCGIS_BASE_URL,
        "expiration": 120,
    }
    response = requests.post(ARCGIS_TOKEN_URL, data=payload, timeout=30)
    response.raise_for_status()
    data = response.json()
    if "token" not in data:
        raise Exception(f"ArcGIS token error: {json.dumps(data)}")

    token = data["token"]
    expires = int(data.get("expiration", 60))
    _ARCGIS_TOKEN_CACHE["token"] = token
    _ARCGIS_TOKEN_CACHE["expiry"] = now + expires - 10
    return token


def arcgis_request(method, url, params=None, data=None, timeout=30, retries=1):
    params = params.copy() if params else {}
    data = data.copy() if data else {}

    if url.startswith(ARCGIS_BASE_URL):
        token = get_arcgis_token()
        if method.upper() == "GET":
            params["token"] = token
        else:
            data["token"] = token

    response = requests.request(method, url, params=params, data=data, timeout=timeout)
    try:
        payload = response.json()
        if isinstance(payload, dict) and payload.get("error", {}).get("code") in (498, 499) and retries > 0:
            _ARCGIS_TOKEN_CACHE["token"] = None
            _ARCGIS_TOKEN_CACHE["expiry"] = 0
            return arcgis_request(method, url, params=params, data=data, timeout=timeout, retries=retries - 1)
    except ValueError:
        pass

    return response


def parse_arcgis_json(response):
    """Parse an ArcGIS response, raising if the body carries an ArcGIS error object.

    ArcGIS reports query failures (bad field, bad geometry, etc.) as HTTP 200 with
    an {'error': {...}} body, so raise_for_status() alone silently turns them into
    empty results.
    """
    data = response.json()
    if isinstance(data, dict) and 'error' in data:
        err = data['error'] or {}
        message = err.get('message') or 'ArcGIS query failed.'
        details = '; '.join(str(d) for d in (err.get('details') or []) if d)
        suffix = f' ({details})' if details else ''
        raise requests.RequestException(f"ArcGIS error {err.get('code')}: {message}{suffix}")
    return data


def get_arcgis_layer_urls():
    return {
        'districts-new': 'https://gis.aptransco.gov.in/server/rest/services/Hosted/Districts_Updated/FeatureServer/0',
        'districts-old': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/16',
        'mandals': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/15',
        'villages': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/14',
        'substations-400kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/13',
        'substations-220kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/13',
        'substations-132kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/13',
        'lines-132kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/10',
        'lines-220kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/9',
        'lines-400kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/8',
        'towers-132kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/2',
        'towers-220kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/1',
        'towers-400kv': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/0',
        'powergrid-ss': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/5',
        'powergrid-lines': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/6',
        'bulkloads': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/7',
        'railway-ss': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/11',
        'generation-ss': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Gridmap_test_06102023/FeatureServer/12',
        'uc-line-works': 'https://gis.aptransco.gov.in/server/rest/services/UC_Projects/projects_progress_28072025/FeatureServer/3',
        'uc-bay-works': 'https://gis.aptransco.gov.in/server/rest/services/UC_Projects/projects_progress_28072025/FeatureServer/4',
        'uc-ss-works': 'https://gis.aptransco.gov.in/server/rest/services/UC_Projects/projects_progress_28072025/FeatureServer/5',
        'uc-towers': 'https://gis.aptransco.gov.in/server/rest/services/UC_Projects/projects_progress_28072025/FeatureServer/1',
        'prop-line-works': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Technical_Feasibility/FeatureServer/1',
        'under-tender-ss': 'https://gis.aptransco.gov.in/server/rest/services/UC_Projects/proposed_new_SS/FeatureServer/0',
        'prop-ss-works': 'https://gis.aptransco.gov.in/server/rest/services/AP_Grid_Map/Technical_Feasibility/FeatureServer/0',
    }


def get_arcgis_layer_fields(layer_id):
    """Return a comma-separated list of ArcGIS fields to request for each layer."""
    field_mapping = {
        # APTransco substations
        'substations-400kv': 'ss_name,voltage,zone,circle,division,subdivison',
        'substations-220kv': 'ss_name,voltage,zone,circle,division,subdivison',
        'substations-132kv': 'ss_name,voltage,zone,circle,division,subdivison',

        # Transmission lines
        'lines-132kv': 'line_name,line_length,circuit_type,date_of_commissioning,zone,circle,division,subdivison',
        'lines-220kv': 'line_name,line_length,circuit_type,date_of_commissioning,zone,circle,division,subdivision',
        'lines-400kv': 'line_name,line_length,circuit_type,date_of_commissioning,zone,circle,division,subdivision',

        # Towers — 'location_number' was removed from the upstream schema; requesting
        # it makes ArcGIS reject the whole query with a generic 400. Only fields present
        # on ALL THREE tower layers are listed here: insulator_type/type_of_earthing exist
        # only on towers-132kv (and are empty), and span/span_km aren't reliable across
        # layers, so requesting them would 400 the 220/400kV queries. The sync fetches with
        # outFields='*' anyway, so raw_properties still captures every field per layer.
        'towers-132kv': 'tower_number,cp_sp,line_name,voltage,tower_type,tower_ckts_conductor,circuit_type,conductor_type,no_of_conductors_per_phase,relay_setting_length_in_km,date_of_commissioning,latitude,longitude,zone,circle,division,subdivision',
        'towers-220kv': 'tower_number,cp_sp,line_name,voltage,tower_type,tower_ckts_conductor,circuit_type,conductor_type,no_of_conductors_per_phase,relay_setting_length_in_km,date_of_commissioning,latitude,longitude,zone,circle,division,subdivision',
        'towers-400kv': 'tower_number,cp_sp,line_name,voltage,tower_type,tower_ckts_conductor,circuit_type,conductor_type,no_of_conductors_per_phase,relay_setting_length_in_km,date_of_commissioning,latitude,longitude,zone,circle,division,subdivision',

        # Powergrid and other SS
        'powergrid-ss': 'name_of_ss,voltage,lat,long_',
        'bulkloads': 'name_of_the_ss,ss_type,lattitude,longitude',
        'railway-ss': 'name_of_the_ss,lattitude,longitude',
        'generation-ss': 'name_of_the_ss,ss_type,lattitude,longitude',

        # Powergrid lines — voltagelevel drives the uniqueValue renderer; actual name field is name_of_the_765kv_pgcil_substat
        'powergrid-lines': 'name_of_the_765kv_pgcil_substat,voltagelevel,serviceoruc',

        # Under construction works
        'uc-line-works': 'project_name,name_of_the_work,voltage,line_length,conductor_name,supply_status,work_status,profile_handover_date,scheduled_completion_date,rescheduled_completion_date,name_of_contactor,zone,circle,division,district',
        'uc-bay-works': 'project_name,name_of_the_work,voltage,purpose_of_bay_work,supply_status,work_status,site_handover_date,scheduled_completion_date,rescheduled_completion_date,name_of_contactor,zone,circle,division,district',
        'uc-ss-works': 'project_name,name_of_the_work,voltage,supply_status,work_status,site_handover_date,scheduled_completion_date,rescheduled_completion_date,name_of_contactor,zone,circle,division,district',
        'uc-towers': 'project_name,name_of_the_work,voltage,line_length,foundation_status,row_status,erection_status,latitude,longitude,name_of_contractor,zone,circle,division,district',

        # Proposed works
        'under-tender-ss': 'proposed_ss_name,voltage,planned_phase,proposed_connectivity,district,latitude,longitude,land_status,estimate_status',
        'prop-ss-works': 'name_of_work,scheme_name,nature_of_scheme,work_status,commissioned_status,district,technical_feasibility_issue_dat,date_of_commissioning',
        'prop-line-works': 'name_of_work,scheme_name,nature_of_scheme,work_status,commissioned_status,district,technical_feasibility_issue_dat,date_of_commissioning',
    }
    return field_mapping.get(layer_id, '*')


def normalize_arcgis_date(value):
    """Convert ArcGIS date values to YYYY-MM-DD strings for the frontend."""
    from datetime import datetime, timezone

    if value in (None, ''):
        return value

    try:
        timestamp = float(value)
        if timestamp > 100000000000:
            timestamp = timestamp / 1000
        return datetime.fromtimestamp(timestamp, tz=timezone.utc).date().isoformat()
    except (TypeError, ValueError, OSError, OverflowError):
        return value


def normalize_feature_dates(features):
    for feature in features:
        properties = feature.get('properties') or {}
        for key in list(properties.keys()):
            if key.lower() == 'date_of_commissioning':
                properties[key] = normalize_arcgis_date(properties[key])
    return features


def normalize_domain_code(value):
    if value is None:
        return ''
    if isinstance(value, bool):
        return str(value).lower()
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if float(value).is_integer():
            return str(int(value))
    text = str(value).strip()
    try:
        number = float(text)
        if number.is_integer():
            return str(int(number))
    except ValueError:
        pass
    return text.lower()


def get_domain_lookup(domain):
    if not isinstance(domain, dict) or domain.get('type') != 'codedValue':
        return {}

    lookup = {}
    for coded_value in domain.get('codedValues', []) or []:
        code = coded_value.get('code')
        name = coded_value.get('name')
        if name not in (None, ''):
            lookup[normalize_domain_code(code)] = name
    return lookup


def build_domain_maps(service_info):
    field_domain_maps = {}
    field_names = {}

    for field in service_info.get('fields', []) or []:
        name = field.get('name')
        if not name:
            continue
        normalized_name = name.lower()
        field_names[normalized_name] = name

        lookup = get_domain_lookup(field.get('domain'))
        if lookup:
            field_domain_maps[normalized_name] = lookup

    type_id_field = (service_info.get('typeIdField') or '').lower()
    subtype_domain_maps = {}
    for layer_type in service_info.get('types', []) or []:
        type_code = normalize_domain_code(layer_type.get('id'))
        for field_name, domain in (layer_type.get('domains') or {}).items():
            lookup = get_domain_lookup(domain)
            if lookup:
                subtype_domain_maps[(type_code, field_name.lower())] = lookup

    return field_domain_maps, subtype_domain_maps, type_id_field, field_names


def get_property_value_case_insensitive(properties, field_name):
    if not field_name:
        return None
    if field_name in properties:
        return properties[field_name]
    lower_name = field_name.lower()
    matching_key = next((key for key in properties if key.lower() == lower_name), None)
    return properties.get(matching_key) if matching_key else None


def apply_domain_descriptions(features, service_info):
    field_domain_maps, subtype_domain_maps, type_id_field, _ = build_domain_maps(service_info)
    if not field_domain_maps and not subtype_domain_maps:
        return features

    for feature in features:
        properties = feature.get('properties') or {}
        type_code = normalize_domain_code(get_property_value_case_insensitive(properties, type_id_field))

        for property_name, value in list(properties.items()):
            if value in (None, ''):
                continue

            normalized_property_name = property_name.lower()
            lookup = (
                subtype_domain_maps.get((type_code, normalized_property_name))
                or field_domain_maps.get(normalized_property_name)
            )
            if not lookup:
                continue

            description = lookup.get(normalize_domain_code(value))
            if description not in (None, ''):
                properties[property_name] = description

    return features


TOWER_LAYER_IDS = {'towers-132kv', 'towers-220kv', 'towers-400kv'}


def get_layer_where_clause(layer_id):
    """Return ArcGIS WHERE clause for a layer.

    Tower layers now include VT (virtual) towers: a VT row is the second/other
    circuit of a multi-circuit line sharing the same physical structure as a
    real tower (co-located). Field crews need to know every circuit strung on a
    structure, so we no longer drop `tower_number LIKE 'VT%'`. VT rows are stored
    with is_virtual=True and grouped to their real tower by coordinate proximity
    (see sync_gis_towers); only real towers are ever inspected.
    """
    return '1=1'


def get_substation_voltage_filter(layer_id):
    # The ArcGIS service stores 220KV substations with voltage code "200"
    return {
        'substations-400kv': '400',
        'substations-220kv': '200',
        'substations-132kv': '132',
    }.get(layer_id)


def filter_substation_features_by_voltage(features, layer_id):
    voltage_filter = get_substation_voltage_filter(layer_id)
    if not voltage_filter:
        return features

    return [
        feature for feature in features
        if voltage_filter in str((feature.get('properties') or {}).get('voltage', '')).upper().replace(' ', '')
    ]


def fetch_all_features(layer_id, layer_url, extra_params=None, timeout=120):
    """Paginate a FeatureServer layer's /query endpoint and return every feature.

    ArcGIS enforces maxRecordCount per query — a single request silently
    truncates at that limit (this is the bug that capped gisdata's gismain()
    view at ~2000 rows). Always paginate via resultOffset/resultRecordCount.
    """
    service_info_response = arcgis_request('GET', layer_url, params={'f': 'json'}, timeout=30)
    service_info_response.raise_for_status()
    service_info = parse_arcgis_json(service_info_response)
    max_record_count = service_info.get('maxRecordCount', 1000)

    out_fields = get_arcgis_layer_fields(layer_id)
    where_clause = get_layer_where_clause(layer_id)

    all_features = []
    result_offset = 0
    page_size = min(max_record_count, 2000)

    while True:
        params = {
            'f': 'geojson',
            'outFields': out_fields,
            'where': where_clause,
            'resultOffset': result_offset,
            'resultRecordCount': page_size,
        }
        if extra_params:
            params.update(extra_params)

        response = arcgis_request('GET', layer_url + '/query', params=params, timeout=timeout)
        response.raise_for_status()

        data = parse_arcgis_json(response)
        features = data.get('features', [])
        if not features:
            break

        all_features.extend(features)
        result_offset += len(features)
        if len(features) < page_size:
            break

    all_features = filter_substation_features_by_voltage(all_features, layer_id)
    apply_domain_descriptions(all_features, service_info)
    normalize_feature_dates(all_features)
    return all_features, service_info
