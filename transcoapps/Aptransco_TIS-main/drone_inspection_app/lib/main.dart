import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'screens/welcome_screen.dart';
import 'services/api_service.dart';
import 'services/auth_store.dart';
import 'services/network_security.dart';
import 'services/offline/cache_warmer.dart';
import 'services/offline/connectivity_service.dart';
import 'services/offline/local_store.dart';
import 'services/offline/outbox.dart';
import 'services/offline/sync_engine.dart';
import 'utils/li_theme.dart';

void main() {
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  // Hold the native launch screen — the full-screen APtransco_app.png welcome
  // artwork — until WelcomeScreen has precached its imagery and calls
  // FlutterNativeSplash.remove(). That's what makes the handoff gap-free:
  // without this, Flutter's default behaviour is to drop the native splash the
  // instant its first frame renders, which can be a blank beat before an
  // Image.asset has finished decoding.
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);
  // _boot() is deliberately NOT awaited before runApp. Android 12+ ignores the
  // artwork above and substitutes its own centre-masked launcher icon, which
  // the platform SplashScreen API gives no way to replace — so every
  // millisecond spent booting before the first Flutter frame is a millisecond
  // of that icon rather than of the welcome artwork. Booting behind the first
  // frame trims it to the unavoidable process-start flash. WelcomeScreen awaits
  // this future before routing on, so the hub and login never open against a
  // half-initialised store.
  runApp(AptranscoApp(boot: _boot()));
}

/// Restores any saved backend URL, wires up TLS trust for intercepting networks
/// (both no-ops by default), then brings up the offline layer: the on-device
/// store, the durable change queue, connectivity tracking, and the sync engine
/// that flushes the queue whenever the backend is reachable.
///
/// Never throws. Everything downstream waits on this future, so letting it
/// complete with an error would strand the app on the welcome artwork forever;
/// a failure is reported through Flutter's normal error channel instead.
Future<void> _boot() async {
  try {
    await ApiService.loadBaseUrl();
    await AuthStore.instance.load();
    await NetworkSecurity.install();
    await LocalStore.instance.init();
    await OutboxStore.instance.init();
    await ConnectivityService.instance.init();
    SyncEngine.instance.start();
  } catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'drone_inspection_app',
        context: ErrorDescription('while booting the offline layer'),
      ),
    );
  }
}

class AptranscoApp extends StatefulWidget {
  const AptranscoApp({super.key, required this.boot});

  /// Completes when the async boot started in [main] has finished. Handed to
  /// WelcomeScreen, which waits on it before routing into the app.
  final Future<void> boot;

  @override
  State<AptranscoApp> createState() => _AptranscoAppState();
}

class _AptranscoAppState extends State<AptranscoApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the foreground is a natural moment to re-check the network,
    // push any changes made while the app was backgrounded, and top up the
    // on-device cache for whatever comes next.
    if (state != AppLifecycleState.resumed) return;
    // Now that boot runs behind the first frame, a resume can land while it is
    // still in flight — background and foreground the app within the first few
    // hundred ms of launch and this fires early. Both calls reach into the
    // outbox and connectivity services, so wait boot out rather than poking a
    // half-initialised layer. In the normal case this is already complete and
    // resolves on the next microtask.
    widget.boot.then((_) {
      if (!mounted) return;
      SyncEngine.instance.onResume();
      CacheWarmer.instance.onResume();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aptransco TIS',
      debugShowCheckedModeBanner: false,
      theme: buildLiTheme(),
      themeMode: ThemeMode.light,
      // The branded welcome screen is the opening screen; its "Get Started"
      // continues into the hub. (Sign-in is still disabled — the hub boots with
      // a default Head-Office session.)
      home: WelcomeScreen(boot: widget.boot),
    );
  }
}
