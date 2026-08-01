"""DRF authentication classes resolving to a bare employee_id — there is no
django.contrib.auth.User anywhere in this app, so request.user is a small
stand-in object rather than a real model instance."""
from datetime import timedelta

from django.utils import timezone
from rest_framework.authentication import BaseAuthentication, get_authorization_header
from rest_framework import exceptions

from ..models import MobileAuthToken
from ..services import keycloak_client
from ..services.keycloak_client import KeycloakClientError


class SimpleIdentity:
    is_authenticated = True

    def __init__(self, employee_id):
        self.employee_id = employee_id
        self.pk = employee_id

    def __str__(self):
        return self.employee_id


class SessionEmployeeAuthentication(BaseAuthentication):
    """For browser-based calls from our own templates (same-origin, session cookie)."""

    def authenticate(self, request):
        employee_id = request.session.get('employee_id')
        if not employee_id:
            return None
        return (SimpleIdentity(employee_id), None)


class MobileTokenAuthentication(BaseAuthentication):
    """For the Phase 4 Flutter field app: a DB-backed, revocable token issued by
    the checkCred login endpoint. Uses the `Token` scheme (NOT `Bearer`, which
    KeycloakBearerAuthentication owns) so the two coexist regardless of order —
    each declines a header that isn't its scheme."""

    keyword = 'token'
    # Only bother touching last_used_at when it's this stale, so a busy client
    # doesn't write a row to the clear schema on every single request.
    _touch_after = timedelta(minutes=5)

    def authenticate(self, request):
        header = get_authorization_header(request).decode('utf-8')
        if not header.lower().startswith('token '):
            return None
        key = header[6:].strip()
        if not key:
            return None
        token = MobileAuthToken.objects.filter(key=key).first()
        if token is None or not token.is_active:
            raise exceptions.AuthenticationFailed('Invalid or revoked token.')
        if token.expires_at and token.expires_at < timezone.now():
            raise exceptions.AuthenticationFailed('Token expired — please sign in again.')

        now = timezone.now()
        if token.last_used_at is None or (now - token.last_used_at) > self._touch_after:
            token.last_used_at = now
            token.save(update_fields=['last_used_at'])

        return (SimpleIdentity(token.employee_id), token)

    def authenticate_header(self, request):
        return 'Token'


class KeycloakBearerAuthentication(BaseAuthentication):
    """For non-browser clients holding a Keycloak access token directly
    (the Phase 4 Flutter app, or any other external API consumer)."""

    def authenticate(self, request):
        header = get_authorization_header(request).decode('utf-8')
        if not header.lower().startswith('bearer '):
            return None
        token = header[7:].strip()
        if not token:
            return None
        try:
            identity = keycloak_client.resolve_bearer_token(token)
        except KeycloakClientError as exc:
            raise exceptions.AuthenticationFailed(str(exc))
        return (SimpleIdentity(identity['employee_id']), token)
