import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// Backend base-URL management for the line-inspection platform.
///
/// This used to also carry the old map-flow's data/inspection endpoints; those
/// screens have been removed, so all that remains is choosing which backend
/// host the app talks to. The line-inspection API layer
/// (`line_inspection_api.dart`) reads [baseUrl] from here.
class ApiService {
  // Backend host. The default is the reserved ngrok static domain, which keeps
  // working over the internet (e.g. LTE) no matter what network the phone or
  // dev machine are on. But on a network that intercepts TLS — a corporate
  // FortiGate doing SSL inspection — HTTPS to ngrok fails with a self-signed
  // certificate error; there, point [baseUrl] at the backend directly over
  // plain HTTP on the local LAN (e.g. the laptop's Wi-Fi hotspot), which the
  // firewall never sees. Requires `ngrok http 8000 --url=<domain>` running
  // against the backend for the ngrok path to work.
  //
  // Three layers decide the active URL, most specific wins:
  //   1. an in-app override (Settings on the Line Inspection screen), persisted
  //      in SharedPreferences — flip office/LAN vs field/ngrok without rebuilding;
  //   2. a build-time override: --dart-define=API_BASE_URL=http://<lan-ip>:8000/api
  //   3. the ngrok default below.
  // Base URL must end in `/api`. This backend serves the line_inspection API
  // under `/inspection/api/`, so point --dart-define / the in-app override at
  // e.g. http://<lan-ip>:8000/inspection/api or https://<host>/inspection/api.
  static const String _compileTimeBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://mispacked-beamy-noelle.ngrok-free.dev/inspection/api',
  );

  static const String _baseUrlPrefKey = 'api_base_url_override';
  static String _override = '';

  /// The active backend base URL: the in-app override if one is set, otherwise
  /// the compile-time default. Read fresh on every request, so a change in
  /// Settings takes effect immediately without a restart.
  static String get baseUrl =>
      _override.isEmpty ? normalize(_compileTimeBaseUrl) : _override;

  /// The compile-time default, shown as the placeholder/reset target in Settings.
  static String get defaultBaseUrl => normalize(_compileTimeBaseUrl);

  /// Whether an in-app override is currently active.
  static bool get hasBaseUrlOverride => _override.isNotEmpty;

  /// Trims a base URL and strips any trailing slashes.
  ///
  /// Every request builds its path as `'$baseUrl/lines/'`, so a base that ends
  /// in `/` produced `…/api//lines/` — which Django does not route (and
  /// `APPEND_SLASH` cannot rescue), so *every* call 404'd. A trailing slash is
  /// exactly what someone typing this URL on a phone, or pasting it from a
  /// browser bar, ends up with, so normalise it here rather than trusting the
  /// input.
  @visibleForTesting
  static String normalize(String url) {
    var u = url.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// Loads any saved base-URL override. Call once from main() before runApp.
  static Future<void> loadBaseUrl() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _override = normalize(prefs.getString(_baseUrlPrefKey) ?? '');
    } catch (_) {/* fall back to the compile-time default */}
  }

  /// Sets (or, when [url] is blank, clears) the in-app base-URL override.
  static Future<void> setBaseUrl(String url) async {
    _override = normalize(url);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_override.isEmpty) {
        await prefs.remove(_baseUrlPrefKey);
      } else {
        await prefs.setString(_baseUrlPrefKey, _override);
      }
    } catch (_) {/* best effort */}
  }
}
