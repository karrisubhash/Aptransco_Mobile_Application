from rest_framework import serializers
from .models import Inspection, InspectionImage

class InspectionImageSerializer(serializers.ModelSerializer):
    class Meta:
        model = InspectionImage
        fields = ['id', 'image', 'thumbnail']

class InspectionSerializer(serializers.ModelSerializer):
    client_id = serializers.CharField(
        required=False, allow_null=True, allow_blank=True, max_length=64
    )
    component = serializers.CharField(required=False, allow_blank=True)
    defect = serializers.CharField(required=False, allow_blank=True)
    line_name = serializers.CharField(required=False, allow_blank=True)
    voltage = serializers.CharField(required=False, allow_blank=True)
    latitude = serializers.FloatField(required=False, allow_null=True)
    longitude = serializers.FloatField(required=False, allow_null=True)
    # The app sends the client-captured time under the key "timestamp";
    # map it onto the model's captured_at field.
    timestamp = serializers.DateTimeField(
        required=False, allow_null=True, source='captured_at'
    )
    images = InspectionImageSerializer(many=True, read_only=True)

    class Meta:
        model = Inspection
        fields = [
            'id',
            'client_id',
            'transmission_line_id',
            'line_name',
            'tower_location',
            'voltage',
            'component',
            'defect',
            'images',
            'latitude',
            'longitude',
            'timestamp',
            'created_at',
        ]
        read_only_fields = ['created_at']

    def validate_client_id(self, value):
        # An empty string would collide with every other empty string under
        # the unique constraint — store "no key" as NULL instead.
        return value or None

    def validate(self, attrs):
        if not attrs.get('component') and not attrs.get('defect'):
            raise serializers.ValidationError(
                'Provide at least one of component or defect.'
            )
        return attrs