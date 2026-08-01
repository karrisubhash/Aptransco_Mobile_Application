import 'package:drone_inspection_app/models/li_asset.dart';
import 'package:drone_inspection_app/utils/line_geometry.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// The corridor gate is the one piece of map logic that can silently lie to a
/// field engineer, so it is tested directly rather than through the map.
///
/// The cases below are the real failure modes measured in the sample
/// jurisdiction: the API drops virtual (`VT`) rows, so a double-circuit line's
/// second circuit commonly arrives as nothing but its two substation gantries
/// tens of kilometres apart.

/// Towers ~290 m apart — the median real span — walking north.
List<LiTower> _run(int count, {double startLat = 16.5, double lng = 80.6}) => [
      for (var i = 0; i < count; i++)
        _tower(i, startLat + i * 0.0026, lng),
    ];

LiTower _tower(int id, double lat, double lng) => LiTower(
      id: id,
      towerNumber: '$id',
      towerType: 'A+0',
      voltage: '132kV',
      lineName: 'L',
      latitude: lat,
      longitude: lng,
      lineId: 1,
      subdivisionName: 'S',
    );

const _line = LiLine(
  id: 1,
  name: '132KV Test Line',
  voltage: '132kV',
  subdivisionName: 'S',
  isActive: true,
);

LiLine _lineNo(int id) => LiLine(
      id: id,
      name: 'Line $id',
      voltage: '132kV',
      subdivisionName: 'S',
      isActive: true,
    );

void main() {
  group('isPlausible', () {
    test('accepts a normally spaced run of towers', () {
      expect(isPlausible(_run(8).map((t) => LatLng(t.latitude!, t.longitude!)).toList()),
          isTrue);
    });

    test('rejects fewer than three points', () {
      final two = _run(2).map((t) => LatLng(t.latitude!, t.longitude!)).toList();
      expect(two.length, 2);
      expect(isPlausible(two), isFalse);
    });

    test('rejects the two-gantries-only case a stripped Ckt-2 produces', () {
      // 16.5,80.6 to 16.7,80.6 is ~22 km — the measured Nuzvid–Narasapuram Ckt-2 gap.
      expect(
        isPlausible(const [LatLng(16.5, 80.6), LatLng(16.7, 80.6), LatLng(16.9, 80.6)]),
        isFalse,
        reason: 'every span is far past maxSegmentM',
      );
    });

    test('rejects a single implausible hop inside an otherwise normal line', () {
      final pts = _run(8).map((t) => LatLng(t.latitude!, t.longitude!)).toList()
        // A tower appended out of order, ~11 km away — what a NULL line_sequence
        // plus a lexicographic tower_number sort produces.
        ..add(const LatLng(16.6, 80.6));
      expect(isPlausible(pts), isFalse);
    });

    test('rejects a mid-line jump that is under the absolute ceiling', () {
      // ~1.1 km — below maxSegmentM, but 4x the line's own median span.
      final pts = <LatLng>[
        const LatLng(16.5000, 80.6),
        const LatLng(16.5026, 80.6),
        const LatLng(16.5152, 80.6),
        const LatLng(16.5178, 80.6),
      ];
      expect(isPlausible(pts), isFalse);
    });

    test('rejects towers that all share one coordinate', () {
      expect(
        isPlausible(const [LatLng(16.5, 80.6), LatLng(16.5, 80.6), LatLng(16.5, 80.6)]),
        isFalse,
      );
    });
  });

  group('buildCorridors', () {
    test('skips a line that fails the gate but keeps the ones that pass', () {
      final corridors = buildCorridors([
        (line: _lineNo(1), towers: _run(6)),
        // Two gantries 22 km apart.
        (
          line: _lineNo(2),
          towers: [_tower(90, 16.5, 81.6), _tower(91, 16.7, 81.6)]
        ),
        (line: _lineNo(3), towers: _run(5, lng: 80.9)),
      ]);
      expect(corridors.map((c) => c.lineId), [1, 3]);
    });

    test('drops towers with no coordinates without breaking the chain', () {
      final towers = _run(5).toList()
        ..insert(
          2,
          const LiTower(
            id: 999,
            towerNumber: '999',
            towerType: 'A+0',
            voltage: '132kV',
            lineName: 'L',
            latitude: null,
            longitude: null,
            lineId: 1,
            subdivisionName: 'S',
          ),
        );
      final corridors = buildCorridors([(line: _line, towers: towers)]);
      expect(corridors, hasLength(1));
      expect(corridors.single.points, hasLength(5));
    });

    test('draws one stroke for two circuits sharing the same structures', () {
      // A double-circuit line: both circuits occupy identical coordinates, so
      // drawing both would stack two strokes and let iteration order pick the
      // visible colour.
      final corridors = buildCorridors([
        (line: _lineNo(1), towers: _run(6)),
        (line: _lineNo(2), towers: _run(6)),
      ]);
      expect(corridors, hasLength(1));
    });

    test('carries the voltage through for styling', () {
      final corridors = buildCorridors([(line: _line, towers: _run(4))]);
      expect(corridors.single.voltage, '132kV');
      expect(corridors.single.lineName, '132KV Test Line');
    });

    test('returns nothing for no lines', () {
      expect(buildCorridors(const []), isEmpty);
    });
  });
}
