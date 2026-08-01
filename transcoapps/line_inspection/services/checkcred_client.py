"""Client for APTRANSCO's legacy employee-credential service (checkCred /
forgotPass / savePass) — the active login mechanism while Keycloak
integration is deferred to a later phase.

A fresh, line_inspection-local implementation (same service gisapp/views.py's
login_proxy already calls, same body/auth shape) — not imported from gisapp,
per the no-cross-app-dependency rule. Credentials for the service itself
(HTTP Basic Auth) come from environment variables only; nothing is
hardcoded.
"""
import os
import requests

CHECKCRED_BASE_URL = os.environ.get('APTRANSCO_AUTH_URL', 'https://qaserv.aptransco.co.in/qath').rstrip('/')
CHECKCRED_URL = f'{CHECKCRED_BASE_URL}/checkCred'
FORGOT_PASSWORD_URL = f'{CHECKCRED_BASE_URL}/forgotPass'
SAVE_PASSWORD_URL = f'{CHECKCRED_BASE_URL}/savePass'

CHECKCRED_USER = os.environ.get('APTRANSCO_AUTH_USER', '')
CHECKCRED_PASS = os.environ.get('APTRANSCO_AUTH_PASS', '')


class CheckCredError(Exception):
    pass


def _require_credentials():
    if not CHECKCRED_USER or not CHECKCRED_PASS:
        raise CheckCredError('APTRANSCO_AUTH_USER / APTRANSCO_AUTH_PASS are not configured.')


def _post(url, payload, timeout=20):
    _require_credentials()
    try:
        response = requests.post(
            url, json=payload, auth=(CHECKCRED_USER, CHECKCRED_PASS), timeout=timeout,
        )
        return response.json()
    except requests.RequestException as exc:
        raise CheckCredError(f'Auth service unreachable: {exc}') from exc
    except ValueError as exc:
        raise CheckCredError('Auth service returned an invalid response.') from exc


def verify_credentials(user_id, passwd):
    """Returns {employee_id, display_name, empdata} on success, or raises
    CheckCredError with a message safe to show the user."""
    # Local-development escape hatch. Inert unless DEBUG *and* both
    # LINE_INSPECTION_DEV_LOGIN / LINE_INSPECTION_DEV_PASSWORD are set --
    # see services/dev_login.py. Delete these four lines to remove it.
    from . import dev_login
    if dev_login.is_enabled():
        return dev_login.verify(user_id, passwd)

    user_id = str(user_id or '').strip()
    passwd = str(passwd or '')
    if not user_id or not passwd:
        raise CheckCredError('Employee ID and password are required.')

    result = _post(CHECKCRED_URL, {'user_id': user_id, 'passwd': passwd})

    message = str(result.get('message', '')).lower()
    empdata = result.get('empdata')
    is_valid = ('valid' in message and 'invalid' not in message) and isinstance(empdata, dict)
    if not is_valid:
        raise CheckCredError(result.get('message') or 'Invalid credentials.')

    display_name = empdata.get('CNAME') or empdata.get('NAME1') or ''
    # SAP employee ids are zero-padded to 8 digits everywhere else in this app
    # (EmployeeCadreSnapshot/SuperAdmin/RoleAssignment) — checkCred's response
    # (or whatever the user typed) may drop a leading zero, e.g. "1073093"
    # instead of "01073093", which would silently fail every downstream
    # employee_id lookup. Normalize here, once, at the point identity enters
    # the session.
    employee_id = str(result.get('user_id') or user_id).strip()
    if employee_id.isdigit():
        employee_id = employee_id.zfill(8)
    return {
        'employee_id': employee_id,
        'display_name': display_name,
        'empdata': empdata,
    }


def forgot_password(user_id):
    user_id = str(user_id or '').strip()
    if not user_id:
        raise CheckCredError('Employee ID is required.')
    return _post(FORGOT_PASSWORD_URL, {'user_id': user_id})


def save_password(user_id, passwd, oldpass):
    user_id = str(user_id or '').strip()
    if not user_id or not passwd or not oldpass:
        raise CheckCredError('Employee ID, new password, and old password are required.')
    return _post(SAVE_PASSWORD_URL, {'user_id': user_id, 'passwd': passwd, 'oldpass': oldpass})
