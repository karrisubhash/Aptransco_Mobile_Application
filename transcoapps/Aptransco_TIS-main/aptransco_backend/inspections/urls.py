from django.urls import path
from .views import (
    HealthView,
    InspectionCreateView,
    InspectionStatusView,
    TowerInspectionHistoryView,
)

urlpatterns = [
    path('health/', HealthView.as_view(), name='health'),
    path('inspections/', InspectionCreateView.as_view(), name='inspection-create'),
    path('inspections/status/', InspectionStatusView.as_view(), name='inspection-status'),
    path('inspections/history/', TowerInspectionHistoryView.as_view(), name='inspection-history'),
]