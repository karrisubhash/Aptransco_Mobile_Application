import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/li_asset.dart';
import '../utils/li_style.dart';
import 'inspect_launcher.dart' show kPresenceRadiusM;
import 'map_dots.dart';

/// Chrome that sits over the map: the colour legend, the compass, tower-number
/// labels, and the basemap attribution.
///
/// Kept out of `home_tab.dart` because these are all pure presentation, and two
/// of them ([TowerLabelLayer], and any future camera-driven chrome) must live
/// inside `FlutterMap.children` to read [MapCamera] — so they rebuild a leaf
/// rather than the whole tab when the camera moves.

// ---------------------------------------------------------------------------
// Legend
// ---------------------------------------------------------------------------

/// Explains what the map's colours mean, collapsed to a pill until asked.
///
/// The map encodes three things and, until now, explained none of them: a pin's
/// fill is its [TowerState] (inspected, still queued on this phone, or not
/// inspected), an accent ring means the tower is inside the presence radius (so
/// Inspect opens with no override), and a corridor stroke's colour and thickness
/// are its voltage class. Colour is the *only* channel carrying the first of
/// those, so a grey dot next to a green one was unreadable without tapping both.
///
/// Starts collapsed: on a phone the map is the product, and a permanent legend
/// would cost more screen than it earns once the engineer knows the scale.
class MapLegend extends StatefulWidget {
  const MapLegend({super.key});

  @override
  State<MapLegend> createState() => _MapLegendState();
}

class _MapLegendState extends State<MapLegend> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kCardBg,
      elevation: 3,
      shadowColor: kBrandPrimaryDark.withValues(alpha: 0.30),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusSm),
        side: const BorderSide(color: kOutline),
      ),
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(_open ? Icons.expand_more_rounded : Icons.expand_less_rounded,
                    size: 16, color: kInkSoft),
                const SizedBox(width: 4),
                const Text('INFO',
                    style: TextStyle(
                        fontSize: 11.5, fontWeight: FontWeight.w700, color: kInk)),
              ]),
              if (_open) ...[
                const SizedBox(height: kSpaceSm),
                _heading('Tower'),
                // Cycle order — grey, orange, green — so the legend reads as the
                // progression a tower actually makes.
                for (final s in TowerState.values)
                  _swatchRow(_stateDot(s), towerStateLabel(s)),
                const SizedBox(height: 6),
                _swatchRow(_stateDot(TowerState.inspected, ring: true),
                    'Within ${kPresenceRadiusM.round()} m — inspect now'),
                const SizedBox(height: kSpaceSm),
                _heading('Line'),
                for (final v in kVoltageColor.keys) _swatchRow(_strokeSwatch(v), v),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t,
            style: const TextStyle(
                fontSize: 9.5,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
                color: kInkFaint)),
      );

  Widget _swatchRow(Widget swatch, String label) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 18, height: 14, child: Center(child: swatch)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 11, color: kInkSoft)),
        ]),
      );

  /// The same dot the map draws, at legend size.
  Widget _stateDot(TowerState state, {bool ring = false}) => SizedBox(
        width: ring ? 14 : 12,
        height: ring ? 14 : 12,
        child: TowerDot(
            color: towerStateColor(state),
            ring: ring,
            borderWidth: ring ? 2 : 1.5),
      );

  /// A short length of corridor, casing and all, so the legend matches the map.
  Widget _strokeSwatch(String voltage) => CustomPaint(
        size: const Size(18, 8),
        painter: _StrokePainter(voltage),
      );
}

class _StrokePainter extends CustomPainter {
  const _StrokePainter(this.voltage);
  final String voltage;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final core = voltageStroke(voltage);
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = kCorridorCasing.withValues(alpha: kCorridorCasingAlpha)
        ..strokeWidth = core + kCorridorCasingWidth
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = voltageColor(voltage)
        ..strokeWidth = core
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_StrokePainter old) => old.voltage != voltage;
}

// ---------------------------------------------------------------------------
// Compass
// ---------------------------------------------------------------------------

/// A reset-to-north control, shown only once the map has actually been rotated.
///
/// Two-finger rotation is on, and until now nothing showed that the map was
/// skewed or offered a way back — a twist could only be undone by twisting
/// again. Hidden at bearing ~0 so it costs nothing in the common case.
///
/// Takes [bearing] as a plain value rather than reading [MapCamera] itself,
/// because it lives in the right-hand control column, which is a sibling of the
/// map rather than one of its children. `MapController.rotate` does not fire
/// `onPositionChanged`, so the host must feed this from `onMapEvent`.
class MapCompass extends StatelessWidget {
  const MapCompass({
    super.key,
    required this.bearing,
    required this.onReset,
    this.size = 46,
  });

  final double bearing;
  final VoidCallback onReset;
  final double size;

  /// Below this many degrees the map reads as north-up and the control hides.
  static const double hideBelowDegrees = 0.5;

  static bool isRotated(double bearing) {
    final b = bearing % 360;
    final off = b > 180 ? 360 - b : b;
    return off.abs() >= hideBelowDegrees;
  }

  @override
  Widget build(BuildContext context) {
    if (!isRotated(bearing)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: kSpaceMd),
      child: Material(
        color: kCardBg,
        elevation: 3,
        shadowColor: kBrandPrimaryDark.withValues(alpha: 0.30),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kRadiusSm),
          side: const BorderSide(color: kOutline),
        ),
        child: Tooltip(
          message: 'Face north',
          child: InkWell(
            onTap: onReset,
            child: SizedBox(
              width: size,
              height: size,
              // The needle turns with the map, so it points at true north.
              child: Transform.rotate(
                angle: -bearing * (3.1415926535897932 / 180),
                child: const Icon(Icons.navigation_rounded,
                    size: 22, color: kBrandAccent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Tower labels
// ---------------------------------------------------------------------------

/// Tower numbers, drawn beside their pins once the map is close enough to read
/// them. A map layer, so it must go in `FlutterMap.children`.
///
/// Identifying a tower previously required tapping it and reading the sheet —
/// unhelpful when the job is "walk to 47". Three things keep this cheap and
/// legible:
///
///  * **Zoom gate.** Nothing below [minZoom], where spans (~290 m typical) are
///    still under a finger's width apart.
///  * **Viewport culling.** Only towers inside `camera.visibleBounds` become
///    markers, so a supervisor's tens of thousands of towers do not each
///    allocate a widget to show the four on screen.
///  * **Upright under rotation.** `rotate: true` counter-rotates each label
///    about its own centre (its box is symmetric on the tower's coordinate), so
///    the offset that pushes the text clear of the dot is applied *inside* the
///    counter-rotated child and therefore stays screen-down at any bearing.
///
/// Labels are wrapped in [IgnorePointer]: map layers are not pointer-translucent
/// by default, so without it this layer would swallow taps meant for the pins
/// underneath.
class TowerLabelLayer extends StatelessWidget {
  const TowerLabelLayer({
    super.key,
    required this.towers,
    this.minZoom = 16.5,
  });

  final List<LiTower> towers;
  final double minZoom;

  static const double _fontSize = 10.5;
  static const double _gap = 3;
  static const double _plateWidth = 90;

  /// Tower numbers are not all short integers — a fifth of them look like
  /// `132TT of KNML2/GDVD2` or `150/24`, far wider than a span is tall. The
  /// leading token identifies the structure; the sheet still shows the full
  /// string.
  static String shortLabel(String towerNumber) {
    final head = towerNumber.trim().split(RegExp(r'\s+')).first;
    if (head.isEmpty) return towerNumber.trim();
    return head.length <= 8 ? head : '${head.substring(0, 8)}…';
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (camera.zoom < minZoom) return const SizedBox.shrink();
    final bounds = camera.visibleBounds;
    // Clear the dot the label belongs to, then half the text, so the plate sits
    // just under the pin.
    final offsetY = TowerPin.dotFor(camera.zoom) / 2 + _gap + _fontSize;
    // Symmetric about the tower's coordinate, so counter-rotation pivots on the
    // point itself.
    final height = offsetY * 2 + _fontSize * 2;

    final markers = <Marker>[];
    for (final t in towers) {
      final lat = t.latitude;
      final lng = t.longitude;
      if (lat == null || lng == null) continue;
      final point = LatLng(lat, lng);
      if (!bounds.contains(point)) continue;
      markers.add(Marker(
        point: point,
        width: _plateWidth,
        height: height,
        alignment: Alignment.center,
        rotate: true,
        child: IgnorePointer(
          child: Align(
            alignment: Alignment.center,
            child: Transform.translate(
              offset: Offset(0, offsetY),
              child: _plate(shortLabel(t.towerNumber)),
            ),
          ),
        ),
      ));
    }
    if (markers.isEmpty) return const SizedBox.shrink();
    return MarkerLayer(markers: markers);
  }

  /// A plate rather than bare text: bare text vanishes into satellite imagery.
  Widget _plate(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: kCardBg.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: kOutline),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: _fontSize,
            fontWeight: FontWeight.w700,
            color: kInk,
            height: 1.1,
          ),
        ),
      );
}

// ---------------------------------------------------------------------------
// Attribution
// ---------------------------------------------------------------------------

/// Basemap credit for whichever layer is showing.
///
/// Both sources require it — OpenStreetMap's tiles are ODbL, and Esri's
/// World_Imagery service carries its own terms — and the map previously credited
/// neither. Hand-rolled rather than [SimpleAttributionWidget] because that
/// widget hardcodes a `flutter_map | ©` prefix and one fixed source, while the
/// correct string here changes with the layer toggle.
class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key, required this.satellite});

  final bool satellite;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: kCardBg.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          child: Text(
            satellite ? 'Imagery © Esri, Maxar, Earthstar' : '© OpenStreetMap contributors',
            style: const TextStyle(fontSize: 9, color: kInkSoft, height: 1.1),
          ),
        ),
      );
}
