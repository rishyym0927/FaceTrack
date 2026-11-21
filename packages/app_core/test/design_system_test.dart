import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<void> _pump(WidgetTester t, Widget child, double width, double scale) async {
  t.view.physicalSize = Size(width, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  await t.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      builder: (context, c) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
        child: c!,
      ),
      home: Scaffold(body: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(16), child: child))),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  for (final width in [360.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Empty, skeleton and pill widgets fit $width at $scale x text', (t) async {
        await _pump(
          t,
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              EmptyState(
                icon: Icons.inbox_outlined,
                title: 'Nothing here yet',
                message: 'Add the first record to see it listed here.',
                action: FilledButton(onPressed: () {}, child: const Text('Add')),
              ),
              const SizedBox(height: 12),
              const EmptyState(compact: true, icon: Icons.search_off, title: 'No matches'),
              const SizedBox(height: 12),
              const SkeletonStatGrid(),
              const SizedBox(height: 12),
              const SkeletonPanel(),
              const SizedBox(height: 12),
              const Wrap(spacing: 8, children: [
                TonePill('Login linked', tone: AppTone.success, icon: Icons.check),
                TonePill('Up next', tone: AppTone.warning),
                TonePill('Needs attention', tone: AppTone.danger),
              ]),
            ],
          ),
          width,
          scale,
        );
        expect(t.takeException(), isNull);
        expect(find.text('Nothing here yet'), findsOneWidget);
        expect(find.byType(SkeletonRows), findsOneWidget);
      });
    }
  }

  testWidgets('A failure with no message still reads in plain language', (t) async {
    var retried = false;
    await _pump(t, ErrorView(Object(), retry: () => retried = true), 390, 1);
    expect(find.text('Could not load this page'), findsOneWidget);
    expect(find.textContaining('try again in a moment'), findsOneWidget);
    await t.tap(find.text('Retry'));
    expect(retried, isTrue);
  });

  testWidgets('Wide screens get a labelled sidebar, narrower ones a slim rail', (t) async {
    final h = (await t.runAsync(() => harness()))!;
    addTearDown(() => t.runAsync(h.dispose));
    t.view.physicalSize = const Size(1440, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    await t.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(classesBuilder: (_) => const Text('Classes content')),
      ),
    );
    await t.pumpAndSettle();
    expect(t.widget<NavigationRail>(find.byType(NavigationRail)).extended, isTrue);
    expect(find.text('Subjects'), findsWidgets);
    t.view.physicalSize = const Size(900, 900);
    await t.pumpAndSettle();
    expect(t.widget<NavigationRail>(find.byType(NavigationRail)).extended, isFalse);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
