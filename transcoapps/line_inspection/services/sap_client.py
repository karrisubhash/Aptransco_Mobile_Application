"""Client for APTRANSCO's live SAP employee-cadre-details RFC service.

A fresh, line_inspection-local implementation — deliberately not imported
from contacts/models.py (that app's helpers are for the org-chart feature,
not shared infrastructure). Credentials/config come from environment
variables only; nothing is hardcoded.
"""
import os
import requests
from requests.auth import HTTPBasicAuth

SAP_RFC_BASE_URL = os.environ.get(
    'SAP_RFC_BASE_URL', 'https://poprdapp.hec.aptransco.gov.in:50001/RESTAdapter'
)
SAP_RFC_USER = os.environ.get('SAP_RFC_USER', '')
SAP_RFC_PASSWORD = os.environ.get('SAP_RFC_PASSWORD', '')

# The employee at the top of the hierarchy to fetch cadre details for the
# whole organisation in one call (ZHR_GET_EMP_CADER_DETAILS returns the
# requested employee's full subtree). Must be set explicitly — there is no
# safe default to guess here.
SAP_HIERARCHY_ROOT_EMPLOYEE_ID = os.environ.get('SAP_HIERARCHY_ROOT_EMPLOYEE_ID', '')

CADER_DETAILS_ENDPOINT = f'{SAP_RFC_BASE_URL}/ZHR_GET_EMP_CADER_DETAILS'
EMP_INFO_POS_ID_ENDPOINT = f'{SAP_RFC_BASE_URL}/EMP_INFO_POS_ID'


class SapClientError(Exception):
    pass


def _require_credentials():
    if not SAP_RFC_USER or not SAP_RFC_PASSWORD:
        raise SapClientError(
            'SAP_RFC_USER / SAP_RFC_PASSWORD are not configured (set them as environment variables).'
        )


def get_employee_cadre_details(root_employee_id=None, timeout=60):
    """Fetch cadre/position details for an employee and everyone under them
    in the reporting hierarchy. Returns a list of raw SAP employee dicts
    (EMP_ID, EMP_NAME, EMP_SUB_GROUP, EMP_POS_TEXT, ... — the same shape SAP
    returns for the org-chart feature)."""
    _require_credentials()

    employee_id = root_employee_id or SAP_HIERARCHY_ROOT_EMPLOYEE_ID
    if not employee_id:
        raise SapClientError(
            'No root employee id given and SAP_HIERARCHY_ROOT_EMPLOYEE_ID is not configured.'
        )

    response = requests.post(
        CADER_DETAILS_ENDPOINT,
        auth=HTTPBasicAuth(SAP_RFC_USER, SAP_RFC_PASSWORD),
        json={'EMPLOYEE_ID': employee_id},
        timeout=timeout,
    )
    response.raise_for_status()
    result = response.json()

    if isinstance(result, dict) and 'error' in result:
        raise SapClientError(f"SAP cadre-details service error: {result['error']}")

    try:
        items = result['LT_OUT'][0]['item']
    except (KeyError, IndexError, TypeError) as exc:
        raise SapClientError(f'Unexpected SAP cadre-details response shape: {result}') from exc

    if isinstance(items, dict):
        items = [items]
    return items


def get_employee_by_position_id(position_id, timeout=30):
    """Looks up the current holder and position text for a single SAP
    position id. posid/postext are interlinked in SAP — this is the
    canonical way to resolve position_text for the "Add by position id"
    fallback on the Manage Admins screen, instead of an Admin typing it by
    hand. Returns {position_id, position_text, employee_id, employee_name};
    raises SapClientError if the position id has no current data."""
    _require_credentials()

    position_id = str(position_id or '').strip()
    if not position_id:
        raise SapClientError('A position id is required.')

    response = requests.post(
        EMP_INFO_POS_ID_ENDPOINT,
        auth=HTTPBasicAuth(SAP_RFC_USER, SAP_RFC_PASSWORD),
        json={'IV_PLANS': [{'PLANS': position_id}]},
        timeout=timeout,
    )
    response.raise_for_status()
    result = response.json()

    try:
        payload = result['MT_EMP_INFO_POID_RES']
        rows = payload.get('ES_EMPINFO_POS_ID') or []
    except (KeyError, TypeError) as exc:
        raise SapClientError(f'Unexpected EMP_INFO_POS_ID response shape: {result}') from exc

    # ES_MSG isn't a reliable vacancy signal on its own (observed "POSITION IS
    # VACANCT FOR" even alongside a populated row) — rows present is ground truth.
    if not rows:
        message = str(payload.get('ES_MSG') or '').strip() or 'No data returned for this position id.'
        raise SapClientError(message)

    row = rows[0]
    position_text = row.get('CURPOSITIONT') or ''
    if not position_text:
        raise SapClientError(f'SAP returned no position text for position id {position_id}.')

    return {
        'position_id': str(row.get('CURPOSITION') or position_id),
        'position_text': position_text,
        'employee_id': str(row.get('PERNR') or ''),
        'employee_name': row.get('EMPNAME') or '',
    }
