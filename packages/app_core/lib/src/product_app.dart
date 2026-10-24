import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'auth.dart';
import 'api.dart';
import 'config.dart';
import 'widgets.dart';

typedef DetailBuilder = Widget Function(BuildContext, String);
SemanticsHandle? _webSemantics;

Future<void> launchProduct(
  AppConfig config, {
  required WidgetBuilder classesBuilder,
  DetailBuilder? detailBuilder,
  DetailBuilder? sessionBuilder,
  WidgetBuilder? enrollmentBuilder,
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
  });
  final WidgetBuilder classesBuilder;
  final DetailBuilder? detailBuilder, sessionBuilder;
  final WidgetBuilder? enrollmentBuilder;
  @override
  ConsumerState<ProductApp> createState() => _ProductAppState();
}

class _ProductAppState extends ConsumerState<ProductApp> {
  late final GoRouter router;
  @override
  void initState() {
    super.initState();
    final auth = ref.read(authProvider);
    router = GoRouter(
      initialLocation: '/classes',
      refreshListenable: auth,
      redirect: (context, state) {
        final path = state.uri.path;
        if (!auth.signedIn) return path == '/login' ? null : '/login';
        if (auth.loading) return path == '/loading' ? null : '/loading';
        if (auth.error != null)
          return path == '/connection' ? null : '/connection';
        if (auth.memberships.isEmpty) {
          final dest = auth.canClaim ? '/claim' : '/access';
          return path == dest ? null : dest;
        }
        if (auth.institute == null)
          return path == '/institutes' ? null : '/institutes';
        if ([
          '/login',
          '/loading',
          '/connection',
          '/claim',
          '/access',
          '/institutes',
        ].contains(path))
          return '/classes';
        return null;
      },
      routes: [
        GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
        GoRoute(
          path: '/loading',
          builder: (_, _) =>
              const Scaffold(body: Center(child: CircularProgressIndicator())),
        ),
        GoRoute(
          path: '/connection',
          builder: (_, _) => const AccountGate(connection: true),
        ),
        GoRoute(path: '/access', builder: (_, _) => const AccountGate()),
        GoRoute(path: '/claim', builder: (_, _) => const ClaimPage()),
        GoRoute(path: '/institutes', builder: (_, _) => const InstitutePage()),
        ShellRoute(
          builder: (context, state, child) => ProductShell(
            key: ValueKey(
              (auth.account?.userId ?? '') + (auth.institute ?? ''),
            ),
            path: state.uri.path,
            child: child,
          ),
          routes: [
            GoRoute(
              path: '/classes',
              builder: (c, s) => widget.classesBuilder(c),
            ),
            GoRoute(path: '/account', builder: (_, _) => const AccountPage()),
            if (widget.enrollmentBuilder != null)
              GoRoute(
                path: '/enrolment',
                builder: (c, s) => widget.enrollmentBuilder!(c),
              ),
            if (widget.sessionBuilder != null)
              GoRoute(
                path: '/sessions/:id',
                builder: (c, s) =>
                    widget.sessionBuilder!(c, s.pathParameters['id']!),
              ),
            if (widget.detailBuilder != null)
              GoRoute(
                path: '/classes/:id',
                builder: (c, s) =>
                    widget.detailBuilder!(c, s.pathParameters['id']!),
              ),
          ],
        ),
      ],
      errorBuilder: (context, state) => Scaffold(
        body: Center(
          child: MessageView(
            title: 'Page unavailable',
            message: 'Return to your classes to continue.',
            action: FilledButton(
              onPressed: () => context.go('/classes'),
              child: const Text('My classes'),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp.router(
    title: ref.read(servicesProvider).config.title,
    theme: appTheme(),
    debugShowCheckedModeBanner: false,
    routerConfig: router,
  );
}

class ProductShell extends StatelessWidget {
  const ProductShell({super.key, required this.path, required this.child});
  final String path;
  final Widget child;
  @override
  Widget build(BuildContext context) => Consumer(
    builder: (context, ref, _) {
      final auth = ref.watch(authProvider),
          config = ref.read(servicesProvider).config;
      final student = config.role == AppRole.student;
      final index = path == '/account'
          ? (student ? 2 : 1)
          : path == '/enrolment'
          ? 1
          : 0;
      void navigate(int i) => context.go(
        i == 0
            ? '/classes'
            : student && i == 1
            ? '/enrolment'
            : '/account',
      );
      return LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 800;
          return Scaffold(
            appBar: AppBar(
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
                if (auth.instituteName.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: c.maxWidth * 0.35),
                      child: Text(
                        auth.instituteName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12,
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
                      if (student) ...[
                        const NavigationDestination(
                          icon: Icon(Icons.groups_outlined),
                          selectedIcon: Icon(Icons.groups),
                          label: 'Classes',
                        ),
                        const NavigationDestination(
                          icon: Icon(Icons.face_outlined),
                          selectedIcon: Icon(Icons.face),
                          label: 'Enrolment',
                        ),
                      ] else
                        const NavigationDestination(
                          icon: Icon(Icons.groups_outlined),
                          selectedIcon: Icon(Icons.groups),
                          label: 'Classes',
                        ),
                      const NavigationDestination(
                        icon: Icon(Icons.person_outline),
                        selectedIcon: Icon(Icons.person),
                        label: 'Account',
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
                      if (student) ...[
                        const NavigationRailDestination(
                          icon: Icon(Icons.groups_outlined),
                          selectedIcon: Icon(Icons.groups),
                          label: Text('Classes'),
                        ),
                        const NavigationRailDestination(
                          icon: Icon(Icons.face_outlined),
                          selectedIcon: Icon(Icons.face),
                          label: Text('Enrolment'),
                        ),
                      ] else
                        const NavigationRailDestination(
                          icon: Icon(Icons.groups_outlined),
                          selectedIcon: Icon(Icons.groups),
                          label: Text('Classes'),
                        ),
                      const NavigationRailDestination(
                        icon: Icon(Icons.person_outline),
                        selectedIcon: Icon(Icons.person),
                        label: Text('Account'),
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

class AuthFrame extends StatelessWidget {
  const AuthFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });
  final String title, subtitle;
  final Widget child;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 900;
          final brand = Container(
            padding: const EdgeInsets.all(36),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xff102f32),
                  Color(0xff146b59),
                  Color(0xff26947a),
                ],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(
                  children: [
                    Icon(
                      Icons.center_focus_strong,
                      color: Colors.white,
                      size: 30,
                    ),
                    SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        'FaceTrack',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 23,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                if (wide) ...[
                  const SizedBox(height: 80),
                  const Icon(
                    Icons.auto_awesome_outlined,
                    color: Color(0xffbbe9af),
                    size: 44,
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Attendance, with clarity.',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.w800,
                      height: 1.1,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'A calmer way to manage classes, enrolment and attendance.',
                    style: TextStyle(
                      color: Color(0xffd5e9e2),
                      fontSize: 16,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          );
          final form = ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Panel(
              padding: wide ? 40 : 26,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -.7,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 30),
                  child,
                ],
              ),
            ),
          );
          return SingleChildScrollView(
            padding: EdgeInsets.all(wide ? 28 : 18),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (c.maxHeight - (wide ? 56 : 36)).clamp(
                  0,
                  double.infinity,
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: wide
                      ? Row(
                          children: [
                            Expanded(child: brand),
                            const SizedBox(width: 28),
                            Expanded(child: form),
                          ],
                        )
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [brand, const SizedBox(height: 16), form],
                        ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );
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
  Widget build(BuildContext context) => AuthFrame(
    title: 'Welcome back',
    subtitle: 'Sign in to ' + ref.read(servicesProvider).config.title + '.',
    child: AutofillGroup(
      child: Form(
        key: form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: email,
              enabled: !busy,
              decoration: const InputDecoration(labelText: 'Email address'),
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
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: busy ? null : login,
              child: Text(busy ? 'Signing in…' : 'Sign in'),
            ),
            const SizedBox(height: 16),
            const Text(
              'Use your institute-approved account. Contact your institute for account help.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
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

class AccountPage extends ConsumerWidget {
  const AccountPage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider), person = auth.person;
    return ContentPage(
      children: [
        const PageHeader(
          title: 'Your account',
          subtitle: 'Your institute-approved identity.',
        ),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                person?.name ?? 'Account',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                ref.read(servicesProvider).client.auth.currentUser?.email ?? '',
              ),
              const SizedBox(height: 12),
              Text('Institute: ' + auth.instituteName),
              const SizedBox(height: 12),
              Text('ID: ' + (person?.number ?? '')),
              const SizedBox(height: 24),
              const StatusBadge('active'),
            ],
          ),
        ),
        const SizedBox(height: 24),
        if (auth.memberships.length > 1)
          OutlinedButton(
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
            child: const Text('Switch institute'),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () => auth.signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign out'),
          ),
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
