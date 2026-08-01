import 'package:flutter/material.dart';

import '../utils/li_style.dart';

/// A plain coloured tower pin (no clustering — the user prefers simple pins).
class TowerDot extends StatelessWidget {
  const TowerDot({
    super.key,
    required this.color,
    this.onTap,
    this.ring = false,
    this.borderWidth,
  });
  final Color color;
  final VoidCallback? onTap;
  final bool ring; // emphasised ring, e.g. an in-range/selected tower

  /// Overrides the default border, which a small dot needs: at a few pixels
  /// across the standard 2 px white ring leaves almost no colour showing.
  final double? borderWidth;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(
                color: ring ? kBrandAccent : Colors.white,
                width: borderWidth ?? (ring ? 3 : 2)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 3,
                offset: const Offset(0, 1),
              ),
            ],
          ),
        ),
      );
}

/// A tower as it reads at a given map zoom: a [TowerDot] that shrinks as the map
/// pulls back.
///
/// Scaling matters because a transmission line is a chain of towers a few hundred
/// metres apart. At a fixed pin size, zooming out to see a whole line turns it
/// into a wall of overlapping pins; shrinking the pin instead lets the line
/// resolve into the thin chain of dots that traces its corridor.
///
/// Sizing is exposed as statics so the caller can size the marker box to match,
/// keeping the dot centred on the tower's coordinate.
class TowerPin extends StatelessWidget {
  const TowerPin({
    super.key,
    required this.color,
    required this.zoom,
    this.ring = false,
    this.selected = false,
    this.onTap,
  });

  final Color color;
  final double zoom;
  final bool ring;

  /// Whether this tower's detail sheet is open.
  ///
  /// Drawn as a soft halo *behind* the dot rather than by changing its border,
  /// because the border already carries [ring] — "inside the presence radius", the
  /// map's statement that Inspect will open without an audited override. The two
  /// have to stay independently readable, since a tower can be either, both or
  /// neither.
  final bool selected;

  final VoidCallback? onTap;

  // The dot ramps linearly between these zooms: a 6 px speck when a whole
  // jurisdiction is in view, a full 26 px target when standing at the tower.
  static const double _minZoom = 11;
  static const double _maxZoom = 17;
  static const double _minDot = 6;
  static const double _maxDot = 26;

  /// A shrunken dot must still be tappable, so the touch area never drops below
  /// this even when the dot drawn inside it is a few pixels across.
  static const double _minTap = 20;

  /// How far the [selected] halo extends past the dot's diameter. The marker box
  /// has to grow to match (see [boxFor]) — at full zoom the dot already fills its
  /// box, so there is no spare room to paint into.
  static const double haloSpread = 10;

  static double dotFor(double zoom) {
    final t = ((zoom - _minZoom) / (_maxZoom - _minZoom)).clamp(0.0, 1.0);
    return _minDot + (_maxDot - _minDot) * t;
  }

  /// The dot's touch area — the dot itself once that exceeds [_minTap].
  static double tapFor(double zoom) {
    final dot = dotFor(zoom);
    return dot < _minTap ? _minTap : dot;
  }

  /// Outline proportional to the diameter, so it reads the same at every size:
  /// the familiar 2 px white (3 px accent when ringed) at full zoom, thinning to
  /// a hairline rather than erasing the fill when the dot is a few pixels across.
  static double _borderFor(double dot, {required bool ring}) {
    final w = dot / (ring ? 7 : 10);
    final min = ring ? 1.2 : 0.8;
    final max = ring ? 3.0 : 2.0;
    if (w < min) return min;
    return w > max ? max : w;
  }

  /// The square marker box this pin needs at [zoom] — the dot's touch area. Being
  /// square, the marker's default centre alignment puts the dot itself on the
  /// tower's coordinate.
  ///
  /// A [selected] pin needs [haloSpread] more room. Growing a marker box grows its
  /// hit area, which would let a pin swallow taps meant for its neighbours — so
  /// this is only ever asked for the one tower whose sheet is open, whose taps are
  /// already being handled.
  static Size boxFor(double zoom, {bool selected = false}) =>
      Size.square(tapFor(zoom) + (selected ? haloSpread : 0));

  @override
  Widget build(BuildContext context) {
    final dot = dotFor(zoom);
    // The tap target stays [_minTap] across around a small dot, so a tower is
    // still selectable when the map is pulled right out. Must agree with
    // [boxFor], which is what sized the marker.
    final side = boxFor(zoom, selected: selected).width;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: side,
        height: side,
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (selected)
              // Proportional to the dot, so the halo stays in scale as the pin
              // ramps. Fits because [boxFor] reserved [haloSpread] for it.
              SizedBox(
                width: dot + haloSpread,
                height: dot + haloSpread,
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Color(0x3314243D),
                  ),
                ),
              ),
            SizedBox(
              width: dot,
              height: dot,
              child: TowerDot(
                color: color,
                ring: ring,
                // Keep the outline proportional so a small dot still reads as
                // its status colour rather than as a white speck.
                borderWidth: _borderFor(dot, ring: ring),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The device's own position: an accent dot ringed in white with a soft glow.
class MyLocationDot extends StatelessWidget {
  const MyLocationDot({super.key});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: kBrandAccent,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: [
            BoxShadow(
              color: kBrandAccent.withValues(alpha: 0.5),
              blurRadius: 6,
              spreadRadius: 1,
            ),
          ],
        ),
      );
}
