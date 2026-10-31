import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'harness.dart';

int instances = 0;

class ResourceProbe extends StatefulWidget {
  const ResourceProbe(this.id, {super.key});
  final String id;
  @override
  State<ResourceProbe> createState() => _ResourceProbeState();
}

class _ResourceProbeState extends State<ResourceProbe> {
  late final int instance = ++instances;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text('${widget.id} instance $instance'),
      TextButton(
        onPressed: () => context.go('/classes/second'),
        child: const Text('Switch class'),
      ),
    ],
  );
}

class SessionProbe extends ConsumerStatefulWidget {
  const SessionProbe(this.id, {super.key});
  final String id;
  @override
  ConsumerState<SessionProbe> createState() => _SessionProbeState();
}

class _SessionProbeState extends ConsumerState<SessionProbe> {
  late final SessionExitGuard guard;
  @override
  void initState() {
    super.initState();
    guard = ref.read(sessionExitGuardProvider)..enter(widget.id);
  }

  @override
  void dispose() {
    guard.leave(widget.id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      const Text('Session fixture'),
      TextButton(
        onPressed: () => guard.dirty = true,
        child: const Text('Change decision'),
      ),
      TextButton(
        onPressed: () => context.go('/classes'),
        child: const Text('Leave session'),
      ),
    ],
  );
}

void main() {
  testWidgets('Changing class IDs creates new screen state', (tester) async {
    instances = 0;
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(
          classesBuilder: (_) => Builder(
            builder: (context) => TextButton(
              onPressed: () => context.go('/classes/first'),
              child: const Text('Open first class'),
            ),
          ),
          detailBuilder: (_, id) => ResourceProbe(id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open first class'));
    await tester.pumpAndSettle();
    expect(find.text('first instance 1'), findsOneWidget);
    await tester.tap(find.text('Switch class'));
    await tester.pumpAndSettle();
    expect(find.text('second instance 2'), findsOneWidget);
  });

  testWidgets('Unsaved session decision warns on route exit', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(
          classesBuilder: (_) => Builder(
            builder: (context) => TextButton(
              onPressed: () => context.go('/sessions/one'),
              child: const Text('Open fixture session'),
            ),
          ),
          sessionBuilder: (_, id) => SessionProbe(id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open fixture session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change decision'));
    await tester.tap(find.text('Leave session'));
    await tester.pumpAndSettle();
    expect(find.text('Discard unsaved decisions?'), findsOneWidget);
    await tester.tap(find.text('Stay'));
    await tester.pumpAndSettle();
    expect(find.text('Session fixture'), findsOneWidget);
    await tester.tap(find.text('Leave session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard changes'));
    await tester.pumpAndSettle();
    expect(find.text('Open fixture session'), findsOneWidget);
  });

  testWidgets('The Attendance tab appears only when the app provides one', (
    tester,
  ) async {
    for (final withTab in [true, false]) {
      final h = (await tester.runAsync(() => harness()))!;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const Text('Subjects page'),
            attendanceBuilder: withTab
                ? (_) => const Text('Attendance page')
                : null,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Attendance'), withTab ? findsOneWidget : findsNothing);
      if (withTab) {
        await tester.tap(find.text('Attendance'));
        await tester.pumpAndSettle();
        expect(find.text('Attendance page'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(h.dispose);
    }
  });

  Future<Harness> ready(WidgetTester tester) async {
    instances = 0;
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    return h;
  }

  Widget app(Harness h, {bool reducedMotion = false}) => ProviderScope(
    overrides: [servicesProvider.overrideWithValue(h.services)],
    child: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: ProductApp(
        classesBuilder: (_) => Builder(
          builder: (context) => Column(
            children: [
              const ResourceProbe('list'),
              TextButton(
                onPressed: () => context.push('/classes/first'),
                child: const Text('Open first class'),
              ),
            ],
          ),
        ),
        detailBuilder: (_, id) => Builder(
          builder: (context) => TextButton(
            onPressed: () => goBack(context, '/classes'),
            child: Text('Back from $id'),
          ),
        ),
      ),
    ),
  );

  testWidgets('Tabs cross-fade: both pages show mid-way, then only the new one', (
    tester,
  ) async {
    final h = await ready(tester);
    await tester.pumpWidget(app(h));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Account'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(find.textContaining('list instance'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(of: find.text('Sign out'), matching: find.byType(FadeTransition)),
    );
    expect(fades.any((f) => f.opacity.value < 1), isTrue);
    await tester.pumpAndSettle();
    expect(find.textContaining('list instance'), findsNothing);
    expect(find.text('Sign out'), findsOneWidget);
  });

  testWidgets('A subject slides over the kept-alive list and back pops to it', (
    tester,
  ) async {
    final h = await ready(tester);
    await tester.pumpWidget(app(h));
    await tester.pumpAndSettle();
    expect(find.text('list instance 1'), findsOneWidget);
    await tester.tap(find.text('Open first class'));
    await tester.pumpAndSettle();
    expect(find.text('Back from first'), findsOneWidget);
    await tester.tap(find.text('Back from first'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    // Mid-pop: the detail is still sliding out over the list.
    expect(find.text('Back from first'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Back from first'), findsNothing);
    // Same list state, not a rebuilt page.
    expect(find.text('list instance 1'), findsOneWidget);
  });

  testWidgets('With reduced motion pages change in a single frame', (tester) async {
    final h = await ready(tester);
    await tester.pumpWidget(app(h, reducedMotion: true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open first class'));
    await tester.pump();
    await tester.pump();
    final fades = tester.widgetList<FadeTransition>(
      find.ancestor(of: find.text('Back from first'), matching: find.byType(FadeTransition)),
    );
    expect(fades, isEmpty);
    await tester.pumpAndSettle();
  });

  testWidgets('goBack falls back when there is nothing to pop', (tester) async {
    final router = GoRouter(
      initialLocation: '/b',
      routes: [
        GoRoute(path: '/a', builder: (_, _) => const Text('Page A')),
        GoRoute(
          path: '/b',
          builder: (context, _) => TextButton(
            onPressed: () => goBack(context, '/a'),
            child: const Text('Back'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Page A'), findsOneWidget);
  });
}
