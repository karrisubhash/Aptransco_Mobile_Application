import 'package:flutter/material.dart';

/// Shared visual language for the line-inspection platform.
///
/// Two layers live here:
///  1. **Semantic status tokens** — criticality colours / labels and the
///     status pills, so every tab reads defects and tickets consistently.
///  2. **Design-system tokens** — the brand palette, spacing / radius scale,
///     elevation shadows and the brand gradient that [buildLiTheme] and the
///     screens draw from, so the whole product feels like one system.
///
/// (Criticality palette is from the POC's validated colours.)

// ---------------------------------------------------------------------------
// Criticality — semantic status colours
// ---------------------------------------------------------------------------

const Map<String, Color> kCritColor = {
  'ok': Color(0xFF12A150),
  'minor': Color(0xFFE8A100),
  'major': Color(0xFFEC7A38),
  'critical': Color(0xFFDA3838),
  'none': Color(0xFF8A8F99),
};

const Map<String, String> kCritLabel = {
  'ok': 'Normal',
  'minor': 'Minor',
  'major': 'Major',
  'critical': 'Critical',
  'none': 'Not inspected',
};

const Map<String, int> kCritOrder = {
  'none': 0,
  'ok': 1,
  'minor': 2,
  'major': 3,
  'critical': 4,
};

Color critColor(String c) => kCritColor[c] ?? kCritColor['none']!;
String critLabel(String c) => kCritLabel[c] ?? c;

String worstOf(Iterable<String> crits) {
  var worst = 'ok';
  for (final c in crits) {
    if ((kCritOrder[c] ?? 0) > (kCritOrder[worst] ?? 0)) worst = c;
  }
  return worst;
}

// ---------------------------------------------------------------------------
// Inspection state — what a tower pin encodes on the map
// ---------------------------------------------------------------------------

/// Where a tower stands in the inspection cycle, as the map draws it.
///
/// The pins answer the question an engineer actually walks a line with — which
/// structures are still outstanding, and which of the ones they did are still
/// sitting on this phone. So pin colour encodes coverage and sync, not severity:
/// criticality keeps its own palette above ([kCritColor]) and still labels the
/// tower sheet, History and tickets, where there is room for a word beside the
/// colour.
enum TowerState {
  /// Nothing on record for this tower.
  notInspected,

  /// Inspected on this device, but the record is still in the offline outbox —
  /// nobody upstream can see it yet.
  awaitingSync,

  /// Inspected, and the record has reached the server.
  inspected,
}

/// Grey → orange → green, in cycle order.
///
/// The values are the same grey, orange and green the criticality palette uses
/// for `none` / `major` / `ok`, written out as literals because a const map
/// cannot be built from another map's lookup.
const Map<TowerState, Color> kTowerStateColor = {
  TowerState.notInspected: Color(0xFF8A8F99),
  TowerState.awaitingSync: Color(0xFFEC7A38),
  TowerState.inspected: Color(0xFF12A150),
};

/// Legend / sheet wording. Colour is never the only channel.
const Map<TowerState, String> kTowerStateLabel = {
  TowerState.notInspected: 'Not inspected',
  TowerState.awaitingSync: 'Inspected — waiting to sync',
  TowerState.inspected: 'Inspected',
};

Color towerStateColor(TowerState s) => kTowerStateColor[s]!;
String towerStateLabel(TowerState s) => kTowerStateLabel[s]!;

// ---------------------------------------------------------------------------
// Brand palette
// ---------------------------------------------------------------------------

/// Deep corporate navy — the primary brand colour (app bars, buttons). A
/// muted, serious navy (kept in the AP TRANSCO blue family to sit with the
/// blue logo) rather than a bright primary blue.
const Color kBrandPrimary = Color(0xFF14243D);

/// A darker shade for gradient depth and pressed states.
const Color kBrandPrimaryDark = Color(0xFF0B1526);

/// A restrained steel-blue accent used for meters, links and highlights.
const Color kBrandAccent = Color(0xFF3D6AA6);

// Kept for backwards compatibility with existing screens that reference the
// POC blue tokens directly. They now map onto the brand palette.
const Color kBlue = kBrandAccent;
const Color kBlue600 = kBrandPrimary;
const Color kBlue100 = Color(0xFFDCEAFB);

// Neutrals — a cool, calm greyscale for text, surfaces and hairlines.
const Color kInk = Color(0xFF16202E); // primary text
const Color kInkSoft = Color(0xFF5A6675); // secondary text
const Color kInkFaint = Color(0xFF8A93A3); // tertiary / hints
const Color kSurface = Color(0xFFF4F7FB); // scaffold background
const Color kCardBg = Color(0xFFFFFFFF); // cards / sheets
const Color kOutline = Color(0xFFE2E8F1); // hairlines / borders

// ---------------------------------------------------------------------------
// Voltage — the map's line corridors
// ---------------------------------------------------------------------------

/// Stroke colour per voltage class, for the corridor polylines on the map.
///
/// Deliberately confined to the blue→violet→plum range, which neither the
/// criticality nor the [TowerState] palette above uses: on the map inspection
/// state already owns colour (it is the encoding that changes as the engineer
/// works), so a voltage hue must never be mistakable for a tower's own colour.
/// That rules out the web dashboard's
/// 400 kV red (`#c0392b`, `dashboard_map.html`) — four points from
/// `kCritColor['critical']` and unreadable next to it. 132 kV and 220 kV keep
/// the dashboard's blue and violet, so the two products still agree where they
/// safely can.
///
/// Voltage is encoded twice, by hue *and* by [kVoltageStroke] width, so the
/// classes stay distinguishable for colour-blind users and on washed-out
/// satellite imagery.
const Map<String, Color> kVoltageColor = {
  '132kV': Color(0xFF2A78D6),
  '220kV': Color(0xFF7A3FB0),
  '400kV': Color(0xFFB02A7A),
};

/// Core stroke width per voltage — the second, redundant voltage channel.
const Map<String, double> kVoltageStroke = {
  '132kV': 2.0,
  '220kV': 2.6,
  '400kV': 3.2,
};

/// Fallback for a line whose voltage is missing or outside the known classes.
const Color kVoltageColorUnknown = kInkFaint;
const double kVoltageStrokeUnknown = 2.0;

/// A dark casing drawn under every corridor stroke. Satellite imagery is the
/// hard case — a thin saturated line over bright fields or water disappears —
/// so each corridor carries its own contrast rather than relying on the
/// basemap. flutter_map punches the core out of the casing (`BlendMode.dstOut`),
/// so a translucent casing never muddies the colour on top of it.
const Color kCorridorCasing = kBrandPrimaryDark;
const double kCorridorCasingAlpha = 0.45;
const double kCorridorCasingWidth = 2.4;

Color voltageColor(String v) => kVoltageColor[v] ?? kVoltageColorUnknown;
double voltageStroke(String v) => kVoltageStroke[v] ?? kVoltageStrokeUnknown;

// ---------------------------------------------------------------------------
// Spacing & radius scale
// ---------------------------------------------------------------------------

const double kSpaceXs = 4;
const double kSpaceSm = 8;
const double kSpaceMd = 12;
const double kSpaceLg = 16;
const double kSpaceXl = 24;

const double kRadiusSm = 10;
const double kRadiusMd = 14;
const double kRadiusLg = 18;
const double kRadiusXl = 24;
const double kRadiusPill = 999;

// ---------------------------------------------------------------------------
// Elevation & gradient
// ---------------------------------------------------------------------------

/// A soft, low card shadow — enough to lift a surface without a heavy drop.
List<BoxShadow> get kShadowSoft => [
      BoxShadow(
        color: kBrandPrimaryDark.withValues(alpha: 0.06),
        blurRadius: 14,
        offset: const Offset(0, 4),
      ),
    ];

/// A slightly stronger shadow for floating elements (search bars, menus).
List<BoxShadow> get kShadowFloating => [
      BoxShadow(
        color: kBrandPrimaryDark.withValues(alpha: 0.12),
        blurRadius: 20,
        offset: const Offset(0, 8),
      ),
    ];

/// The dark brand gradient. Currently applied nowhere — the app bar is white
/// ([kCardBg]) and sign-in sits on the light [kSurface] — kept as the brand's
/// dark treatment for any surface that wants it.
const LinearGradient kBrandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [kBrandPrimary, kBrandPrimaryDark],
);

// ---------------------------------------------------------------------------
// Brand marks
// ---------------------------------------------------------------------------

/// The AP TRANSCO transmission-tower mark (no wordmark), on a transparent
/// background — for compact placements like the app-bar badge.
const String kLogoMark = 'assets/branding/logo_mark.png';

/// The full AP TRANSCO logo with wordmark, transparent — for the auth hero.
const String kLogoFull = 'assets/branding/logo_full.png';

/// A white, rounded "app badge" holding the brand tower mark. Reads crisply on
/// the dark brand gradient (app bar, hero) and matches the launcher icon, so
/// the product feels branded end to end.
Widget liBrandBadge({double size = 40, double radius = kRadiusSm}) {
  return Container(
    width: size,
    height: size,
    padding: EdgeInsets.all(size * 0.15),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(radius),
      boxShadow: [
        BoxShadow(
          color: kBrandPrimaryDark.withValues(alpha: 0.28),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
    ),
    child: Image.asset(kLogoMark, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
  );
}

// ---------------------------------------------------------------------------
// Shared components
// ---------------------------------------------------------------------------

/// A small criticality pill: coloured dot + label (never colour alone).
Widget critChip(String crit, {String? text}) {
  final color = critColor(crit);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(kRadiusPill),
      border: Border.all(color: color.withValues(alpha: 0.45)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        // Flexible so the pill degrades gracefully when a caller hands it a
        // tight width (e.g. inside an Expanded next to a wide button) instead
        // of overflowing. Unconstrained, it still sizes to its label.
        Flexible(
          child: Text(
            text ?? critLabel(crit),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: kInk,
              letterSpacing: 0.1,
            ),
          ),
        ),
      ],
    ),
  );
}

/// A status pill for tickets / requests (open vs closed/resolved).
Widget statusPill(String status) {
  final open = status == 'open';
  final color = open ? kCritColor['major']! : kCritColor['ok']!;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(kRadiusPill),
      border: Border.all(color: color.withValues(alpha: 0.55)),
    ),
    child: Text(
      status.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.6,
        color: color,
      ),
    ),
  );
}

/// A consistent section header: leading icon, title and an optional count
/// badge / trailing widget. Used across the tabs so every list section reads
/// the same.
Widget liSectionHeader(
  IconData icon,
  String title, {
  int? count,
  Widget? trailing,
}) {
  return Row(
    children: [
      Icon(icon, size: 18, color: kBrandAccent),
      const SizedBox(width: kSpaceSm),
      // Flexible + ellipsis so a long title yields to the count badge and
      // trailing widget instead of overflowing. Titles that already fit are
      // laid out identically (loose fit takes only what it needs).
      Flexible(
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w700,
            color: kInk,
            letterSpacing: 0.1,
          ),
        ),
      ),
      if (count != null) ...[
        const SizedBox(width: kSpaceSm),
        liCountBadge(count),
      ],
      if (trailing != null) ...[const Spacer(), trailing],
    ],
  );
}

/// A small pill showing a count next to a section header.
Widget liCountBadge(int count) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
    decoration: BoxDecoration(
      color: kBrandAccent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(kRadiusPill),
    ),
    child: Text(
      '$count',
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: kBrandPrimary,
      ),
    ),
  );
}

/// A centred empty / hint state: soft icon in a tinted disc, a title and an
/// optional supporting line.
Widget liEmptyState(
  IconData icon,
  String title, {
  String? subtitle,
}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: kBrandAccent.withValues(alpha: 0.08),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 36, color: kBrandAccent),
          ),
          const SizedBox(height: kSpaceLg),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: kInk,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: kSpaceXs + 2),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: kInkSoft, height: 1.4),
            ),
          ],
        ],
      ),
    ),
  );
}

/// A branded full-area loading state: the AP TRANSCO mark inside a slim
/// progress ring, with an optional caption. Used in place of a bare spinner so
/// waits feel like part of the product.
Widget liLoading({String? message}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 60,
            height: 60,
            child: Stack(
              alignment: Alignment.center,
              children: [
                const SizedBox(
                  width: 60,
                  height: 60,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.6,
                    color: kBrandAccent,
                    backgroundColor: kOutline,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(15),
                  child: Image.asset(kLogoMark, fit: BoxFit.contain),
                ),
              ],
            ),
          ),
          if (message != null) ...[
            const SizedBox(height: kSpaceLg),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: kInkSoft),
            ),
          ],
        ],
      ),
    ),
  );
}

/// A consistent error state: a tinted alert disc, a title, the detail line and
/// an optional retry action — so every failure across the tabs reads the same.
Widget liErrorState(String message, {VoidCallback? onRetry, String? title}) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: kCritColor['critical']!.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.cloud_off_rounded,
                size: 34, color: kCritColor['critical']),
          ),
          const SizedBox(height: kSpaceLg),
          Text(
            title ?? 'Something went wrong',
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: kInk),
          ),
          const SizedBox(height: kSpaceXs + 2),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: kInkSoft, height: 1.4),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: kSpaceLg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    ),
  );
}

/// Renders a follow-up answers map as "v1 · v2 · v3".
String answersText(Map<String, dynamic> answers) => answers.values
    .map((v) => v is List ? v.join(', ') : v.toString())
    .join(' · ');
