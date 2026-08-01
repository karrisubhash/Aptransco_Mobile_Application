import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';

import '../services/auth_store.dart';
import '../utils/li_style.dart';
import 'line_inspection_hub_screen.dart';
import 'line_inspection_login_screen.dart';

/// The launch welcome screen: brand mark, "Welcome" and a one-line pitch over
/// a wave/watermark backdrop. Fully visible from its very first frame (no
/// gap-causing fade-in) and handed off from the native splash the moment its
/// own imagery is precached, it holds briefly before routing on — to the hub
/// if a stored token exists, otherwise to the login screen (real
/// checkCred-backed sign-in).
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key, required this.boot});

  /// The async boot started in `main()`, which now runs behind the first frame
  /// so this screen can replace the native splash as early as possible. The
  /// on-screen hold below and the boot overlap; [_enter] waits for whichever
  /// finishes last.
  final Future<void> boot;

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    // Content never starts transparent — the native splash already owns the
    // "reveal" moment, so this only needs a small settle-in pop. A fade from
    // 0 here would show as a blank white beat the instant the native splash
    // is removed underneath it, which is exactly the gap this screen must not
    // have.
    _c =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 1400),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _enter();
        });
    _scale = Tween<double>(begin: 0.98, end: 1.0).animate(
      CurvedAnimation(
        parent: _c,
        curve: const Interval(0.0, 0.25, curve: Curves.easeOut),
      ),
    );
    // Wait for the first frame, precache both brand images, then hand off
    // from the native splash to this screen — and only then start the
    // on-screen clock. Removing the splash any earlier risks doing so before
    // Image.asset has finished decoding, which is its own source of a blank
    // flash.
    WidgetsBinding.instance.addPostFrameCallback((_) => _ready());
  }

  Future<void> _ready() async {
    await Future.wait([
      precacheImage(const AssetImage(kLogoFull), context),
      precacheImage(const AssetImage(kLogoMark), context),
    ]);
    FlutterNativeSplash.remove();
    if (mounted) _c.forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _enter() async {
    // The boot runs concurrently with the hold above, so by now it has usually
    // finished — but on a cold start on a slow device it may not have, and
    // AuthStore below is one of the things it populates. Routing on before it
    // lands would read an empty session and send a signed-in engineer to the
    // login screen.
    await widget.boot;
    if (!mounted) return;
    final session = AuthStore.instance.session;
    final loggedIn = AuthStore.instance.isLoggedIn;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 400),
        pageBuilder: (_, _, _) => loggedIn
            ? LineInspectionHubScreen(session: session!)
            : const LineInspectionLoginScreen(),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Stack(
          children: [
            // Waves + faint tower watermark anchored to the bottom, behind
            // everything else and untouchable (it's pure decoration).
            const Positioned.fill(
              child: IgnorePointer(child: _WelcomeBackdrop()),
            ),
            SafeArea(
              child: ScaleTransition(
                scale: _scale,
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 24,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          kLogoFull,
                          width: 150,
                          filterQuality: FilterQuality.medium,
                        ),
                        const SizedBox(height: kSpaceLg),
                        const Text(
                          'APTRANSCO',
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.4,
                            color: kBrandPrimary,
                          ),
                        ),
                        const SizedBox(height: kSpaceSm),
                        const Text(
                          'Andhra Pradesh Transmission Corporation Limited',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            letterSpacing: 0.2,
                            color: kInkSoft,
                          ),
                        ),
                        const SizedBox(height: kSpaceXl + kSpaceSm),
                        Row(
                          children: [
                            Expanded(
                              child: Divider(color: kOutline, height: 1),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: kSpaceMd,
                              ),
                              child: Icon(
                                Icons.bolt,
                                size: 18,
                                color: kBrandAccent,
                              ),
                            ),
                            Expanded(
                              child: Divider(color: kOutline, height: 1),
                            ),
                          ],
                        ),
                        const SizedBox(height: kSpaceXl + kSpaceSm),
                        const Text(
                          'Welcome',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            color: kInk,
                          ),
                        ),
                        const SizedBox(height: kSpaceMd),
                        const Text(
                          'AI Powered Drone Inspection System for Smarter '
                          'Transmission Monitoring',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.4,
                            color: kInkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The wavy blue backdrop with a faint tower watermark, pinned to the bottom
/// of the screen — pure decoration behind the welcome content.
class _WelcomeBackdrop extends StatelessWidget {
  const _WelcomeBackdrop();

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Ghost tower mark, oversized and mostly cropped off the bottom-right
        // corner — the same brand mark used everywhere else, just huge and
        // faint so it reads as texture rather than a second logo.
        Positioned(
          bottom: -30,
          right: -70,
          child: Opacity(
            opacity: 0.10,
            child: Image.asset(
              kLogoMark,
              width: 320,
              color: kBrandAccent,
              colorBlendMode: BlendMode.srcIn,
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SizedBox(
            height: 220,
            width: double.infinity,
            child: CustomPaint(painter: _WavePainter()),
          ),
        ),
      ],
    );
  }
}

/// Three overlapping sine-wave layers in ascending brand blues, lightest
/// (furthest back) to darkest (frontmost) — a calm footer for the welcome
/// screen rather than a hard horizontal edge.
class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    _layer(canvas, size, heightFactor: 0.62, phase: 0.35, color: kBlue100);
    _layer(
      canvas,
      size,
      heightFactor: 0.4,
      phase: 0.0,
      color: kBrandAccent.withValues(alpha: 0.55),
    );
    _layer(
      canvas,
      size,
      heightFactor: 0.22,
      phase: 0.6,
      color: kBrandPrimary.withValues(alpha: 0.9),
    );
  }

  void _layer(
    Canvas canvas,
    Size size, {
    required double heightFactor,
    required double phase,
    required Color color,
  }) {
    final baseline = size.height * (1 - heightFactor);
    final amplitude = size.height * 0.06;
    final path = Path()..moveTo(0, size.height);
    path.lineTo(0, baseline);
    const steps = 40;
    for (var i = 0; i <= steps; i++) {
      final x = size.width * i / steps;
      final y =
          baseline +
          amplitude *
              math.sin((i / steps * math.pi * 2) + (phase * math.pi * 2));
      path.lineTo(x, y);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(covariant _WavePainter oldDelegate) => false;
}
