/// Asset models for the line-inspection platform (`clear` schema): a
/// transmission [LiLine] and a [LiTower] on it. Named with an `Li` prefix to
/// avoid colliding with the legacy [TransmissionLine] / [TowerLocation] models
/// used by the older upload flow.
library;

class LiLine {
  final int id;
  final String name;
  final String voltage;
  final String subdivisionName;
  final bool isActive;

  const LiLine({
    required this.id,
    required this.name,
    required this.voltage,
    required this.subdivisionName,
    required this.isActive,
  });

  factory LiLine.fromJson(Map<String, dynamic> j) => LiLine(
        id: j['id'] as int,
        name: j['name'] as String? ?? '',
        voltage: j['voltage'] as String? ?? '',
        subdivisionName: j['subdivision_name'] as String? ?? '',
        isActive: j['is_active'] as bool? ?? true,
      );
}

class LiTower {
  final int id;
  final String towerNumber;
  final String towerType;
  final String voltage;
  final String lineName;
  final double? latitude;
  final double? longitude;
  final int? lineId;
  final String subdivisionName;

  /// Whether this inspector may actually *save* an inspection here.
  ///
  /// Tower lists are oversight-scoped and deliberately wider than the capture
  /// scope the server enforces on submit, so a tower can be visible yet not
  /// inspectable. False means the form is refused up front rather than after the
  /// checklist is filled in — see `launchInspection`.
  ///
  /// Defaults to true when absent so a tower list cached before the server sent
  /// the field keeps working offline; the server is still the authority.
  final bool canInspect;

  const LiTower({
    required this.id,
    required this.towerNumber,
    required this.towerType,
    required this.voltage,
    required this.lineName,
    required this.latitude,
    required this.longitude,
    required this.lineId,
    required this.subdivisionName,
    this.canInspect = true,
  });

  factory LiTower.fromJson(Map<String, dynamic> j) => LiTower(
        id: j['id'] as int,
        towerNumber: j['tower_number'] as String? ?? '',
        towerType: j['tower_type'] as String? ?? '',
        voltage: j['voltage'] as String? ?? '',
        lineName: j['line_name'] as String? ?? '',
        latitude: (j['latitude'] as num?)?.toDouble(),
        longitude: (j['longitude'] as num?)?.toDouble(),
        lineId: j['line_id'] as int?,
        subdivisionName: j['subdivision_name'] as String? ?? '',
        canInspect: j['can_inspect'] as bool? ?? true,
      );
}
