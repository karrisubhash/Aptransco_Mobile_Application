import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import 'api_service.dart';

/// Adjusts the app's default [HttpClient] trust so requests can still succeed on
/// networks that intercept TLS — e.g. a corporate FortiGate doing SSL
/// inspection, which re-signs every HTTPS response with its own CA and makes the
/// ngrok backend fail with `CERTIFICATE_VERIFY_FAILED: self signed certificate`.
///
/// Two independent mechanisms, both OFF unless you opt in:
///
///  1. **Bundled corp CA (SECURE).** Put the real corporate root / SSL-inspection
///     CA (PEM) into `assets/certs/corp_ca.pem` and rebuild. It is added to the
///     trust store, so certs re-signed by that CA validate normally — the correct,
///     cryptographically safe way to work through SSL inspection. Get the CA from
///     IT / your FortiGate admin (on this project the required CA was
///     `CN=FG6H1FTB22904052, O=Fortinet`; the dev machine only had an unrelated
///     `CN=support` Fortinet root, which does not validate the intercepted certs).
///
///  2. **Accept the interceptor for the backend host only (INSECURE).** Enabled
///     with `--dart-define=ACCEPT_CORP_MITM=true`. Accepts an untrusted cert ONLY
///     for the currently-configured backend host — never a blanket accept-all.
///     This disables TLS authentication for that host: anyone on-path can read the
///     traffic. Use only as a last resort on a trusted corporate LAN when the CA
///     is unavailable, and never in a build handed to real inspectors.
class NetworkSecurity {
  static const bool _acceptCorpMitm =
      bool.fromEnvironment('ACCEPT_CORP_MITM', defaultValue: false);

  static const String _caAsset = 'assets/certs/corp_ca.pem';

  /// Installs [HttpOverrides] if either mechanism is active. A no-op — leaving
  /// default, fully-verified TLS in place — when no CA is bundled and the
  /// insecure flag is off.
  static Future<void> install() async {
    List<int>? caBytes;
    try {
      final pem = await rootBundle.loadString(_caAsset);
      if (pem.trimLeft().startsWith('-----BEGIN CERTIFICATE-----')) {
        caBytes = pem.codeUnits; // PEM is ASCII
      }
    } catch (_) {/* asset absent or unreadable — fine */}

    if (caBytes == null && !_acceptCorpMitm) return;

    HttpOverrides.global = _CorpHttpOverrides(caBytes, _acceptCorpMitm);
    if (_acceptCorpMitm) {
      debugPrint('NetworkSecurity: ACCEPT_CORP_MITM is ON — TLS authentication '
          'is disabled for the backend host. Do not ship this build.');
    }
  }
}

class _CorpHttpOverrides extends HttpOverrides {
  _CorpHttpOverrides(this._caBytes, this._acceptMitm);

  final List<int>? _caBytes;
  final bool _acceptMitm;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    // Keep the built-in roots, then additively trust the bundled corp CA.
    final ctx = context ?? SecurityContext(withTrustedRoots: true);
    final bytes = _caBytes;
    if (bytes != null) {
      try {
        ctx.setTrustedCertificatesBytes(bytes);
      } catch (_) {/* already added / malformed PEM — ignore */}
    }
    final client = super.createHttpClient(ctx);
    if (_acceptMitm) {
      client.badCertificateCallback = (cert, host, port) {
        // Accept an unverifiable cert ONLY for the active backend host.
        return host == Uri.tryParse(ApiService.baseUrl)?.host;
      };
    }
    return client;
  }
}
