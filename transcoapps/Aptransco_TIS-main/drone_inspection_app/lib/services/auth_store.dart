import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/li_session.dart';
import 'offline/local_store.dart';

/// Holds the signed-in session + mobile auth token for the line-inspection
/// backend. The token is minted by `POST /auth/login/` (checkCred-verified) and
/// sent as `Authorization: Token <token>` on every request. Loaded once from
/// SharedPreferences at startup (see main.dart) and kept in memory so the API
/// layer can read it synchronously on each call.
class AuthStore {
  AuthStore._();
  static final AuthStore instance = AuthStore._();

  static const _sessionKey = 'li_session_v1';

  LiSession? _session;

  LiSession? get session => _session;
  String? get token => _session?.token;
  bool get isLoggedIn => (_session?.token ?? '').isNotEmpty;

  /// Set once the backend has rejected the stored token (a 401 from any call).
  ///
  /// Mobile tokens are valid for 30 days and are revoked on sign-out, so this
  /// state is reached by every long-lived install eventually. It used to be
  /// invisible: [UnauthorizedException] was raised and then caught by nobody, so
  /// each tab quietly showed "Session expired" as its error text (or kept showing
  /// cached data) with no hint that signing in again was the fix, while the sync
  /// queue burned an attempt per pass on work it could never upload.
  ///
  /// Deliberately a signal rather than a forced sign-out: an inspector may be
  /// mid-checklist at a tower, and tearing the navigation stack down under them
  /// would discard work they walked there to capture. Saving keeps working — the
  /// write path is offline-first — and the queue drains itself once they sign in.
  final ValueNotifier<bool> sessionExpired = ValueNotifier<bool>(false);

  /// Record that the token was refused. Ignored when already signed out, so a
  /// stray 401 on a public endpoint cannot raise the banner for nobody.
  void markSessionExpired() {
    if (!isLoggedIn) return;
    sessionExpired.value = true;
  }

  /// Auth header map to merge into every request, or empty when signed out.
  Map<String, String> authHeaders() {
    final t = token;
    return (t == null || t.isEmpty) ? const {} : {'Authorization': 'Token $t'};
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_sessionKey);
      if (saved != null) {
        _session = LiSession.fromJson(jsonDecode(saved) as Map<String, dynamic>);
      }
    } catch (_) {/* no session → signed out */}
  }

  /// Persist [session] — first wiping the on-device data of whoever was signed
  /// in, when this is a *different* employee.
  ///
  /// The wipe belongs here rather than in the login screen because this is the
  /// one funnel every sign-in goes through, and the failure it prevents is
  /// showing one employee another's jurisdiction. Sign-out already clears
  /// ([clear]), but relying on that alone leaves the real cases uncovered: the
  /// app force-killed instead of signed out, a session left behind by a crash,
  /// or simply a second person signing in on a shared field device. Any of those
  /// and [LocalStore]'s per-resource cache keys answer the new session with the
  /// old one's lines, towers, tickets and KPIs — and because master data is held
  /// for [LineInspectionApi.freshMaster], the network is not even consulted to
  /// correct it.
  ///
  /// A [copyWith] update for the *same* employee (the scope picker) must not
  /// purge, so this compares ids rather than whole sessions.
  Future<void> save(LiSession session) async {
    final previous = _session?.employeeId ?? '';
    if (previous.isNotEmpty && previous != session.employeeId) {
      await LocalStore.instance.purgeUserData();
    }
    _session = session;
    // A fresh token clears the refusal, so the banner drops and the queue is
    // allowed to drain again.
    sessionExpired.value = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, jsonEncode(session.toJson()));
    } catch (_) {/* best effort */}
  }

  /// Sign out: forget the session and drop everything cached under it, so
  /// whoever signs in next starts from the server rather than from this
  /// employee's data.
  Future<void> clear() async {
    _session = null;
    sessionExpired.value = false;
    await LocalStore.instance.purgeUserData();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey);
    } catch (_) {/* best effort */}
  }
}
