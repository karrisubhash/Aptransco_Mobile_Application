from .auth import is_admin, is_super_admin
from . import viewing


def identity(request):
    employee_id = request.session.get('employee_id')
    if not employee_id:
        return {}
    return {
        'session_employee_id': employee_id,
        'session_display_name': request.session.get('display_name', employee_id),
        'is_admin': is_admin(employee_id),
        'is_super_admin': is_super_admin(employee_id),
        # Drives the Reports tab + all-tower rollup scope. Cheap (one indexed
        # snapshot lookup); the heavier tier/subtree walk stays in the views.
        'is_management': viewing.is_management(employee_id),
        'cadre_label': viewing.display_label(employee_id),
    }
