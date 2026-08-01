import 'package:flutter_test/flutter_test.dart';

import 'package:drone_inspection_app/screens/li_tabs/home_tab.dart';
import 'package:drone_inspection_app/widgets/map_dots.dart';

/// Pulled back far enough, a transmission line's towers sit closer together than
/// the pins drawn for them, so the pins stop being markers and become a dotted
/// smear along a corridor the polyline already draws. Past that point the map
/// shows lines only.
///
/// The threshold is a geometric claim, not a taste one, so it is worth pinning:
/// at ~350 m tower spacing and this latitude, neighbouring towers are about 9 px
/// apart at zoom 12 and roughly half that at zoom 11 — against a 6 px pin.
void main() {
  group('showTowerPinsAt', () {
    test('hides pins across the overview zooms', () {
      // The whole-state opening camera, and the fitted-jurisdiction view a
      // supervisor lands on.
      expect(showTowerPinsAt(3), isFalse);
      expect(showTowerPinsAt(7), isFalse);
      expect(showTowerPinsAt(10), isFalse);
      // Where the pins would just begin to overlap.
      expect(showTowerPinsAt(11.9), isFalse);
    });

    test('shows pins from the threshold up to working zoom', () {
      expect(showTowerPinsAt(kTowerPinMinZoom), isTrue,
          reason: 'the boundary itself is inclusive');
      expect(showTowerPinsAt(13), isTrue);
      // The zoom Home opens at for a field engineer standing at a structure —
      // pins must never be hidden there.
      expect(showTowerPinsAt(17), isTrue);
      expect(showTowerPinsAt(19), isTrue);
    });

    test('the threshold sits inside the pin ramp, so pins fade in mid-size', () {
      // TowerPin ramps 6 px → 26 px between zoom 11 and 17. Appearing at 12
      // means they arrive already grown past the smallest speck, rather than
      // popping in at minimum size and looking like noise.
      final atThreshold = TowerPin.dotFor(kTowerPinMinZoom);
      expect(atThreshold, greaterThan(TowerPin.dotFor(11)),
          reason: 'pins should not appear at the very bottom of the ramp');
      expect(atThreshold, lessThan(TowerPin.dotFor(17)));
    });

    test('the hint zooms past the threshold, not onto it', () {
      // What the "Zoom in to see towers" pill targets. Landing exactly on the
      // boundary would show 9 px specks and read as a tap that barely worked.
      expect(showTowerPinsAt(kTowerPinMinZoom + 1), isTrue);
      expect(TowerPin.dotFor(kTowerPinMinZoom + 1),
          greaterThan(TowerPin.dotFor(kTowerPinMinZoom)));
    });
  });
}
