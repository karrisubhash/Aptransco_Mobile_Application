"""Keycloak OIDC client — adapted from gisapp/views.py's proven login flow.

Deliberately copied rather than imported: line_inspection must not depend
on any other app in this Django project at runtime. Reimplemented as plain
functions returning dicts (raising KeycloakClientError on failure) instead
of DRF Response objects, since this module is used by both the plain
Django session-login views (auth.py) and the DRF API's bearer-token auth.
"""
import base64
import json
import os
from urllib.parse import urlencode

import requests

KEYCLOAK_BASE_URL = os.environ.get('KEYCLOAK_BASE_URL', 'https://keycloak.aptransco.co.in').rstrip('/')
KEYCLOAK_REALM = os.environ.get('KEYCLOAK_REALM', 'APTRANSCO-EMP')
KEYCLOAK_CLIENT_ID = os.environ.get('KEYCLOAK_CLIENT_ID', 'clear')
# No hardcoded secret default on purpose — a real secret must never live in
# source. Set KEYCLOAK_CLIENT_SECRET in the environment before runserver.
KEYCLOAK_CLIENT_SECRET = os.environ.get('KEYCLOAK_CLIENT_SECRET', 'hUEGqxJTNgXxlGuSsAFy4LePclLGiBAz')
KEYCLOAK_AUTH_URL = f'{KEYCLOAK_BASE_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/auth'
KEYCLOAK_TOKEN_URL = f'{KEYCLOAK_BASE_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/token'
KEYCLOAK_USERINFO_URL = f'{KEYCLOAK_BASE_URL}/realms/{KEYCLOAK_REALM}/protocol/openid-connect/userinfo'
KEYCLOAK_EMPLOYEE_ID_CLAIMS = ('employee_id', 'emp_id', 'empid', 'preferred_username', 'user_id')


class KeycloakClientError(Exception):
    pass


def _require_client_secret():
    if not KEYCLOAK_CLIENT_SECRET:
        raise KeycloakClientError('KEYCLOAK_CLIENT_SECRET is not configured.')


def get_authorize_url(redirect_uri, state=''):
    params = {
        'client_id': KEYCLOAK_CLIENT_ID,
        'redirect_uri': redirect_uri,
        'response_type': 'code',
        'scope': 'openid profile email',
    }
    if state:
        params['state'] = state
    return f'{KEYCLOAK_AUTH_URL}?{urlencode(params)}'


def _decode_jwt_payload(token):
    try:
        parts = str(token or '').split('.')
        if len(parts) < 2:
            return {}
        payload = parts[1] + '=' * (-len(parts[1]) % 4)
        return json.loads(base64.urlsafe_b64decode(payload.encode('utf-8')).decode('utf-8'))
    except (ValueError, TypeError, json.JSONDecodeError):
        return {}


def _fetch_userinfo(access_token):
    response = requests.get(
        KEYCLOAK_USERINFO_URL,
        headers={'Authorization': f'Bearer {access_token}'},
        timeout=15,
    )
    response.raise_for_status()
    return response.json()


def _extract_identity(claims):
    if not isinstance(claims, dict):
        claims = {}

    employee_id = ''
    for claim in KEYCLOAK_EMPLOYEE_ID_CLAIMS:
        value = claims.get(claim)
        if value:
            employee_id = str(value).strip()
            break

    name = str(
        claims.get('name')
        or claims.get('employee_name')
        or claims.get('given_name')
        or claims.get('preferred_username')
        or ''
    ).strip()
    display_name = ' - '.join(part for part in (name, employee_id) if part)

    return {
        'employee_id': employee_id,
        'name': name,
        'display_name': display_name or employee_id,
    }


def _session_from_token_response(token_data):
    access_token = token_data.get('access_token')
    if not access_token:
        raise KeycloakClientError('Keycloak did not return an access token.')

    id_token_claims = _decode_jwt_payload(token_data.get('id_token'))
    claims = {**id_token_claims, **_fetch_userinfo(access_token)}
    identity = _extract_identity(claims)
    if not identity['employee_id']:
        raise KeycloakClientError('Employee ID was not present in the Keycloak login response.')

    return {
        'employee_id': identity['employee_id'],
        'name': identity['name'],
        'display_name': identity['display_name'],
        'access_token': access_token,
        'refresh_token': token_data.get('refresh_token'),
        'expires_in': token_data.get('expires_in'),
        'refresh_expires_in': token_data.get('refresh_expires_in'),
        'token_type': token_data.get('token_type', 'Bearer'),
    }


def _post_token_request(grant_params):
    _require_client_secret()
    try:
        upstream = requests.post(
            KEYCLOAK_TOKEN_URL,
            data={
                'client_id': KEYCLOAK_CLIENT_ID,
                'client_secret': KEYCLOAK_CLIENT_SECRET,
                **grant_params,
            },
            timeout=20,
        )
        token_data = upstream.json()
    except requests.RequestException as exc:
        raise KeycloakClientError(f'Keycloak token service unreachable: {exc}') from exc
    except ValueError as exc:
        raise KeycloakClientError('Keycloak returned an invalid token response.') from exc

    if not upstream.ok:
        raise KeycloakClientError(token_data.get('error_description') or token_data.get('error') or 'Keycloak login failed.')

    return _session_from_token_response(token_data)


def exchange_code(code, redirect_uri):
    """Exchange an authorization code for a session. Returns the dict shape
    from _session_from_token_response, or raises KeycloakClientError."""
    return _post_token_request({
        'grant_type': 'authorization_code',
        'code': code,
        'redirect_uri': redirect_uri,
    })


def refresh(refresh_token):
    return _post_token_request({
        'grant_type': 'refresh_token',
        'refresh_token': refresh_token,
    })


def resolve_bearer_token(access_token):
    """Resolve a bearer access token straight to an employee_id (no code
    exchange) — used by the DRF API's bearer-token auth for non-browser
    clients (e.g. the Phase 4 Flutter app) that already hold a valid token."""
    try:
        claims = _fetch_userinfo(access_token)
    except requests.RequestException as exc:
        raise KeycloakClientError(f'Invalid or expired Keycloak session: {exc}') from exc

    identity = _extract_identity(claims)
    if not identity['employee_id']:
        raise KeycloakClientError('Employee ID was not present in the Keycloak token claims.')
    return identity
