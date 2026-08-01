import 'package:latlong2/latlong.dart';

import '../models/li_asset.dart';

/// Turning a line's towers into a drawable corridor — and, just as importantly,
/// refusing to draw one when the towers cannot honestly describe the route.
///
/// The app has no line geometry: `GET /lines/<id>/towers/` returns towers in
/// schedule order (`line_sequence`, then `tower_number`) and the corridor is
/// chained from those coordinates. That is only truthful when the towers
/// actually cover the line, and often they do not:
///
///  * The API excludes virtual (`VT`) rows, and on a double-circuit line the
///    second circuit is almost entirely VT — so Ckt-2 commonly arrives as just
///    its two substation gantries. Chaining those draws one straight stroke
///    across tens of kilometres of ground the conductor never crosses.
///  * `line_sequence` is nullable and is not exposed to the app, so a line whose
///    towers were never scheduled falls back to a lexicographic `tower_number`
///    sort where '10' precedes '9' — a corridor that jumps back and forth.
///
/// A fabricated corridor is worse than none: unlike the bare dots, it looks like
/// surveyed data and an engineer could navigate by it. So [buildCorridors] gates
/// every line on [minPoints] and on segment plausibility, and silently omits any
/// line that fails. Those lines still show their towers — the map simply stops
/// claiming to know the route between them.
///
/// Pure and dependency-free by design, so the ordering rules can be unit-tested
/// without a map or a device.
class LineCorridor {
  const LineCorridor({
    required this.lineId,
    required this.lineName,
    required this.voltage,
    required this.points,
  });

  final int lineId;
  final String lineName;
  final String voltage;

  /// Two or more points, in route order.
  final List<LatLng> points;
}

/// A line needs at least this many mappable towers before its corridor is
/// believable. Two points is exactly the degenerate Ckt-2 case described above —
/// a straight line between two substations — so two is not enough.
const int minPoints = 3;

/// No single span may exceed this. Real spans in the sample jurisdiction run
/// ~230–340 m (median 290 m); anything past 2 km is a gap in the data, not a
/// span, and is the signature of the missing-VT-rows case.
const double maxSegmentM = 2000;

/// A span may also not exceed this multiple of the line's own median span. Catches
/// the subtler mis-ordering — a corridor that runs out and then jumps back into
/// the middle — on lines whose absolute spans are all under [maxSegmentM].
const double maxSegmentMedianFactor = 4.0;

/// Corridors for every line whose towers describe a plausible route.
///
/// [grouped] must preserve the server's per-line tower order. Lines that fail
/// the gate are omitted, as are exact duplicate corridors: a double-circuit
/// line's two circuits occupy the same structures, so drawing both would stack
/// two identical strokes and let iteration order decide which colour is visible.
List<LineCorridor> buildCorridors(
  Iterable<({LiLine line, List<LiTower> towers})> grouped,
) {
  final out = <LineCorridor>[];
  final seen = <String>{};
  for (final g in grouped) {
    final points = <LatLng>[
      for (final t in g.towers)
        if (t.latitude != null && t.longitude != null)
          LatLng(t.latitude!, t.longitude!),
    ];
    if (!isPlausible(points)) continue;
    final fingerprint = _fingerprint(points);
    if (!seen.add(fingerprint)) continue;
    out.add(LineCorridor(
      lineId: g.line.id,
      lineName: g.line.name,
      voltage: g.line.voltage,
      points: points,
    ));
  }
  return out;
}

/// Whether [points] describe a route worth drawing — see the gate rationale on
/// [LineCorridor].
bool isPlausible(List<LatLng> points) {
  if (points.length < minPoints) return false;
  final spans = <double>[];
  for (var i = 1; i < points.length; i++) {
    final d = _metres(points[i - 1], points[i]);
    if (d > maxSegmentM) return false;
    spans.add(d);
  }
  // Every span coincident (a line whose towers all share one coordinate) carries
  // no route information either.
  final median = _median(spans);
  if (median <= 0) return false;
  for (final d in spans) {
    if (d > median * maxSegmentMedianFactor) return false;
  }
  return true;
}

double _median(List<double> xs) {
  final sorted = [...xs]..sort();
  final n = sorted.length;
  if (n == 0) return 0;
  return n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
}

/// Rounded to ~1 m so two circuits on the same structures compare equal despite
/// float noise in their separately-synced coordinates.
String _fingerprint(List<LatLng> points) => points
    .map((p) => '${p.latitude.toStringAsFixed(5)},'
        '${p.longitude.toStringAsFixed(5)}')
    .join(';');

final Distance _distance = const Distance();

double _metres(LatLng a, LatLng b) => _distance.as(LengthUnit.Meter, a, b);
