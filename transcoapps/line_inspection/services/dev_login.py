"""LOCAL DEVELOPMENT ONLY - offline stand-in for the checkCred gateway.

Why this exists: checkCred (services/checkcred_client.py) is the real login
mechanism, but it is unreachable from outside APTRANSCO's network and needs
app-level gateway credentials (APTRANSCO_AUTH_USER / APTRANSCO_AUTH_PASS)
that are not in this checkout. That makes the web admin panel and the Flutter
app un-loggable-into on a developer machine. This module resolves an employee
id against the locally-synced EmployeeCadreSnapshot table instead, so UI work
can proceed offline.

It DOES NOT verify anyone's real password. It checks a single shared
development password from the environment. Never treat a session created
this way as proof of identity.

Three independent conditions must all hold before it will do anything:

  1. settings.DEBUG is True
  2. LINE_INSPECTION_DEV_LOGIN == '1'
  3. LINE_INSPECTION_DEV_PASSWORD is set to a non-empty value

Any one of them missing and is_enabled() returns False, so checkcred_client
falls straight through to the real gateway. Deleting this file and the
four-line delegation at the top of checkcred_client.verify_credentials
removes the feature entirely.
"""
import hmac
import logging
import os

logger = logging.getLogger(__name__)

ENV_FLAG = 'LINE_INSPECTION_DEV_LOGIN'
ENV_PASSWORD = 'LINE_INSPECTION_DEV_PASSWORD'

_warned = False


def is_enabled():
    """True only when all three guards hold. Read at call time, not import
    time, so toggling the env var takes effect on the next server start
    without any import-order subtlety."""
    from django.conf import settings

    if not getattr(settings, 'DEBUG', False):
        return False
    if os.environ.get(ENV_FLAG, '') != '1':
        return False
    if not os.environ.get(ENV_PASSWORD, ''):
        return False

    global _warned
    if not _warned:
        _warned = True
        logger.warning(
            'DEV LOGIN ACTIVE - checkCred is bypassed and passwords are NOT '
            'verified. Local development only. Unset %s to restore real auth.',
            ENV_FLAG,
        )
    return True


def verify(user_id, passwd):
    """Same contract as checkcred_client.verify_credentials: returns
    {employee_id, display_name, empdata} or raises CheckCredError."""
    # Imported here rather than at module scope: this module is pulled in by
    # checkcred_client, which the app registry loads before models are ready.
    from line_inspection.models import EmployeeCadreSnapshot
    from .checkcred_client import CheckCredError

    user_id = str(user_id or '').strip()
    passwd = str(passwd or '')
    if not user_id or not passwd:
        raise CheckCredError('Employee ID and password are required.')

    expected = os.environ.get(ENV_PASSWORD, '')
    if not hmac.compare_digest(passwd, expected):
        raise CheckCredError('Invalid credentials.')

    # Match the real gateway's normalization exactly - SAP ids are zero-padded
    # to 8 digits everywhere downstream (see checkcred_client.verify_credentials).
    employee_id = user_id.zfill(8) if user_id.isdigit() else user_id

    snapshot = EmployeeCadreSnapshot.objects.filter(employee_id=employee_id).first()
    if snapshot is None:
        raise CheckCredError(
            f'No cadre snapshot for employee {employee_id}. Dev login can only '
            f'sign in employees already synced into EmployeeCadreSnapshot.'
        )

    logger.warning('DEV LOGIN: signed in %s (%s) without password verification.',
                   employee_id, snapshot.employee_name)

    return {
        'employee_id': employee_id,
        'display_name': snapshot.employee_name or employee_id,
        # The real gateway returns SAP's employee record here. Only CNAME/NAME1
        # are read downstream, so mirror just those and mark the payload.
        'empdata': {
            'CNAME': snapshot.employee_name,
            'NAME1': snapshot.employee_name,
            '_source': 'dev_login',
        },
    }
