import 'package:flutter/material.dart';

import '../models/li_session.dart';
import '../services/auth_store.dart';
import '../services/line_inspection_api.dart';
import '../utils/li_style.dart';
import '../services/offline/cache_warmer.dart';
import '../services/offline/sync_engine.dart';
import '../widgets/sync_status_bar.dart';
import 'li_tabs/home_tab.dart';
import 'li_tabs/inspections_tab.dart';
import 'li_tabs/tickets_tab.dart';
import 'li_tabs/support_tab.dart';
import 'line_inspection_login_screen.dart';

/// The line-inspection platform shell: four tabs (Home, Tickets, History, Help)
/// scoped to the logged-in session.
///
/// Home carries the whole inspection workflow — it maps the user's assigned
/// lines, ranks the nearest towers from the live GPS fix, and a tap on any tower
/// opens its details with an Inspect action that runs the presence gate and
/// opens the form. There is deliberately no separate Inspect tab.
class LineInspectionHubScreen extends StatefulWidget {
  final LiSession session;
  const LineInspectionHubScreen({super.key, required this.session});

  @override
  State<LineInspectionHubScreen> createState() =>
      _LineInspectionHubScreenState();
}

class _LineInspectionHubScreenState extends State<LineInspectionHubScreen> {
  LiSession get session => widget.session;

  @override
  void initState() {
    super.initState();
    // Start keeping the device stocked in the background. Signing in is the
    // point the jurisdiction becomes known, so it is the earliest moment the
    // warmer can do anything useful — and it needs no prompting from the user.
    CacheWarmer.instance.start(session);
  }

  @override
  void dispose() {
    CacheWarmer.instance.stop();
    super.dispose();
  }

  static const _tabs = <Tab>[
    Tab(icon: Icon(Icons.home_outlined), text: 'Home'),
    Tab(icon: Icon(Icons.confirmation_number_outlined), text: 'Tickets'),
    Tab(icon: Icon(Icons.assignment_outlined), text: 'History'),
    Tab(icon: Icon(Icons.support_agent_outlined), text: 'Help'),
  ];

  Future<void> _logout(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text('You will need your employee ID and password to sign in again.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Sign out')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    // Stop warming before the session goes away, so a pass in flight can't keep
    // pulling down the previous user's jurisdiction.
    CacheWarmer.instance.stop();
    await LineInspectionApi.logout();
    // Revokes the token, forgets the session and purges everything cached under
    // it, so the next employee to sign in starts from the server.
    await AuthStore.instance.clear();
    // The queue is deliberately kept (unsynced field work), but it is now scoped
    // to its owner — so recount, or the status bar keeps advertising this
    // employee's pending changes to whoever signs in next.
    SyncEngine.instance.kick();
    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LineInspectionLoginScreen()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: _tabs.length,
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: kCardBg,
          foregroundColor: kInk,
          toolbarHeight: 64,
          title: Row(
            children: [
              _brandEmblem(),
              const SizedBox(width: kSpaceMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'APTRANSCO',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                        height: 1.1,
                      ),
                    ),
                    Text(
                      'Line Inspection',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: kInkSoft,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3,
                        height: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
              onPressed: () => _logout(context),
            ),
            const SizedBox(width: kSpaceXs),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(32),
            child: _scopeBar(),
          ),
        ),
        body: Column(
          children: [
            const SyncStatusBar(),
            Expanded(
              child: TabBarView(
                children: [
                  HomeTab(session: session),
                  TicketsTab(session: session),
                  InspectionsTab(session: session),
                  SupportTab(session: session),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: _bottomNav(),
      ),
    );
  }

  /// The primary navigation, pinned to the bottom of the shell. Styled for a
  /// light surface — the shared [tabBarTheme] is tuned for the dark brand
  /// gradient this bar used to sit on, so its colours are overridden here. The
  /// active tab is marked with a hairline along the top edge (toward the
  /// content), not the usual underline.
  Widget _bottomNav() {
    return Container(
      decoration: const BoxDecoration(
        color: kCardBg,
        border: Border(top: BorderSide(color: kOutline)),
      ),
      child: SafeArea(
        top: false,
        child: const TabBar(
          isScrollable: false,
          tabs: _tabs,
          labelColor: kBrandPrimary,
          unselectedLabelColor: kInkFaint,
          indicatorSize: TabBarIndicatorSize.tab,
          indicator: BoxDecoration(
            border: Border(top: BorderSide(color: kBrandPrimary, width: 2.5)),
          ),
          labelStyle: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
          unselectedLabelStyle: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// The AP TRANSCO tower mark shown at the head of the app bar — placed
  /// directly on the white bar (no white badge, which would vanish).
  Widget _brandEmblem() => Image.asset(
        kLogoMark,
        width: 34,
        height: 34,
        filterQuality: FilterQuality.medium,
      );

  /// A slim identity strip under the title showing who is signed in and the
  /// jurisdiction everything below is scoped to.
  Widget _scopeBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(kSpaceLg, 0, kSpaceLg, kSpaceSm),
      color: Colors.transparent,
      child: Row(
        children: [
          Icon(
            session.isManagementOrAdmin ? Icons.apartment_rounded : Icons.person_pin_circle_outlined,
            size: 15,
            color: kInkSoft,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${session.employeeId}  ·  ${session.jurisdictionLabel}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                color: kInkSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
