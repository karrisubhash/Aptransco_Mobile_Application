import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../models/inspection_catalog.dart';
import '../models/li_asset.dart';
import '../screens/line_inspection_form_screen.dart';
import '../services/line_inspection_api.dart';
import '../services/location_service.dart';
import '../utils/li_style.dart';

/// Towers within this radius are "in range" and open the form directly.
const double kPresenceRadiusM = 50;

/// Opens the tower-inspection form behind the presence gate. Home is the single
/// entry point — a tower tapped on the map or picked from the nearest-towers
/// sheet lands here.
///
/// Being physically at the tower is the utmost criterion, so the gate is
/// enforced before the form appears: towers within [kPresenceRadiusM] open
/// directly, anything else needs an audited override with a mandatory reason —
/// field GPS drifts, so the override keeps work unblocked while flagging it for
/// oversight.
///
/// Pass [fix]/[accuracyM] when the caller already tracks live position — Home
/// streams it to rank the nearest towers, so the gate reuses that fix rather
/// than waiting on a fresh one. Without it a one-shot fix is taken here. GPS
/// works with no mobile data, so this whole path is offline-capable once the
/// jurisdiction has been downloaded.
///
/// Returns true once the form has been opened and closed, so the caller can
/// refresh its criticality colours.
Future<bool> launchInspection(
  BuildContext context, {
  required LiTower tower,
  required String inspectorEmployeeId,
  LatLng? fix,
  double? accuracyM,
}) async {
  // Jurisdiction before anything else: a tower can be visible for oversight yet
  // outside this inspector's capture scope, and the server refuses that save.
  // Refuse here — before the GPS fix, before the checklist — so the work is
  // never done twice, rather than letting it queue and fail at sync time.
  if (!tower.canInspect) {
    await showNoJurisdictionDialog(context, tower: tower);
    return false;
  }

  var me = fix;
  var accuracy = accuracyM;
  String? gpsError;

  if (me == null) {
    final result = await showDialog<_PresenceFix>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _PresenceFixDialog(),
    );
    if (!context.mounted) return false;
    me = result?.fix;
    accuracy = result?.accuracy;
    gpsError = result?.error;
  }

  final double? distance =
      (me != null && tower.latitude != null && tower.longitude != null)
          ? LocationService.distanceTo(me, tower.latitude!, tower.longitude!)
          : null;
  final inRange = distance != null && distance <= kPresenceRadiusM;

  final String presenceFlag;
  var overrideReason = '';
  if (inRange) {
    presenceFlag = 'in_range';
  } else {
    presenceFlag = me == null ? 'no_fix' : 'out_of_range';
    final reason = await askPresenceOverride(
      context,
      flag: presenceFlag,
      distance: distance,
      gpsError: gpsError,
    );
    if (reason == null || !context.mounted) return false; // cancelled
    overrideReason = reason;
  }

  try {
    final InspectionCatalog catalog = await LineInspectionApi.loadCatalog();
    if (!context.mounted) return false;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => LineInspectionFormScreen(
        tower: tower,
        catalog: catalog,
        inspectorEmployeeId: inspectorEmployeeId,
        inspectorLat: me?.latitude,
        inspectorLng: me?.longitude,
        gpsAccuracyM: accuracy,
        presenceFlag: presenceFlag,
        overrideReason: overrideReason,
      ),
    ));
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not open form: $e')));
    }
    return false;
  }
}

/// Explains why a tower that is plainly visible on the map cannot be inspected.
///
/// This is a jurisdiction gap, not a fault the inspector can clear themselves:
/// they can see the tower because oversight is scoped to their reporting subtree,
/// but recording an inspection needs an assignment of their own. Says who can fix
/// it rather than just refusing.
Future<void> showNoJurisdictionDialog(
  BuildContext context, {
  required LiTower tower,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Not your tower to inspect'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Tower ${tower.towerNumber}'
            '${tower.lineName.isEmpty ? '' : ' on ${tower.lineName}'}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'You can view this tower, but it is not in your inspection '
            'assignment, so the server will not accept an inspection for it.',
            style: TextStyle(fontSize: 13, color: kInkSoft),
          ),
          const SizedBox(height: 8),
          const Text(
            'Ask your EE to assign you this line, or the tower range covering '
            'it, then reopen the app.',
            style: TextStyle(fontSize: 13, color: kInkSoft),
          ),
        ],
      ),
      actions: [
        FilledButton(
            onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
      ],
    ),
  );
}

/// The audited-override dialog: requires a non-empty reason before an
/// out-of-range / no-fix inspection can proceed.
Future<String?> askPresenceOverride(
  BuildContext context, {
  required String flag,
  double? distance,
  String? gpsError,
}) {
  final headline = flag == 'no_fix'
      ? (gpsError ?? 'No GPS fix available')
      : distance == null
          ? 'This tower has no recorded location'
          : 'You are ${distance.round()} m from this tower';
  return showDialog<String>(
    context: context,
    builder: (_) => _PresenceOverrideDialog(headline: headline),
  );
}

/// The reason field is owned by a widget rather than by [askPresenceOverride]
/// so its controller lives exactly as long as the dialog does.
///
/// Disposing it as soon as `showDialog` resolved looked tidy but crashed: the
/// route stays mounted for its exit transition, so the TextField rebuilt against
/// an already-disposed controller and the inspector got the red error screen —
/// on Cancel, which is the routine "wrong tower, walk closer first" path. A
/// State's `dispose` runs only once the route is gone, which is the whole point.
class _PresenceOverrideDialog extends StatefulWidget {
  const _PresenceOverrideDialog({required this.headline});

  final String headline;

  @override
  State<_PresenceOverrideDialog> createState() =>
      _PresenceOverrideDialogState();
}

class _PresenceOverrideDialogState extends State<_PresenceOverrideDialog> {
  final _ctl = TextEditingController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _continue() {
    final r = _ctl.text.trim();
    if (r.isEmpty) return; // reason is mandatory
    Navigator.pop(context, r);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Presence check'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.headline,
              style: TextStyle(
                  fontWeight: FontWeight.w700, color: kCritColor['major'])),
          const SizedBox(height: 8),
          Text(
            'Inspection is meant to be done at the tower (within '
            '${kPresenceRadiusM.round()} m). You can continue, but the reason '
            'is recorded and the inspection is flagged for review.',
            style: const TextStyle(fontSize: 13, color: kInkSoft),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ctl,
            autofocus: true,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Reason (required)',
              hintText:
                  'e.g. GPS not locking under the tower; inspected on site',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(
          onPressed: _continue,
          child: const Text('Continue'),
        ),
      ],
    );
  }
}

/// The outcome of a one-shot presence fix: a position, or the user-facing
/// reason there isn't one (which becomes the `no_fix` case).
class _PresenceFix {
  const _PresenceFix({this.fix, this.accuracy, this.error});
  final LatLng? fix;
  final double? accuracy;
  final String? error;
}

/// Blocking "getting your location" dialog that takes the fix itself and pops
/// with the result, so callers just await [showDialog].
class _PresenceFixDialog extends StatefulWidget {
  const _PresenceFixDialog();

  @override
  State<_PresenceFixDialog> createState() => _PresenceFixDialogState();
}

class _PresenceFixDialogState extends State<_PresenceFixDialog> {
  /// Whether this dialog has already popped. A route stays `mounted` for the
  /// duration of its exit transition, so without this a fix that lands just
  /// after "Skip GPS" would pop a *second* route — taking Home with it.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _locate();
  }

  void _finish(_PresenceFix result) {
    if (_done || !mounted) return;
    _done = true;
    Navigator.of(context).pop(result);
  }

  Future<void> _locate() async {
    _PresenceFix result;
    try {
      final pos = await LocationService.currentFix();
      result = _PresenceFix(
        fix: LatLng(pos.latitude, pos.longitude),
        accuracy: pos.accuracy,
      );
    } on LocationUnavailable catch (e) {
      result = _PresenceFix(error: e.message);
    } catch (e) {
      result = _PresenceFix(error: '$e');
    }
    _finish(result);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      content: const Row(children: [
        SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
        SizedBox(width: 16),
        Expanded(
          child: Text(
            'Confirming you are at the tower…',
            style: TextStyle(fontSize: 13.5, color: kInkSoft),
          ),
        ),
      ]),
      // The barrier is deliberately not dismissible, so without this the
      // inspector had no way out at all if the platform never returned a fix —
      // the tower simply could not be inspected. Skipping resolves as the
      // `no_fix` case, which is the audited-override path.
      actions: [
        TextButton(
          onPressed: () =>
              _finish(const _PresenceFix(error: 'Waiting for GPS was skipped')),
          child: const Text('Skip GPS'),
        ),
      ],
    );
  }
}
