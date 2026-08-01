from django.urls import path

from .views import (
    PingView,
    CatalogView,
    LineListView,
    LineTowersView,
    TowerDetailView,
    InspectionCreateView,
    SubdivisionListView,
    InspectionListView,
    InspectionDetailView,
    TicketListView,
    TicketCloseView,
    SupportRequestListCreateView,
    SupportRequestResolveView,
    DashboardView,
)

urlpatterns = [
    path('ping/', PingView.as_view(), name='li-ping'),
    path('catalog/', CatalogView.as_view(), name='li-catalog'),
    path('subdivisions/', SubdivisionListView.as_view(), name='li-subdivisions'),
    path('lines/', LineListView.as_view(), name='li-lines'),
    path('lines/<int:line_id>/towers/', LineTowersView.as_view(), name='li-line-towers'),
    path('towers/<int:tower_id>/', TowerDetailView.as_view(), name='li-tower'),
    path('line-inspections/', InspectionCreateView.as_view(), name='li-inspection-create'),
    path('line-inspections/list/', InspectionListView.as_view(), name='li-inspection-list'),
    path('line-inspections/<int:pk>/', InspectionDetailView.as_view(), name='li-inspection-detail'),
    path('tickets/', TicketListView.as_view(), name='li-tickets'),
    path('tickets/<int:pk>/close/', TicketCloseView.as_view(), name='li-ticket-close'),
    path('support-requests/', SupportRequestListCreateView.as_view(), name='li-support'),
    path('support-requests/<int:pk>/resolve/', SupportRequestResolveView.as_view(), name='li-support-resolve'),
    path('dashboard/', DashboardView.as_view(), name='li-dashboard'),
]
