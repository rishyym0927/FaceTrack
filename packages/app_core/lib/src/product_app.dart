import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'auth.dart';
import 'api.dart';
import 'config.dart';
import 'home.dart';
import 'notifications.dart';
import 'transitions.dart';
import 'widgets.dart';

typedef DetailBuilder = Widget Function(BuildContext, String);
SemanticsHandle? _webSemantics;

/// Tracks unsaved teacher decisions for the currently open session route.
class SessionExitGuard {
  String? sessionId;
  bool dirty = false;
  bool busy = false;
  void enter(String id) {
    sessionId = id;
    dirty = false;
    busy = false;
  }

  void leave(String id) {
    if (sessionId == id) {
      sessionId = null;
      dirty = false;
      busy = false;
    }
  }

  bool protects(String id) => sessionId == id;
}

final sessionExitGuardProvider = Provider<SessionExitGuard>(
  (ref) => SessionExitGuard(),
);

Future<void> launchProduct(
  AppConfig config, {
  required WidgetBuilder classesBuilder,
  DetailBuilder? detailBuilder,
  DetailBuilder? sessionBuilder,
  WidgetBuilder? enrollmentBuilder,
  WidgetBuilder? adminBuilder,
  WidgetBuilder? attendanceBuilder,
  WidgetBuilder? accountStatsBuilder,
  NotificationsLoader? notificationsLoader,
  Future<void> Function(AppServices)? configure,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) _webSemantics ??= SemanticsBinding.instance.ensureSemantics();
  try {
    final services = await AppServices.initialize(config);
    await configure?.call(services);
    runApp(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(services)],
        child: ProductApp(
          classesBuilder: classesBuilder,
          detailBuilder: detailBuilder,
          sessionBuilder: sessionBuilder,
          enrollmentBuilder: enrollmentBuilder,
          adminBuilder: adminBuilder,
          attendanceBuilder: attendanceBuilder,
          accountStatsBuilder: accountStatsBuilder,
          notificationsLoader: notificationsLoader,
        ),
      ),
    );
  } catch (_) {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: appTheme(),
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: 440),
                child: MessageView(
                  title: 'Setup required',
                  message: 'This build could not start. Check its configuration or contact the development team.',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class ProductApp extends ConsumerStatefulWidget {
  const ProductApp({
    super.key,
    required this.classesBuilder,
    this.detailBuilder,
    this.sessionBuilder,
    this.enrollmentBuilder,
    this.adminBuilder,
    this.attendanceBuilder,
    this.accountStatsBuilder,
    this.notificationsLoader,
  });
  final WidgetBuilder classesBuilder;
  final DetailBuilder? detailBuilder, sessionBuilder;
  final WidgetBuilder? enrollmentBuilder;
  final WidgetBuilder? adminBuilder;

  /// An all-subjects attendance page, shown as its own tab when present.
  final WidgetBuilder? attendanceBuilder;

  /// Role-specific statistics shown on the Account page.
  final WidgetBuilder? accountStatsBuilder;

  /// Supplies this app's in-app notices; null shows no bell.
  final NotificationsLoader? notificationsLoader;
  @override
  ConsumerState<ProductApp> createState() => _ProductAppState();
}

class _ProductAppState extends ConsumerState<ProductApp> {
  late final GoRouter router;
  NotificationCenter? notifications;
  AppLifecycleListener? lifecycle;

  void refreshNotifications({bool force = false}) {
    final auth = ref.read(authProvider);
    if (!auth.signedIn || auth.loading || auth.error != null) return;
    notifications?.ensureFresh(
      ref.read(servicesProvider).api,
      auth,
      force: force,
    );
  }

  static const _authScreens = {
    '/login',
    '/loading',
    '/connection',
    '/claim',
    '/access',
    '/institutes',
  };

  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    if (widget.notificationsLoader != null) {
      notifications = NotificationCenter(widget.notificationsLoader!);
      lifecycle = AppLifecycleListener(
        onResume: () => refreshNotifications(force: true),
      );
    }
    router = GoRouter(
      initialLocation: '/classes',
      refreshListenable: auth,
      // The destination is preserved in a ?from= query on the auth screens, so
      // it survives every gating bounce and a browser refresh — with no mutable
      // state that a redirect re-run could race on and clear.
      redirect: (context, state) {
        final loc = state.uri;
        final atAuthScreen = _authScreens.contains(loc.path);
        final carried = loc.queryParameters['from'];
        // Where to return once auth is ready: the carried target, or the
        // current location when it is a real (non-auth) route.
        final target = (carried != null && carried.isNotEmpty)
            ? carried
            : (atAuthScreen ? null : loc.toString());

        String? gateTo(String screen) {
          final keep = (target == null || target == '/classes') ? null : target;
          // Already parked on this screen with the right target → no redirect
          // (compare logical values to avoid encoding-mismatch loops).
          if (loc.path == screen &&
              (loc.queryParameters['from'] ?? '') == (keep ?? '')) {
            return null;
          }
          return Uri(
            path: screen,
            queryParameters: keep == null ? null : {'from': keep},
          ).toString();
        }

        if (!auth.signedIn) return gateTo('/login');
        if (auth.loading) return gateTo('/loading');
        if (auth.error != null) return gateTo('/connection');
        if (auth.memberships.isEmpty) {
          return gateTo(auth.canClaim ? '/claim' : '/access');
        }
        if (auth.institute == null) return gateTo('/institutes');
        // Ready: resume the carried destination when parked on an auth screen.
        if (atAuthScreen) return target ?? '/classes';
        return null;
      },
      routes: [
        GoRoute(
          path: '/login',
          pageBuilder: (_, s) => fadeThroughPage(s, const LoginPage()),
        ),
        GoRoute(
          path: '/loading',
          pageBuilder: (_, s) => fadeThroughPage(
            s,
            const Scaffold(body: Center(child: CircularProgressIndicator())),
          ),
        ),
        GoRoute(
          path: '/connection',
          pageBuilder: (_, s) =>
              fadeThroughPage(s, const AccountGate(connection: true)),
        ),
        GoRoute(
          path: '/access',
          pageBuilder: (_, s) => fadeThroughPage(s, const AccountGate()),
        ),
        GoRoute(
          path: '/claim',
          pageBuilder: (_, s) => fadeThroughPage(s, const ClaimPage()),
        ),
        GoRoute(
          path: '/institutes',
          pageBuilder: (_, s) => fadeThroughPage(s, const InstitutePage()),
        ),
        ShellRoute(
          builder: (context, state, child) {
            // Navigating is a natural moment to refresh stale notices.
            refreshNotifications();
            return ProductShell(
              key: ValueKey(
                (auth.account?.userId ?? '') + (auth.institute ?? ''),
              ),
              path: state.uri.path,
              hasAdmin: widget.adminBuilder != null,
              hasAttendance: widget.attendanceBuilder != null,
              notifications: notifications,
              child: child,
            );
          },
          routes: [
            // A subject's page is nested under the list, so opening one
            // pushes over the list (kept alive) and back pops with the
            // reverse slide; the URL stays /classes/:id.
            GoRoute(
              path: '/classes',
              pageBuilder: (c, s) =>
                  fadeThroughPage(s, Builder(builder: widget.classesBuilder)),
              routes: [
                if (widget.detailBuilder != null)
                  GoRoute(
                    path: ':id',
                    pageBuilder: (c, s) => slidePage(
                      s,
                      KeyedSubtree(
                        key: ValueKey('class:${s.pathParameters['id']}'),
                        child: widget.detailBuilder!(
                          c,
                          s.pathParameters['id']!,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            GoRoute(
              path: '/account',
              pageBuilder: (_, s) => fadeThroughPage(
                s,
                AccountPage(statsBuilder: widget.accountStatsBuilder),
              ),
            ),
            if (widget.attendanceBuilder != null)
              GoRoute(
                path: '/attendance',
                pageBuilder: (c, s) => fadeThroughPage(
                  s,
                  Builder(builder: widget.attendanceBuilder!),
                ),
              ),
            if (notifications != null)
              GoRoute(
                path: '/notifications',
                pageBuilder: (_, s) => fadeThroughPage(
                  s,
                  NotificationsPage(
                    center: notifications!,
                    refresh: () => refreshNotifications(force: true),
                  ),
                ),
              ),
            if (widget.adminBuilder != null)
              GoRoute(
                path: '/admin',
                pageBuilder: (c, s) =>
                    fadeThroughPage(s, Builder(builder: widget.adminBuilder!)),
              ),
            if (widget.enrollmentBuilder != null)
              GoRoute(
                path: '/enrolment',
                pageBuilder: (c, s) => fadeThroughPage(
                  s,
                  Builder(builder: widget.enrollmentBuilder!),
                ),
              ),
            if (widget.sessionBuilder != null)
              GoRoute(
                path: '/sessions/:id',
                pageBuilder: (c, s) => slidePage(
                  s,
                  KeyedSubtree(
                    key: ValueKey('session:${s.pathParameters['id']}'),
                    child: widget.sessionBuilder!(c, s.pathParameters['id']!),
                  ),
                ),
                onExit: (context, state) async {
                  final guard = ref.read(sessionExitGuardProvider);
                  final id = state.pathParameters['id']!;
                  if (!guard.protects(id) ||
                      !auth.signedIn ||
                      auth.error != null) {
                    return true;
                  }
                  if (guard.busy) return false;
                  if (!guard.dirty) return true;
                  return await showDialog<bool>(
                        context: context,
                        builder: (dialogContext) => AlertDialog(
                          title: const Text('Discard unsaved decisions?'),
                          content: const Text(
                            'Your attendance choices have not been saved. Stay to save a draft, or discard these changes.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, false),
                              child: const Text('Stay'),
                            ),
                            FilledButton(
                              onPressed: () =>
                                  Navigator.pop(dialogContext, true),
                              child: const Text('Discard changes'),
                            ),
                          ],
                        ),
                      ) ??
                      false;
                },
              ),
          ],
        ),
      ],
      errorBuilder: (context, state) => Scaffold(
        body: Center(
          child: MessageView(
            title: 'Page unavailable',
            message: 'Return to your subjects to continue.',
            action: FilledButton(
              onPressed: () => context.go('/classes'),
              child: const Text('My subjects'),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    lifecycle?.dispose();
    notifications?.dispose();
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: ref.read(servicesProvider).config.title,
    theme: appTheme(),
    debugShowCheckedModeBanner: false,
    routerConfig: router,
    builder: (context, child) => notifications == null
        ? child!
        : NotificationScope(notifier: notifications!, child: child!),
  );
}

class NavTab {
  const NavTab(this.path, this.label, this.icon, this.selectedIcon);
  final String path, label;
  final IconData icon, selectedIcon;
}

class ProductShell extends StatelessWidget {
  const ProductShell({
    super.key,
    required this.path,
    required this.child,
    this.hasAdmin = false,
    this.hasAttendance = false,
    this.notifications,
  });
  final String path;
  final Widget child;
  final bool hasAdmin, hasAttendance;
  final NotificationCenter? notifications;
  @override
  Widget build(BuildContext context) => Consumer(
    builder: (context, ref, _) {
      final auth = ref.watch(authProvider),
          config = ref.read(servicesProvider).config;
      final student = config.role == AppRole.student;
      final isAdmin =
          hasAdmin &&
          config.role == AppRole.teacher &&
          (auth.account?.members.any(
                (m) =>
                    m.role == 'admin' &&
                    m.status == 'active' &&
                    m.instituteId == auth.institute,
              ) ??
              false);
      final tabs = <NavTab>[
        const NavTab(
          '/classes',
          'Subjects',
          Icons.groups_outlined,
          Icons.groups,
        ),
        if (hasAttendance)
          const NavTab(
            '/attendance',
            'Attendance',
            Icons.insights_outlined,
            Icons.insights,
          ),
        if (student)
          const NavTab(
            '/enrolment',
            'Enrolment',
            Icons.face_outlined,
            Icons.face,
          ),
        if (isAdmin)
          const NavTab(
            '/admin',
            'Admin',
            Icons.admin_panel_settings_outlined,
            Icons.admin_panel_settings,
          ),
        const NavTab('/account', 'Account', Icons.person_outline, Icons.person),
      ];
      var index = tabs.indexWhere((t) => path == t.path);
      if (index < 0)
        index = 0; // subject/session detail routes fall under Subjects
      void navigate(int i) => context.go(tabs[i].path);
      return LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 800;
          final showInstituteName =
              c.maxWidth >= 620 &&
              MediaQuery.textScalerOf(context).scale(1) <= 1.3;
          return Scaffold(
            appBar: AppBar(
              titleSpacing: wide ? 24 : 16,
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: const Icon(
                      Icons.center_focus_strong,
                      color: Colors.white,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 11),
                  Flexible(
                    child: Text(
                      config.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                if (notifications != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: NotificationBell(center: notifications!),
                  ),
                if (auth.instituteName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Tooltip(
                      message: auth.instituteName,
                      child: Semantics(
                        label: 'Institute: ${auth.instituteName}',
                        button: false,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: showInstituteName
                                ? c.maxWidth * 0.32
                                : 44,
                          ),
                          padding: EdgeInsets.symmetric(
                            horizontal: showInstituteName ? 12 : 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary
                                .withValues(alpha: .07),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.account_balance_outlined,
                                size: 18,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                              if (showInstituteName) ...[
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    auth.instituteName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            bottomNavigationBar: wide
                ? null
                : NavigationBar(
                    selectedIndex: index,
                    onDestinationSelected: navigate,
                    destinations: [
                      for (final t in tabs)
                        NavigationDestination(
                          icon: Icon(t.icon),
                          selectedIcon: Icon(t.selectedIcon),
                          label: t.label,
                        ),
                    ],
                  ),
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (wide)
                  NavigationRail(
                    selectedIndex: index,
                    labelType: NavigationRailLabelType.all,
                    onDestinationSelected: navigate,
                    destinations: [
                      for (final t in tabs)
                        NavigationRailDestination(
                          icon: Icon(t.icon),
                          selectedIcon: Icon(t.selectedIcon),
                          label: Text(t.label),
                        ),
                    ],
                  ),
                Expanded(child: child),
              ],
            ),
          );
        },
      );
    },
  );
}

class ContentPage extends StatelessWidget {
  const ContentPage({super.key, required this.children});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
    padding: EdgeInsets.symmetric(
      horizontal: MediaQuery.sizeOf(context).width < 600 ? 16 : 32,
      vertical: MediaQuery.sizeOf(context).width < 600 ? 20 : 32,
    ),
    children: [
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
    ],
  );
}

class _Highlight {
  const _Highlight(this.icon, this.title, this.body);
  final IconData icon;
  final String title, body;
}

const _brandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [Color(0xff0d2a2c), Color(0xff135f50), Color(0xff23906f)],
);

/// Shared frame for sign-in and account screens in both apps (web and phone).
/// Wide screens get a split layout with a branded panel; narrow screens get a
/// compact branded header above the form.
class AuthFrame extends ConsumerWidget {
  const AuthFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title, subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final student = ref.read(servicesProvider).config.role == AppRole.student;
    final portal = student ? 'Student portal' : 'Faculty portal';
    final headline = student
        ? 'Your attendance, always in view.'
        : 'Attendance you can trust, in minutes.';
    final highlights = student
        ? const [
            _Highlight(
              Icons.face_outlined,
              'Enrol your face once',
              'A short guided recording, only with your consent.',
            ),
            _Highlight(
              Icons.event_available_outlined,
              'Every subject in one place',
              'See published attendance and your percentage per subject.',
            ),
            _Highlight(
              Icons.lock_outline,
              'Private by design',
              'Face data stays private and you can withdraw consent.',
            ),
          ]
        : const [
            _Highlight(
              Icons.videocam_outlined,
              'Record the class once',
              'A short walk-through clip suggests who is present.',
            ),
            _Highlight(
              Icons.fact_check_outlined,
              'You stay in control',
              'Review every suggestion before anything is published.',
            ),
            _Highlight(
              Icons.insights_outlined,
              'See the whole semester',
              'Subject-wise and semester-wise attendance at a glance.',
            ),
          ];
    final scheme = Theme.of(context).colorScheme;

    Widget logo({double size = 44}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .14),
            borderRadius: BorderRadius.circular(size * .3),
            border: Border.all(color: Colors.white.withValues(alpha: .22)),
          ),
          child: Icon(
            Icons.center_focus_strong,
            color: Colors.white,
            size: size * .56,
          ),
        ),
        const SizedBox(width: 12),
        const Flexible(
          child: Text(
            'FaceTrack',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              letterSpacing: -.3,
            ),
          ),
        ),
      ],
    );

    Widget portalChip({bool light = true}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: light
            ? Colors.white.withValues(alpha: .14)
            : scheme.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            student ? Icons.school_outlined : Icons.co_present_outlined,
            size: 16,
            color: light ? const Color(0xffbbe9af) : scheme.primary,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              portal,
              style: TextStyle(
                color: light ? Colors.white : scheme.primary,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );

    final form = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -.7),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
          ),
          const SizedBox(height: 28),
          child,
          const SizedBox(height: 28),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.verified_user_outlined,
                size: 18,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Faces are processed privately. Attendance is final only after faculty review.',
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontSize: 12.5,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white,
      body: LayoutBuilder(
        builder: (context, c) {
          if (c.maxWidth >= 900) {
            final brand = DecoratedBox(
              decoration: const BoxDecoration(gradient: _brandGradient),
              child: CustomPaint(
                painter: _ScanPainter(),
                child: SafeArea(
                  child: LayoutBuilder(
                    builder: (context, b) => SingleChildScrollView(
                      padding: const EdgeInsets.all(48),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          minHeight: (b.maxHeight - 96).clamp(
                            0,
                            double.infinity,
                          ),
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              logo(),
                              const SizedBox(height: 64),
                              portalChip(),
                              const SizedBox(height: 20),
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 520,
                                ),
                                child: Text(
                                  headline,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 40,
                                    fontWeight: FontWeight.w800,
                                    height: 1.1,
                                    letterSpacing: -1,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 36),
                              for (final h in highlights)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 20),
                                  child: _HighlightRow(h),
                                ),
                              const SizedBox(height: 28),
                              const Text(
                                'Face-assisted attendance · human reviewed',
                                style: TextStyle(
                                  color: Color(0xffa9cfc2),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(flex: 11, child: brand),
                Expanded(
                  flex: 9,
                  child: SafeArea(
                    child: LayoutBuilder(
                      builder: (context, b) => SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 48,
                          vertical: 40,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (b.maxHeight - 80).clamp(
                              0,
                              double.infinity,
                            ),
                          ),
                          child: Center(child: form),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DecoratedBox(
                  decoration: const BoxDecoration(
                    gradient: _brandGradient,
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(28),
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(28),
                    ),
                    child: CustomPaint(
                      painter: _ScanPainter(),
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(22, 22, 22, 26),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              logo(size: 38),
                              const SizedBox(height: 22),
                              portalChip(),
                              const SizedBox(height: 12),
                              Text(
                                headline,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  height: 1.15,
                                  letterSpacing: -.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(22, 28, 22, 28),
                  child: Center(child: form),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HighlightRow extends StatelessWidget {
  const _HighlightRow(this.h);
  final _Highlight h;
  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 460),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(h.icon, color: const Color(0xffbbe9af), size: 22),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                h.title,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                h.body,
                style: const TextStyle(color: Color(0xffcfe5dc), height: 1.45),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Faint scan rings and a focus frame: decoration only.
class _ScanPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: .07);
    final centre = Offset(size.width * .8, size.height * .2);
    for (var r = 60.0; r < size.longestSide; r += 56) {
      canvas.drawCircle(centre, r, ring);
    }
    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round
      ..color = Colors.white.withValues(alpha: .16);
    const arm = 22.0, box = 92.0;
    final o = Offset(centre.dx - box / 2, centre.dy - box / 2);
    for (final (x, y, dx, dy) in [
      (0.0, 0.0, 1.0, 1.0),
      (box, 0.0, -1.0, 1.0),
      (0.0, box, 1.0, -1.0),
      (box, box, -1.0, -1.0),
    ]) {
      final p = o + Offset(x, y);
      canvas
        ..drawLine(p, p + Offset(arm * dx, 0), frame)
        ..drawLine(p, p + Offset(0, arm * dy), frame);
    }
  }

  @override
  bool shouldRepaint(_ScanPainter oldDelegate) => false;
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final form = GlobalKey<FormState>(),
      email = TextEditingController(),
      password = TextEditingController();
  bool busy = false, obscured = true;
  String? error;
  Future<void> login() async {
    if (busy) return;
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await ref.read(authProvider).signIn(email.text, password.text);
      password.clear();
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is AppFailure
              ? e.message
              : 'Could not sign in. Please retry.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    email.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final student = ref.read(servicesProvider).config.role == AppRole.student;
    return AuthFrame(
      title: 'Welcome back',
      subtitle: student
          ? 'Sign in with your institute student account to see your subjects and attendance.'
          : 'Sign in with your institute faculty account to take and review attendance.',
      child: AutofillGroup(
        child: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: email,
                enabled: !busy,
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  hintText: 'you@institute.edu',
                  prefixIcon: Icon(Icons.mail_outline),
                ),
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.username],
                textInputAction: TextInputAction.next,
                validator: (v) =>
                    v != null &&
                        RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(v.trim())
                    ? null
                    : 'Enter a valid email address.',
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: password,
                enabled: !busy,
                obscureText: obscured,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    tooltip: obscured ? 'Show password' : 'Hide password',
                    onPressed: () => setState(() => obscured = !obscured),
                    icon: Icon(
                      obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                  ),
                ),
                autofillHints: const [AutofillHints.password],
                onFieldSubmitted: (_) => busy ? null : login(),
                validator: requiredText,
              ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Semantics(
                  liveRegion: true,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: scheme.errorContainer.withValues(alpha: .6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.error_outline,
                          color: scheme.error,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            error!,
                            style: TextStyle(color: scheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                onPressed: busy ? null : login,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (busy) ...[
                      const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2.2),
                      ),
                      const SizedBox(width: 12),
                    ],
                    Flexible(child: Text(busy ? 'Signing in…' : 'Sign in')),
                    if (!busy) ...[
                      const SizedBox(width: 8),
                      const Icon(Icons.arrow_forward, size: 20),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerLowest,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: scheme.outline),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.help_outline, size: 20, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        student
                            ? 'No login yet? Your institute administrator creates student logins in the Admin section. For a forgotten password, contact the administrator.'
                            : 'No login yet? Your institute administrator creates faculty logins in the Admin section. For a forgotten password, contact the administrator.',
                        style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ClaimPage extends ConsumerStatefulWidget {
  const ClaimPage({super.key});
  @override
  ConsumerState<ClaimPage> createState() => _ClaimPageState();
}

class _ClaimPageState extends ConsumerState<ClaimPage> {
  final form = GlobalKey<FormState>(), number = TextEditingController();
  final mutation = Mutation();
  bool busy = false;
  String? error;
  Future<void> claim() async {
    if (busy) return;
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final services = ref.read(servicesProvider);
      await services.api.send(
        'POST',
        '/v1/identity/claim',
        institute: services.config.defaultInstituteId,
        body: {'enrollment_number': number.text.trim()},
        mutation: mutation,
      );
      await ref.read(authProvider).load();
    } catch (e) {
      if (mounted)
        setState(
          () => error = e is AppFailure
              ? e.message
              : 'Could not link your identity. Please retry.',
        );
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    number.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AuthFrame(
    title: 'Link your student identity',
    subtitle: 'Enter your approved enrolment number. Your account email must match the institute record.',
    child: Form(
      key: form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: number,
            enabled: !busy,
            maxLength: 32,
            decoration: const InputDecoration(labelText: 'Enrolment number'),
            validator: requiredText,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => busy ? null : claim(),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy ? null : claim,
            child: Text(busy ? 'Linking…' : 'Link identity'),
          ),
          TextButton(
            onPressed: busy ? null : () => ref.read(authProvider).signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
    ),
  );
}

class AccountGate extends ConsumerWidget {
  const AccountGate({super.key, this.connection = false});
  final bool connection;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return AuthFrame(
      title: connection
          ? 'Connection unavailable'
          : 'Account access unavailable',
      subtitle: connection ? (auth.error?.message ?? 'Please retry.') : 'This account is not approved for this app. Contact your institute.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            ref.read(servicesProvider).config.title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Signed in as ' +
                (ref.read(servicesProvider).client.auth.currentUser?.email ??
                    'your account'),
          ),
          const SizedBox(height: 20),
          OutlinedButton(
            onPressed: () => auth.load(),
            child: const Text('Retry'),
          ),
          TextButton(
            onPressed: () => auth.signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

class InstitutePage extends ConsumerWidget {
  const InstitutePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    return AuthFrame(
      title: 'Choose your institute',
      subtitle: 'Continue with an approved membership.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final m in auth.memberships)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: OutlinedButton(
                onPressed: () => auth.selectInstitute(m.instituteId),
                child: Text(m.instituteName),
              ),
            ),
          TextButton(
            onPressed: () => auth.signOut(),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty);
  final letters = parts.take(2).map((p) => p[0].toUpperCase()).join();
  return letters.isEmpty ? '?' : letters;
}

String _roleLabel(String role) => switch (role) {
  'teacher' => 'Faculty',
  'admin' => 'Admin',
  'student' => 'Student',
  _ => role,
};

class AccountPage extends ConsumerWidget {
  const AccountPage({super.key, this.statsBuilder});

  /// Role-specific statistics from the app (Student or Faculty).
  final WidgetBuilder? statsBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider), person = auth.person;
    final scheme = Theme.of(context).colorScheme;
    final email = ref.read(servicesProvider).client.auth.currentUser?.email;
    final name = person?.name ?? 'Account';
    final roles = {
      for (final m in auth.account?.members ?? const <Member>[])
        if (m.instituteId == auth.institute && m.status == 'active')
          _roleLabel(m.role),
    }.toList()..sort();
    final center = NotificationScope.of(context);
    final student = ref.read(servicesProvider).config.role == AppRole.student;

    Widget chip(IconData icon, String text) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x26ffffff),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: Colors.white),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );

    Widget detail(IconData icon, String label, String value, {Widget? trailing}) =>
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon, color: scheme.primary),
          title: Text(label, style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13)),
          subtitle: SelectableText(
            value.isEmpty ? '—' : value,
            style: TextStyle(color: scheme.onSurface, fontSize: 15, fontWeight: FontWeight.w600),
          ),
          trailing: trailing,
        );

    final header = Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xff0d2a2c), Color(0xff135f50), Color(0xff23906f)],
        ),
      ),
      child: Wrap(
        spacing: 20,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: Colors.white,
            child: Text(
              _initials(name),
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w800,
                color: Color(0xff135f50),
              ),
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -.5,
                  ),
                ),
                if (email != null) ...[
                  const SizedBox(height: 4),
                  Text(email, style: const TextStyle(color: Color(0xffd5e9e2))),
                ],
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final r in roles) chip(Icons.badge_outlined, r),
                    if (auth.instituteName.isNotEmpty)
                      chip(Icons.account_balance_outlined, auth.instituteName),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final details = Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Profile', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          detail(
            Icons.tag,
            student ? 'Enrolment number' : 'Employee number',
            person?.number ?? '',
            trailing: person == null
                ? null
                : IconButton(
                    tooltip: 'Copy',
                    icon: const Icon(Icons.copy_outlined),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: person.number));
                      showMessage(context, 'Copied to clipboard.');
                    },
                  ),
          ),
          detail(Icons.mail_outline, 'Email', email ?? ''),
          detail(Icons.account_balance_outlined, 'Institute', auth.instituteName),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text('Identity', style: TextStyle(color: scheme.onSurfaceVariant)),
                StatusBadge(person?.status == 'approved' ? 'active' : person?.status ?? 'unknown'),
              ],
            ),
          ),
        ],
      ),
    );

    final activity = center == null
        ? null
        : ListenableBuilder(
            listenable: center,
            builder: (context, _) {
              final recent = [...center.items]
                ..sort((a, b) => (b.time ?? DateTime(0)).compareTo(a.time ?? DateTime(0)));
              return Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Recent activity',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        TextButton(
                          onPressed: () => context.go('/notifications'),
                          child: const Text('See all'),
                        ),
                      ],
                    ),
                    if (center.loading && recent.isEmpty)
                      const LinearProgressIndicator()
                    else if (recent.isEmpty)
                      Text(
                        'No activity yet.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      )
                    else
                      for (final n in recent.take(5))
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(n.icon, color: scheme.primary),
                          title: Text(n.title),
                          subtitle: n.time == null ? null : Text(noticeAge(n.time!)),
                          trailing: n.route == null ? null : const Icon(Icons.chevron_right),
                          onTap: n.route == null
                              ? null
                              : () {
                                  center.markRead(n);
                                  context.go(n.route!);
                                },
                        ),
                  ],
                ),
              );
            },
          );

    return ContentPage(
      children: [
        header,
        if (statsBuilder != null) ...[
          const SizedBox(height: 20),
          statsBuilder!(context),
        ],
        const SizedBox(height: 20),
        LayoutBuilder(
          builder: (context, box) => box.maxWidth >= 820 && activity != null
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 20),
                    Expanded(child: activity),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    details,
                    if (activity != null) ...[const SizedBox(height: 20), activity],
                  ],
                ),
        ),
        const SizedBox(height: 24),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            if (auth.memberships.length > 1)
              OutlinedButton.icon(
                icon: const Icon(Icons.swap_horiz),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (context) => SimpleDialog(
                    title: const Text('Choose institute'),
                    children: [
                      for (final m in auth.memberships)
                        SimpleDialogOption(
                          onPressed: () {
                            auth.selectInstitute(m.instituteId);
                            Navigator.pop(context);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(m.instituteName),
                          ),
                        ),
                    ],
                  ),
                ),
                label: const Text('Switch institute'),
              ),
            OutlinedButton.icon(
              onPressed: () => auth.signOut(),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ],
    );
  }
}

mixin ResumeRefresh<T extends StatefulWidget> on State<T> {
  AppLifecycleListener? _lifecycle;
  void refreshOnResume();
  void watchLifecycle() =>
      _lifecycle = AppLifecycleListener(onResume: refreshOnResume);
  void unwatchLifecycle() => _lifecycle?.dispose();
}
