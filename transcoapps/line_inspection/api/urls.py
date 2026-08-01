from django.urls import path

from . import views

urlpatterns = [
    path('health/', views.HealthView.as_view(), name='api-health'),
    path('ping/', views.PingView.as_view(), name='api-ping'),

    # Mobile auth (Phase 4) — checkCred-issued DB-backed token
    path('auth/login/', views.MobileLoginView.as_view(), name='api-login'),
    path('auth/logout/', views.MobileLogoutView.as_view(), name='api-logout'),
    path('auth/me/', views.MobileMeView.as_view(), name='api-me'),

    path('auth/keycloak/exchange/', views.KeycloakExchangeView.as_view(), name='api-keycloak-exchange'),
    path('auth/keycloak/refresh/', views.KeycloakRefreshView.as_view(), name='api-keycloak-refresh'),

    path('catalog/', views.CatalogView.as_view(), name='api-catalog'),
    path('subdivisions/', views.SubdivisionListView.as_view(), name='api-subdivisions'),

    path('lines/', views.LineListView.as_view(), name='api-lines'),
    path('lines/<int:line_id>/towers/', views.LineTowerListView.as_view(), name='api-line-towers'),
    path('towers/', views.TowerListView.as_view(), name='api-towers'),
    path('towers/<int:pk>/', views.TowerDetailView.as_view(), name='api-tower-detail'),

    # Phase 3 dashboard map (reporting-hierarchy oversight scope)
    path('map/lines/', views.MapLineListView.as_view(), name='api-map-lines'),
    path('map/towers/', views.MapTowerListView.as_view(), name='api-map-towers'),

    # Mobile inspection contract (multipart submit + list/detail). `list/` and
    # `export/` are literal segments declared before the <int:pk> route so they
    # stay unambiguous.
    path('line-inspections/', views.LineInspectionSubmitView.as_view(), name='api-line-inspections-submit'),
    path('line-inspections/list/', views.MobileInspectionListView.as_view(), name='api-line-inspections-list'),
    path('line-inspections/export/', views.MobileInspectionExportView.as_view(), name='api-line-inspections-export'),
    path('line-inspections/<int:pk>/', views.MobileInspectionDetailView.as_view(), name='api-line-inspections-detail'),

    # Legacy JSON create/list (kept)
    path('inspections/', views.InspectionListView.as_view(), name='api-inspections-list'),
    path('inspections/create/', views.InspectionCreateView.as_view(), name='api-inspections-create'),

    path('tickets/', views.DefectTicketListView.as_view(), name='api-tickets'),
    path('tickets/export/', views.DefectTicketExportView.as_view(), name='api-tickets-export'),
    path('tickets/<int:pk>/close/', views.DefectTicketCloseView.as_view(), name='api-ticket-close'),

    path('support-requests/', views.SupportRequestListCreateView.as_view(), name='api-support-requests'),
    path('support-requests/<int:pk>/resolve/', views.SupportRequestResolveView.as_view(), name='api-support-request-resolve'),

    path('dashboard/', views.MobileDashboardView.as_view(), name='api-dashboard'),
]
