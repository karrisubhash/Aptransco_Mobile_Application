import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:drone_inspection_app/models/li_session.dart';
import 'package:drone_inspection_app/services/offline_credentials.dart';

/// Offline sign-in lets an inspector into the app with no signal, so its rules
/// are security rules and are worth stating as tests rather than as comments.
///
/// The shape of the guarantee: this class can only ever *replay* a decision the
/// backend already made about a password, on this device, recently, and slowly
/// enough that a found phone is not worth working through.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final creds = OfflineCredentials.instance;

  const session = LiSession(
    employeeId: '01019688',
    token: 'tok-from-online-login',
    displayName: 'Test Inspector',
    cadre: 'AEE',
    tier: 'field_user',
    subdivisionId: 4,
    subdivisionName: 'Kadapa',
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await creds.forget();
  });

  group('enrolment', () {
    test('an employee is not enrolled until an online sign-in says so',
        () async {
      expect(await creds.isEnrolled('01019688'), isFalse);

      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter2');

      expect(result.ok, isFalse);
      expect(result.failure, OfflineLoginFailure.notEnrolled);
    });

    test('remembering makes the same credentials work offline', () async {
      await creds.remember(
          employeeId: '01019688', password: 'hunter2', session: session);

      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter2');

      expect(result.ok, isTrue);
      expect(result.session!.employeeId, '01019688');
      // The token captured online is what the app carries afterwards, so a
      // reconnect can sync immediately instead of demanding another sign-in.
      expect(result.session!.token, 'tok-from-online-login');
      expect(result.session!.subdivisionId, 4);
    });

    test('the password itself is never written to disk', () async {
      const password = 'a-very-distinctive-password-9f3b';
      await creds.remember(
          employeeId: '01019688', password: password, session: session);

      final prefs = await SharedPreferences.getInstance();
      final dump = prefs
          .getKeys()
          .map((k) => '${prefs.get(k)}')
          .join('\n');

      expect(dump, isNot(contains(password)),
          reason: 'a recoverable credential must never reach storage');
      expect(dump, contains('salt'));
      expect(dump, contains('hash'));
    });

    test('each enrolment uses a fresh salt, so equal passwords differ on disk',
        () async {
      await creds.remember(
          employeeId: 'aaa', password: 'same-password', session: session);
      await creds.remember(
          employeeId: 'bbb', password: 'same-password', session: session);

      final prefs = await SharedPreferences.getInstance();
      final all = jsonDecode(
              prefs.getString('li_offline_credentials_v1') as String)
          as Map<String, dynamic>;

      final a = all['aaa'] as Map<String, dynamic>;
      final b = all['bbb'] as Map<String, dynamic>;
      expect(a['salt'], isNot(b['salt']));
      expect(a['hash'], isNot(b['hash']),
          reason: 'without a per-user salt, matching passwords are visible');
    });
  });

  group('verification', () {
    setUp(() async {
      await creds.remember(
          employeeId: '01019688', password: 'hunter2', session: session);
    });

    test('the wrong password is refused', () async {
      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter3');

      expect(result.ok, isFalse);
      expect(result.failure, OfflineLoginFailure.wrongPassword);
    });

    test('an empty password is refused', () async {
      final result = await creds.verify(employeeId: '01019688', password: '');

      expect(result.ok, isFalse);
    });

    test('a different employee id is not enrolled', () async {
      final result =
          await creds.verify(employeeId: '09999999', password: 'hunter2');

      expect(result.failure, OfflineLoginFailure.notEnrolled);
    });

    test('surrounding whitespace in the id still matches', () async {
      final result =
          await creds.verify(employeeId: '  01019688  ', password: 'hunter2');

      expect(result.ok, isTrue,
          reason: 'a stray space from a keyboard must not read as a new user');
    });
  });

  group('expiry', () {
    test('an enrolment older than the token it restores stops working',
        () async {
      await creds.remember(
          employeeId: '01019688', password: 'hunter2', session: session);

      // Age the record past the window, the way 31 days of no signal would.
      await _ageEnrolment('01019688', const Duration(days: 31));

      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter2');

      expect(result.ok, isFalse);
      expect(result.failure, OfflineLoginFailure.expired,
          reason: 'the restored token would be past its 30-day server life');
    });

    test('just inside the window still works', () async {
      await creds.remember(
          employeeId: '01019688', password: 'hunter2', session: session);
      await _ageEnrolment('01019688', const Duration(days: 29));

      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter2');

      expect(result.ok, isTrue);
    });
  });

  group('throttling a found phone', () {
    setUp(() async {
      await creds.remember(
          employeeId: '01019688', password: 'hunter2', session: session);
    });

    test('repeated wrong guesses earn a cooldown', () async {
      for (var i = 0; i < 5; i++) {
        await creds.verify(employeeId: '01019688', password: 'guess-$i');
      }

      final result =
          await creds.verify(employeeId: '01019688', password: 'guess-again');

      expect(result.failure, OfflineLoginFailure.lockedOut);
      expect(result.lockedUntil, isNotNull);
      expect(result.message, contains('Too many failed attempts'));
    });

    test('the cooldown blocks even the correct password', () async {
      for (var i = 0; i < 5; i++) {
        await creds.verify(employeeId: '01019688', password: 'guess-$i');
      }

      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter2');

      expect(result.ok, isFalse,
          reason: 'a lockout that the real password skips protects nothing');
      expect(result.failure, OfflineLoginFailure.lockedOut);
    });

    test('a success before the limit clears the count', () async {
      await creds.verify(employeeId: '01019688', password: 'wrong-1');
      await creds.verify(employeeId: '01019688', password: 'wrong-2');
      await creds.verify(employeeId: '01019688', password: 'hunter2');

      // Back to a full allowance: four more misses must not lock it.
      for (var i = 0; i < 4; i++) {
        await creds.verify(employeeId: '01019688', password: 'wrong-$i');
      }
      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter2');

      expect(result.ok, isTrue);
    });

    test('a fresh online sign-in forgives a lockout', () async {
      for (var i = 0; i < 5; i++) {
        await creds.verify(employeeId: '01019688', password: 'guess-$i');
      }
      expect(
          (await creds.verify(employeeId: '01019688', password: 'hunter2'))
              .failure,
          OfflineLoginFailure.lockedOut);

      // The backend vouching for them again outranks the device's suspicion.
      await creds.remember(
          employeeId: '01019688', password: 'hunter2', session: session);

      final result =
          await creds.verify(employeeId: '01019688', password: 'hunter2');
      expect(result.ok, isTrue);
    });
  });

  group('forgetting', () {
    test('forget drops one employee, leaving others enrolled', () async {
      await creds.remember(
          employeeId: 'aaa', password: 'pw-a', session: session);
      await creds.remember(
          employeeId: 'bbb', password: 'pw-b', session: session);

      await creds.forget('aaa');

      expect(await creds.isEnrolled('aaa'), isFalse);
      expect(await creds.isEnrolled('bbb'), isTrue);
    });

    test('a password change online re-enrols, retiring the old one', () async {
      await creds.remember(
          employeeId: '01019688', password: 'old-password', session: session);
      await creds.remember(
          employeeId: '01019688', password: 'new-password', session: session);

      expect(
          (await creds.verify(employeeId: '01019688', password: 'new-password'))
              .ok,
          isTrue);
      expect(
          (await creds.verify(employeeId: '01019688', password: 'old-password'))
              .ok,
          isFalse,
          reason: 'the superseded password must not keep working offline');
    });
  });
}

/// Backdate an enrolment's `verifiedAt` by [by], standing in for time passing.
Future<void> _ageEnrolment(String employeeId, Duration by) async {
  final prefs = await SharedPreferences.getInstance();
  final all = jsonDecode(prefs.getString('li_offline_credentials_v1') as String)
      as Map<String, dynamic>;
  final rec = (all[employeeId] as Map).cast<String, dynamic>();
  rec['verifiedAt'] =
      DateTime.now().subtract(by).millisecondsSinceEpoch;
  all[employeeId] = rec;
  await prefs.setString('li_offline_credentials_v1', jsonEncode(all));
}
