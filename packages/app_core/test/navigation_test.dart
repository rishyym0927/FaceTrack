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
}
