import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/li_session.dart';

/// Why an offline sign-in attempt did not produce a session.
enum OfflineLoginFailure {
  /// This device has never completed an online sign-in for that employee id.
  notEnrolled,

  /// Enrolled, but the password does not match.
  wrongPassword,

  /// The enrolment is older than [OfflineCredentials.maxAge] — the token it
  /// would restore is past the server's 30-day life, so it must be re-earned
  /// online.
  expired,

  /// Too many wrong attempts; locked until the returned time.
  lockedOut,
}

/// The outcome of [OfflineCredentials.verify].
class OfflineLoginResult {
  const OfflineLoginResult.success(this.session)
      : failure = null,
        lockedUntil = null;
  const OfflineLoginResult.failed(this.failure, {this.lockedUntil})
      : session = null;

  final LiSession? session;
  final OfflineLoginFailure? failure;
  final DateTime? lockedUntil;

  bool get ok => session != null;

  /// A message safe to put in front of the user.
  ///
  /// Deliberately does **not** distinguish "no such employee on this device"
  /// from "wrong password" in a way that helps someone probing a found phone:
  /// both point at the same remedy.
  String get message {
    switch (failure) {
      case OfflineLoginFailure.notEnrolled:
        return 'No internet, and this device has not signed in as that '
            'employee before. Connect once to sign in.';
      case OfflineLoginFailure.wrongPassword:
        return 'No internet, and that password does not match the one last '
            'used to sign in on this device.';
      case OfflineLoginFailure.expired:
        return 'No internet, and this device has not been online for more than '
            '30 days. Connect once to sign in again.';
      case OfflineLoginFailure.lockedOut:
        final until = lockedUntil;
        final mins = until == null
            ? 0
            : until.difference(DateTime.now()).inMinutes.clamp(0, 1 << 30);
        return 'Too many failed attempts. Try again in '
            '${mins <= 1 ? 'a minute' : '$mins minutes'}.';
      case null:
        return '';
    }
  }
}

/// Lets an inspector sign in with no signal, using credentials this device has
/// already verified against the backend at least once.
///
/// **The password is never stored.** Enrolment keeps a PBKDF2-HMAC-SHA256 hash
/// with a random per-employee salt, and sign-in re-derives and compares in
/// constant time. What is stored is the same shape of secret a server keeps, not
/// a recoverable credential.
///
/// The rules are chosen so this adds convenience without becoming a way in:
///  * **Enrolment requires a successful *online* sign-in.** The backend
///    (checkCred) stays the only thing that can ever say a password is correct
///    for the first time; this only replays a decision it already made.
///  * **A refusal from a reachable server never reaches this class.** The login
///    screen falls back here only on a transport failure, so a wrong password
///    typed while online fails online, as it should.
///  * **It expires.** After [maxAge] the enrolment stops working, because the
///    token it restores is past the server's own 30-day life — an offline
///    sign-in that outlives its token would just 401 on the first sync.
///  * **It throttles.** [_maxAttempts] wrong guesses buy a cooldown, so a found
///    phone cannot be worked through at speed.
///
/// Records survive sign-out on purpose: signing out clears the session and the
/// cached jurisdiction, but the same employee should still be able to get back
/// in at a tower with no signal. [forget] is the way to drop one deliberately.
class OfflineCredentials {
  OfflineCredentials._();
  static final OfflineCredentials instance = OfflineCredentials._();

  static const _prefsKey = 'li_offline_credentials_v1';

  /// PBKDF2 rounds. High enough to make guessing an extracted record expensive,
  /// low enough to sign in promptly on a low-end field handset — and stored per
  /// record, so this can be raised later without invalidating what exists.
  static const int _iterations = 100000;

  static const int _saltBytes = 16;
  static const int _keyBytes = 32;

  /// How long an enrolment stays usable without a successful online sign-in.
  /// Matched to the backend's mobile-token life.
  static const Duration maxAge = Duration(days: 30);

  /// Wrong attempts allowed before a cooldown.
  static const int _maxAttempts = 5;
  static const Duration _lockout = Duration(minutes: 15);

  final Random _random = Random.secure();

  /// Record a successful **online** sign-in so the same credentials work offline.
  ///
  /// Call this only after the backend has accepted [password]; it is what makes
  /// the offline path a replay of a real decision rather than a new authority.
  Future<void> remember({
    required String employeeId,
    required String password,
    required LiSession session,
  }) async {
    final id = _norm(employeeId);
    if (id.isEmpty || password.isEmpty) return;
    final salt = _newSalt();
    final hash = await _derive(password, salt, _iterations);
    final all = await _readAll();
    all[id] = <String, dynamic>{
      'salt': base64Encode(salt),
      'hash': base64Encode(hash),
      'iterations': _iterations,
      'verifiedAt': DateTime.now().millisecondsSinceEpoch,
      'session': session.toJson(),
      // A fresh online sign-in is also the moment to forgive past fumbling.
      'failures': 0,
      'lockedUntil': null,
    };
    await _writeAll(all);
  }

  /// Whether [employeeId] can attempt an offline sign-in on this device.
  Future<bool> isEnrolled(String employeeId) async =>
      (await _readAll())[_norm(employeeId)] != null;

  /// Check [password] against the stored enrolment for [employeeId] and, on a
  /// match, hand back the session captured at that last online sign-in.
  Future<OfflineLoginResult> verify({
    required String employeeId,
    required String password,
  }) async {
    final id = _norm(employeeId);
    final all = await _readAll();
    final rec = all[id];
    if (rec == null) {
      return const OfflineLoginResult.failed(OfflineLoginFailure.notEnrolled);
    }

    final lockedUntilMs = rec['lockedUntil'] as int?;
    if (lockedUntilMs != null) {
      final until = DateTime.fromMillisecondsSinceEpoch(lockedUntilMs);
      if (DateTime.now().isBefore(until)) {
        return OfflineLoginResult.failed(OfflineLoginFailure.lockedOut,
            lockedUntil: until);
      }
    }

    final verifiedAtMs = rec['verifiedAt'] as int? ?? 0;
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(verifiedAtMs));
    if (age > maxAge) {
      return const OfflineLoginResult.failed(OfflineLoginFailure.expired);
    }

    final salt = base64Decode(rec['salt'] as String? ?? '');
    final expected = base64Decode(rec['hash'] as String? ?? '');
    final iterations = rec['iterations'] as int? ?? _iterations;
    if (salt.isEmpty || expected.isEmpty) {
      return const OfflineLoginResult.failed(OfflineLoginFailure.notEnrolled);
    }

    final actual = await _derive(password, salt, iterations);
    if (!_constantTimeEquals(actual, expected)) {
      // Count it, and start a cooldown once the allowance is spent.
      final failures = (rec['failures'] as int? ?? 0) + 1;
      rec['failures'] = failures;
      if (failures >= _maxAttempts) {
        rec['lockedUntil'] =
            DateTime.now().add(_lockout).millisecondsSinceEpoch;
        rec['failures'] = 0;
      }
      all[id] = rec;
      await _writeAll(all);
      return const OfflineLoginResult.failed(OfflineLoginFailure.wrongPassword);
    }

    rec['failures'] = 0;
    rec['lockedUntil'] = null;
    all[id] = rec;
    await _writeAll(all);

    try {
      final session =
          LiSession.fromJson((rec['session'] as Map).cast<String, dynamic>());
      return OfflineLoginResult.success(session);
    } catch (_) {
      // A record written by an older build that no longer parses is not a
      // credential we can honour.
      return const OfflineLoginResult.failed(OfflineLoginFailure.notEnrolled);
    }
  }

  /// Drop the enrolment for [employeeId] (or all of them when null).
  Future<void> forget([String? employeeId]) async {
    if (employeeId == null) {
      await _writeAll({});
      return;
    }
    final all = await _readAll();
    all.remove(_norm(employeeId));
    await _writeAll(all);
  }

  // ---- storage -------------------------------------------------------------

  Future<Map<String, dynamic>> _readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_prefsKey);
      if (raw == null) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, dynamic>{};
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<void> _writeAll(Map<String, dynamic> all) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, jsonEncode(all));
    } catch (_) {/* best effort */}
  }

  // ---- crypto --------------------------------------------------------------

  Uint8List _newSalt() {
    final b = Uint8List(_saltBytes);
    for (var i = 0; i < b.length; i++) {
      b[i] = _random.nextInt(256);
    }
    return b;
  }

  /// Derive the key off the UI thread — 100k HMAC rounds is long enough to drop
  /// frames on a low-end handset, and sign-in is exactly when the app should
  /// look composed.
  Future<Uint8List> _derive(
          String password, List<int> salt, int iterations) async =>
      compute(_pbkdf2, <String, dynamic>{
        'password': password,
        'salt': Uint8List.fromList(salt),
        'iterations': iterations,
        'length': _keyBytes,
      });

  static String _norm(String employeeId) => employeeId.trim();

  /// Compare without an early exit, so the time taken says nothing about how
  /// much of the hash matched.
  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// PBKDF2-HMAC-SHA256. Top-level so it can run in a background isolate via
/// [compute].
Uint8List _pbkdf2(Map<String, dynamic> args) {
  final password = utf8.encode(args['password'] as String);
  final salt = args['salt'] as Uint8List;
  final iterations = args['iterations'] as int;
  final length = args['length'] as int;

  final hmac = Hmac(sha256, password);
  const hLen = 32;
  final blocks = (length + hLen - 1) ~/ hLen;
  final out = Uint8List(blocks * hLen);

  for (var block = 1; block <= blocks; block++) {
    // U1 = HMAC(P, S || INT_BE32(block))
    final input = Uint8List(salt.length + 4)
      ..setRange(0, salt.length, salt)
      ..[salt.length] = (block >> 24) & 0xff
      ..[salt.length + 1] = (block >> 16) & 0xff
      ..[salt.length + 2] = (block >> 8) & 0xff
      ..[salt.length + 3] = block & 0xff;

    var u = Uint8List.fromList(hmac.convert(input).bytes);
    final t = Uint8List.fromList(u);
    for (var i = 1; i < iterations; i++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var j = 0; j < hLen; j++) {
        t[j] ^= u[j];
      }
    }
    out.setRange((block - 1) * hLen, block * hLen, t);
  }
  return Uint8List.sublistView(out, 0, length);
}
