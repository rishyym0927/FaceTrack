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

  Future<NotificationCenter> centerWith(
    WidgetTester tester,
    List<AppNotice> items,
  ) async {
    final center = NotificationCenter((_, _, _) async => NoticeBatch(const []));
    await tester.runAsync(
      () => center.reload('student.u.i', () async => NoticeBatch(items)),
    );
    return center;
  }

  Future<void> pumpCard(WidgetTester tester, NotificationCenter center) =>
      tester.pumpWidget(
        MaterialApp(
          home: NotificationScope(
            notifier: center,
            child: const Scaffold(body: AttentionCard()),
          ),
        ),
      );

  const update = AppNotice(
    id: 'pub:1',
    title: 'Attendance published: Data Structures',
    body: 'You were marked Present.',
    tone: NoticeTone.success,
    icon: Icons.event_available_outlined,
  );

  testWidgets('An unread update shows on the card, matching the badge', (
    tester,
  ) async {
    final center = await centerWith(tester, [update]);
    expect(center.unread, 1);
    await pumpCard(tester, center);
    expect(find.text('No actions needed · 1 new'), findsOneWidget);
    expect(find.text(update.title), findsOneWidget);
    expect(find.text('You are all set'), findsNothing);
    await tester.tap(find.text('Mark all read'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(center.unread, 0);
    expect(find.text('You are all set'), findsOneWidget);
    expect(find.text('Mark all read'), findsNothing);
  });

  testWidgets('Actions come before updates on the card', (tester) async {
    final center = await centerWith(tester, [
      update,
      const AppNotice(
        id: 'face:none',
        title: 'Set up face enrolment',
        body: 'b',
        tone: NoticeTone.action,
        icon: Icons.face_outlined,
      ),
    ]);
    await pumpCard(tester, center);
    expect(find.text('Needs your attention · 1'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Set up face enrolment')).dy,
      lessThan(tester.getTopLeft(find.text(update.title)).dy),
    );
  });
}
