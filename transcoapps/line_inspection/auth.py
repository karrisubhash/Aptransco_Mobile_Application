"""Session-based identity for the admin panel / web dashboard — no
django.contrib.auth.User anywhere. Identity is a bare SAP employee_id,
stored directly in Django's session framework (independent of contrib.auth).

Active login mechanism: the legacy checkCred service
(services/checkcred_client.py). Keycloak (services/keycloak_client.py) is
built but DORMANT — deferred to a later phase pending a Keycloak-admin-console
redirect-URI fix outside our control. Do not delete the Keycloak code; it's
kept ready for when that phase happens.

Three authorization tiers:
  - any logged-in employee                -> @login_required
  - Admin (EE holding a granted position)  -> @admin_required
  - Super Admin (decides who's an Admin)   -> @super_admin_required
"""
from functools import wraps

from django.shortcuts import redirect, render
from django.urls import reverse
from django.http import HttpResponseForbidden

from . import request_scope
from .models import EmployeeCadreSnapshot, FieldEECadrePosition, SuperAdmin
from .services import checkcred_client
from .services.checkcred_client import CheckCredError


def login_view(request):
    if request.method == 'POST':
        user_id = request.POST.get('user_id', '')
        passwd = request.POST.get('passwd', '')
        try:
            identity = checkcred_client.verify_credentials(user_id, passwd)
        except CheckCredError as exc:
            return render(request, 'line_inspection/login.html', {'error': str(exc), 'user_id': user_id})

        request.session['employee_id'] = identity['employee_id']
        request.session['display_name'] = identity['display_name'] or identity['employee_id']
        next_url = request.POST.get('next') or request.GET.get('next') or reverse('line_inspection:admin-home')
        return redirect(next_url)

    return render(request, 'line_inspection/login.html', {'next': request.GET.get('next', '')})


def forgot_password_view(request):
    result = None
    if request.method == 'POST':
        user_id = request.POST.get('user_id', '')
        try:
            checkcred_client.forgot_password(user_id)
            result = 'If that employee id is registered, password-reset instructions have been sent.'
        except CheckCredError as exc:
            result = f'Error: {exc}'
    return render(request, 'line_inspection/forgot_password.html', {'result': result})


def change_password_view(request):
    result = None
    if request.method == 'POST':
        user_id = request.POST.get('user_id', '')
        oldpass = request.POST.get('oldpass', '')
        passwd = request.POST.get('passwd', '')
        confirm = request.POST.get('confirm', '')
        if passwd != confirm:
            result = 'Error: New password and confirmation do not match.'
        else:
            try:
                checkcred_client.save_password(user_id, passwd, oldpass)
                result = 'Password changed successfully. You can log in with your new password.'
            except CheckCredError as exc:
                result = f'Error: {exc}'
    return render(request, 'line_inspection/change_password.html', {'result': result})


def logout_view(request):
    request.session.flush()
    return redirect(reverse('line_inspection:login'))


def is_admin(employee_id):
    """True if employee_id currently holds a position_id that's been
    granted Admin (FieldEECadrePosition) rights, or is a Super Admin —
    Super Admin is a superset of Admin, not a separate/unrelated tier.

    Memoized per request (request_scope): a decorator, a view, a serializer and
    the identity block all ask this while building one response, and each ask cost
    up to three queries."""
    return request_scope.memoized(('is_admin', employee_id),
                                  lambda: _is_admin(employee_id))


def _is_admin(employee_id):
    if is_super_admin(employee_id):
        return True
    snapshot = EmployeeCadreSnapshot.objects.filter(employee_id=employee_id).first()
    if not snapshot or not snapshot.position_id:
        return False
    return FieldEECadrePosition.objects.filter(position_id=snapshot.position_id).exists()


def is_super_admin(employee_id):
    """Also memoized per request — is_admin(), is_management() and the super-admin
    decorators each reach for it."""
    return request_scope.memoized(
        ('is_super_admin', employee_id),
        lambda: SuperAdmin.objects.filter(employee_id=employee_id).exists(),
    )


def login_required(view_func):
    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        if not request.session.get('employee_id'):
            login_url = reverse('line_inspection:login') + f'?next={request.path}'
            return redirect(login_url)
        return view_func(request, *args, **kwargs)
    return wrapper


def admin_required(view_func):
    @login_required
    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        if not is_admin(request.session['employee_id']):
            return HttpResponseForbidden('This section is restricted to Admins (EE cadre with an assigned field position).')
        return view_func(request, *args, **kwargs)
    return wrapper


def super_admin_required(view_func):
    @login_required
    @wraps(view_func)
    def wrapper(request, *args, **kwargs):
        if not is_super_admin(request.session['employee_id']):
            return HttpResponseForbidden('This section is restricted to Super Admins.')
        return view_func(request, *args, **kwargs)
    return wrapper
