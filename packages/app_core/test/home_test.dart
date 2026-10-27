import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Greeting follows the time of day and uses the first name', () {
    expect(greeting(DateTime(2026, 10, 28, 9)), 'Good morning');
    expect(greeting(DateTime(2026, 10, 28, 14)), 'Good afternoon');
    expect(greeting(DateTime(2026, 10, 28, 20)), 'Good evening');
    expect(firstName('Asha  Verma'), 'Asha');
    expect(firstName('  '), isNull);
    expect(firstName(null), isNull);
  });

  for (final size in const [Size(360, 640), Size(768, 1024), Size(1440, 900)]) {
    testWidgets('Home pieces hold at ${size.width.toInt()} px with 200% text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final center = NotificationCenter(
        (_, _, _) async => NoticeBatch(const []),
      );
      await tester.runAsync(
        () => center.reload(
          'teacher.u.i',
          () async => NoticeBatch([
            for (var i = 0; i < 5; i++)
              AppNotice(
                id: 'a$i',
                title: 'Review and publish: Data Structures $i',
                body: 'b',
                tone: NoticeTone.action,
                icon: Icons.fact_check_outlined,
              ),
            const AppNotice(
              id: 'u',
              title: 'Update',
              body: 'b',
              tone: NoticeTone.success,
              icon: Icons.check,
            ),
          ]),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: NotificationScope(
              notifier: center,
              child: Scaffold(
                body: ContentPage(
                  children: [
                    HomeHero(
                      title: 'Good morning, Asha',
                      subtitle: 'Open a subject to take attendance.',
                      actions: [
                        FilledButton(
                          onPressed: () {},
                          child: const Text('Add subject'),
                        ),
                        OutlinedButton(
                          onPressed: () {},
                          child: const Text('Refresh'),
                        ),
                      ],
                    ),
                    const AttentionCard(),
                    const SectionTitle('Your subjects'),
                    SubjectTile(
                      title: 'Data Structures',
                      subtitle: 'BCS 201 · CSE · 3rd Semester · Section CSE1',
                      note: 'Odd Semester 2026',
                      status: 'requested',
                      onTap: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Needs your attention · 5'), findsOneWidget);
      // Only the first three urgent items are shown on the home screen.
      expect(find.textContaining('Review and publish'), findsNWidgets(3));
      expect(find.text('Update'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Without notifications the attention card is hidden', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AttentionCard())),
    );
    expect(find.text('All notifications'), findsNothing);
  });
}
