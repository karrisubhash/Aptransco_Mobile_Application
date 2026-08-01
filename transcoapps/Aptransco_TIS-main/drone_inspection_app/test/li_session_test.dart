import 'package:drone_inspection_app/models/li_session.dart';
import 'package:flutter_test/flutter_test.dart';

/// How Home frames the map on open is a per-cadre rule, and getting it wrong is
/// invisible in code review but obvious in the field — a supervisor pinned to one
/// structure cannot see the lines they are responsible for. So the rule is tested
/// directly against every cadre label the backend can send.

LiSession _session({
  String cadre = '',
  String tier = '',
  bool isAdmin = false,
  bool isManagement = false,
}) =>
    LiSession(
      employeeId: 'E1',
      token: 't',
      cadre: cadre,
      tier: tier,
      isAdmin: isAdmin,
      isManagement: isManagement,
    );

void main() {
  group('opensAtNearestTower', () {
    test('AEE and EE open at the tower nearest them', () {
      for (final cadre in ['AEE', 'EE']) {
        expect(_session(cadre: cadre).opensAtNearestTower, isTrue,
            reason: '$cadre works at a single structure');
      }
    });

    test('DEE and SE open on their lines', () {
      for (final cadre in ['DEE', 'SE']) {
        expect(_session(cadre: cadre).opensAtNearestTower, isFalse,
            reason: '$cadre supervises whole lines');
      }
    });

    test('DEE is not caught by the AEE rule', () {
      // `viewing.CADRE_LABELS` maps the raw code 'ADE/AEE' onto the label 'DEE',
      // so a substring test against 'AEE' would silently misroute every DEE.
      expect(_session(cadre: 'DEE').opensAtNearestTower, isFalse);
      expect(_session(cadre: 'ADE/AEE').opensAtNearestTower, isFalse);
    });

    test('admins open on their lines whatever their cadre says', () {
      expect(_session(cadre: 'AEE', isAdmin: true).opensAtNearestTower, isFalse);
      expect(_session(cadre: 'EE', isAdmin: true).opensAtNearestTower, isFalse);
    });

    test('top-cadre management opens on their lines', () {
      expect(_session(cadre: 'EE', isManagement: true).opensAtNearestTower, isFalse);
      for (final cadre in ['CE', 'Director', 'GM', 'JMD', 'CMD']) {
        expect(_session(cadre: cadre).opensAtNearestTower, isFalse);
      }
    });

    test('an unknown or missing cadre falls back to the overview', () {
      expect(_session().opensAtNearestTower, isFalse);
      expect(_session(cadre: '   ').opensAtNearestTower, isFalse);
      expect(_session(cadre: 'SOMETHING_NEW').opensAtNearestTower, isFalse);
    });

    test('matching is case- and whitespace-insensitive', () {
      expect(_session(cadre: ' aee ').opensAtNearestTower, isTrue);
      expect(_session(cadre: 'ee').opensAtNearestTower, isTrue);
    });

    test('tier no longer decides the framing', () {
      // The old rule was `tier == 'field_user'`. It split cadres the wrong way:
      // an EE with subordinates reads as 'supervisor', and a DEE holding only
      // their own assignment reads as 'field_user'.
      expect(_session(cadre: 'EE', tier: 'supervisor').opensAtNearestTower, isTrue);
      expect(_session(cadre: 'DEE', tier: 'field_user').opensAtNearestTower, isFalse);
    });
  });

  group('session plumbing the rule depends on', () {
    test('cadre survives a JSON round trip', () {
      final restored = LiSession.fromJson(_session(cadre: 'EE').toJson());
      expect(restored.cadre, 'EE');
      expect(restored.opensAtNearestTower, isTrue);
    });

    test('a login response without a cadre yields the overview', () {
      final s = LiSession.fromLogin(const {'employee_id': 'E1'}, token: 't');
      expect(s.cadre, isEmpty);
      expect(s.opensAtNearestTower, isFalse);
    });

    test('copyWith keeps the cadre', () {
      final s = _session(cadre: 'AEE').copyWith(subdivisionId: 4);
      expect(s.opensAtNearestTower, isTrue);
    });
  });
}
