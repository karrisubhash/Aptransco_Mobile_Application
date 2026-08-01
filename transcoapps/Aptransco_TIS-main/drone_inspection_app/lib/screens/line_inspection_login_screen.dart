import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/li_session.dart';
import '../services/auth_store.dart';
import '../services/line_inspection_api.dart';
import '../services/offline_credentials.dart';
import '../services/offline/connectivity_service.dart';
import '../services/offline/sync_engine.dart';
import '../utils/li_style.dart';
import 'line_inspection_hub_screen.dart';

/// Real sign-in for the line-inspection platform: employee ID + password are
/// verified by the backend (`POST /auth/login/`, which calls APTRANSCO's
/// checkCred gateway). On success a DB-backed token is issued and stored; every
/// subsequent request carries it, and the server scopes all data to the
/// employee's jurisdiction. Replaces the old free-text/role picker.
class LineInspectionLoginScreen extends StatefulWidget {
  const LineInspectionLoginScreen({super.key});

  @override
  State<LineInspectionLoginScreen> createState() =>
      _LineInspectionLoginScreenState();
}

class _LineInspectionLoginScreenState extends State<LineInspectionLoginScreen> {
  final _idCtl = TextEditingController();
  final _pwCtl = TextEditingController();
  bool _obscure = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _idCtl.dispose();
    _pwCtl.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final id = _idCtl.text.trim();
    final pw = _pwCtl.text;
    if (id.isEmpty || pw.isEmpty) {
      setState(() => _error = 'Enter your employee ID and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The backend is always tried first, even when we believe we are offline —
      // that belief can be stale, and a real sign-in mints a fresh token where
      // the offline path can only replay an old one. Believing we are offline
      // only shortens how long we are willing to wait to find out.
      final believedOffline = !ConnectivityService.instance.online.value;
      final profile = await LineInspectionApi.login(
        id,
        pw,
        timeout: believedOffline
            ? const Duration(seconds: 6)
            : const Duration(seconds: 25),
      );
      final token = profile['token'] as String? ?? '';
      if (token.isEmpty) throw const LoginFailedException('No token returned.');
      final session = LiSession.fromLogin(profile, token: token);
      // Purges the previous employee's cached data when this is a different
      // person — see AuthStore.save. Must complete before the hub is built, or
      // its tabs paint from the old jurisdiction on their first frame.
      await AuthStore.instance.save(session);
      // The backend has just vouched for these credentials, which is the only
      // thing that earns the right to accept them again with no signal.
      await OfflineCredentials.instance
          .remember(employeeId: session.employeeId, password: pw, session: session);
      _enter(session);
    } on LoginFailedException catch (e) {
      // The server was reachable and said no. That is an answer, not an outage —
      // falling back to the device's copy here would let a wrong password in
      // whenever the stored one happened to match.
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (!_isNetworkError(e)) {
        if (mounted) setState(() => _error = 'Could not sign in. $e');
        return;
      }
      await _signInOffline(id, pw);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The server could not be reached, so fall back to credentials this device
  /// has already had verified online.
  Future<void> _signInOffline(String id, String pw) async {
    final result = await OfflineCredentials.instance
        .verify(employeeId: id, password: pw);
    if (!mounted) return;
    final session = result.session;
    if (session == null) {
      setState(() => _error = result.message);
      return;
    }
    await AuthStore.instance.save(session);
    if (!mounted) return;
    _enter(session, offline: true);
  }

  /// Into the hub, picking up anything this employee left queued on this device
  /// and recounting so the status bar reflects them rather than whoever was
  /// signed in before.
  void _enter(LiSession session, {bool offline = false}) {
    SyncEngine.instance.kick();
    if (!mounted) return;
    if (offline) {
      // Say it plainly: they are in, on saved credentials, and their work will
      // upload later. Anything vaguer reads as "did that actually work?".
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Signed in offline — your work will upload when you '
            'reconnect.'),
        duration: Duration(seconds: 4),
      ));
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute(
      builder: (_) => LineInspectionHubScreen(session: session),
    ));
  }

  /// Whether [e] means "couldn't reach the server" rather than "the server said
  /// no" — the distinction that decides if an offline sign-in is legitimate.
  static bool _isNetworkError(Object e) =>
      e is SocketException ||
      e is TimeoutException ||
      e is http.ClientException ||
      e is HandshakeException;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The light product surface, not the dark brand gradient: sign-in now
      // reads like every other screen (white app bar over kSurface) instead of
      // being the one dark page in the app.
      backgroundColor: kSurface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _hero(),
                  const SizedBox(height: kSpaceXl),
                  Container(
                    decoration: BoxDecoration(
                      color: kCardBg,
                      borderRadius: BorderRadius.circular(kRadiusXl),
                      // A hairline carries the card's edge against the light
                      // page; the shadow only has to lift it, so the softer of
                      // the two elevations is enough.
                      border: Border.all(color: kOutline),
                      boxShadow: kShadowSoft,
                    ),
                    padding: const EdgeInsets.all(kSpaceXl),
                    child: _form(),
                  ),
                  const SizedBox(height: kSpaceLg),
                  const Text(
                    'Transmission Corporation of Andhra Pradesh',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.3,
                      color: kInkFaint,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The logo sits straight on the page — on a light background the white
  /// plate it used to need over the gradient is just another box.
  Widget _hero() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Image.asset(kLogoFull, height: 88, filterQuality: FilterQuality.medium),
          const SizedBox(height: kSpaceLg),
          const Text(
            'Transmission Line Inspection System',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: kInkSoft,
            ),
          ),
        ],
      );

  Widget _form() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Sign in',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: kInk)),
          const SizedBox(height: kSpaceXs),
          const Text('Use your APTRANSCO employee credentials',
              style: TextStyle(fontSize: 13, color: kInkSoft)),
          const SizedBox(height: kSpaceXl),
          TextField(
            controller: _idCtl,
            enabled: !_busy,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Employee ID',
              prefixIcon: Icon(Icons.badge_outlined),
            ),
          ),
          const SizedBox(height: kSpaceLg),
          TextField(
            controller: _pwCtl,
            enabled: !_busy,
            obscureText: _obscure,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _busy ? null : _signIn(),
            decoration: InputDecoration(
              labelText: 'Password',
              prefixIcon: const Icon(Icons.lock_outline),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
          // Say up front that no signal is not a dead end, so an inspector at a
          // tower tries instead of assuming they are locked out.
          ValueListenableBuilder<bool>(
            valueListenable: ConnectivityService.instance.online,
            builder: (context, isOnline, _) {
              if (isOnline) return const SizedBox.shrink();
              return const Padding(
                padding: EdgeInsets.only(top: kSpaceMd),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.cloud_off_outlined, size: 16, color: kInkSoft),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'No internet — you can still sign in if you have '
                        'signed in on this device before.',
                        style: TextStyle(fontSize: 12.5, color: kInkSoft),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          if (_error != null) ...[
            const SizedBox(height: kSpaceMd),
            Row(
              children: [
                Icon(Icons.error_outline, size: 16, color: kCritColor['critical']),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(_error!,
                      style: TextStyle(color: kCritColor['critical'], fontSize: 12.5)),
                ),
              ],
            ),
          ],
          const SizedBox(height: kSpaceXl),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              // The steel-blue accent rather than the theme's navy primary, so
              // no navy is left on this screen. White on #3D6AA6 is 5.5:1.
              style: FilledButton.styleFrom(backgroundColor: kBrandAccent),
              onPressed: _busy ? null : _signIn,
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.login, size: 20),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_busy ? 'Signing in…' : 'Sign in'),
              ),
            ),
          ),
        ],
      );
}
