from django.urls import path, include

from . import auth, admin_views, dashboard_views

app_name = 'line_inspection'

urlpatterns = [
    # Session-based login (checkCred — active) — no django.contrib.auth.
    # Keycloak (auth.callback_view) is dormant, deferred to a later phase.
    path('login/', auth.login_view, name='login'),
    path('forgot-password/', auth.forgot_password_view, name='forgot-password'),
    path('change-password/', auth.change_password_view, name='change-password'),
    path('logout/', auth.logout_view, name='logout'),

    # Admin panel
    path('admin/', admin_views.admin_home, name='admin-home'),
    path('admin/super/positions/', admin_views.manage_admins, name='manage-admins'),
    path('admin/super/positions/lookup/<str:position_id>/', admin_views.lookup_position, name='lookup-position'),

    path('admin/assignments/', admin_views.role_assignments, name='role-assignments'),
    path('admin/assignments/new/<str:employee_id>/', admin_views.role_assignment_new, name='role-assignment-new'),
    path('admin/line/<int:line_id>/schedule/', admin_views.line_schedule_json, name='line-schedule-json'),

    path('admin/checklist/', admin_views.checklist_editor, name='checklist-editor'),
    path('admin/checklist/group/new/', admin_views.checklist_item_group_form, name='checklist-group-new'),
    path('admin/checklist/group/<int:pk>/', admin_views.checklist_item_group_form, name='checklist-group-edit'),
    path('admin/checklist/item/new/', admin_views.checklist_item_form, name='checklist-item-new'),
    path('admin/checklist/item/<int:pk>/', admin_views.checklist_item_form, name='checklist-item-edit'),
    path('admin/checklist/defect/new/', admin_views.defect_form, name='checklist-defect-new'),
    path('admin/checklist/defect/<int:pk>/', admin_views.defect_form, name='checklist-defect-edit'),
    path('admin/checklist/followup/new/', admin_views.followup_question_form, name='checklist-followup-new'),
    path('admin/checklist/followup/<int:pk>/', admin_views.followup_question_form, name='checklist-followup-edit'),
    path('admin/checklist/rule/new/', admin_views.criticality_rule_form, name='checklist-rule-new'),
    path('admin/checklist/rule/<int:pk>/', admin_views.criticality_rule_form, name='checklist-rule-edit'),
    path('admin/checklist/delete/<str:model_name>/<int:pk>/', admin_views.checklist_delete, name='checklist-delete'),

    path('admin/sap-mapping/', admin_views.sap_mapping, name='sap-mapping'),

    # LILO (Super Admin only)
    path('admin/lilo/', admin_views.lilo_home, name='lilo-home'),
    path('admin/lilo/<int:pk>/', admin_views.lilo_reconcile, name='lilo-reconcile'),

    # Phase 3 field-engineer / oversight dashboard (read-only)
    path('dashboard/map/', dashboard_views.map_view, name='dashboard-map'),
    path('dashboard/tickets/', dashboard_views.tickets_view, name='dashboard-tickets'),
    path('dashboard/inspections/', dashboard_views.inspections_view, name='dashboard-inspections'),
    path('dashboard/register/', dashboard_views.register_view, name='dashboard-register'),
    path('dashboard/reports/', dashboard_views.rollup_view, name='dashboard-rollup'),

    # REST API
    path('api/', include('line_inspection.api.urls')),
]
