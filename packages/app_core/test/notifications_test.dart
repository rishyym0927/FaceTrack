import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

AppNotice notice(String id, NoticeTone tone, {DateTime? time, String? route}) =>
    AppNotice(
      id: id,
      title: 'Title $id',
      body: 'Body $id',
      tone: tone,
      icon: Icons.info_outline,
      time: time,
      route: route,
    );

NotificationCenter center() =>
    NotificationCenter((_, _, _) async => NoticeBatch(const []));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Actions come first, then warnings, then updates, newest first', () {
    final sorted = sortNotices([
      notice('old-update', NoticeTone.info, time: DateTime(2026, 10, 1)),
      notice('warn', NoticeTone.warning),
      notice('new-update', NoticeTone.success, time: DateTime(2026, 10, 2)),
      notice('act', NoticeTone.action),
    ]);
    expect(sorted.map((n) => n.id), [
      'act',
      'warn',
      'new-update',
      'old-update',
    ]);
  });

  test('Ages read naturally', () {
    final now = DateTime(2026, 10, 27, 12);
    expect(noticeAge(now, now: now), 'Just now');
    expect(
      noticeAge(now.subtract(const Duration(minutes: 5)), now: now),
      '5 min ago',
    );
    expect(
      noticeAge(now.subtract(const Duration(hours: 3)), now: now),
      '3 h ago',
    );
    expect(noticeAge(DateTime(2026, 9, 1), now: now), '1 Sep 2026');
  });

  test(
    'Read state is per account, survives reloads and forgets stale ids',
    () async {
      final c = center();
      await c.reload(
        'teacher.u1.i1',
        () async => NoticeBatch([
          notice('a', NoticeTone.action),
          notice('b', NoticeTone.info),
        ]),
      );
      expect(c.unread, 2);
      await c.markRead(c.items.first);
      expect(c.unread, 1);

      // Same account: "a" stays read; "b" disappeared so it is forgotten.
      await c.reload(
        'teacher.u1.i1',
        () async => NoticeBatch([
          notice('a', NoticeTone.action),
          notice('c', NoticeTone.info),
        ]),
      );
      expect(c.unread, 1);
      await c.markAllRead();
      expect(c.unread, 0);

      // Another account on the same device starts unread.
      await c.reload(
        'teacher.u2.i1',
        () async => NoticeBatch([notice('a', NoticeTone.action)]),
      );
      expect(c.unread, 1);

      // A fresh centre for the first account restores its read state.
      final again = center();
      await again.reload(
        'teacher.u1.i1',
        () async => NoticeBatch([
          notice('a', NoticeTone.action),
          notice('c', NoticeTone.info),
        ]),
      );
      expect(again.unread, 0);
    },
  );

  test('A failing loader is reported, not thrown', () async {
    final c = center();
    await c.reload('student.u1.i1', () async => throw Exception('offline'));
    expect(c.items, isEmpty);
    expect(c.failed, isNotEmpty);
    expect(c.loading, isFalse);
  });

  test('One failing source does not hide the others', () async {
    final collector = NoticeCollector();
    await collector.source('good', () async => [notice('ok', NoticeTone.info)]);
    await collector.source('bad', () async => throw Exception('403'));
    final batch = collector.done();
    expect(batch.items.single.id, 'ok');
    expect(batch.failed, ['bad']);
  });

  for (final size in const [Size(360, 640), Size(768, 1024), Size(1440, 900)]) {
    testWidgets(
      'Panel holds at ${size.width.toInt()} px with 200% text and marks items read',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = center();
        await tester.runAsync(
          () => c.reload(
            'teacher.u1.i1',
            () async => NoticeBatch(
              [
                notice('act', NoticeTone.action, time: DateTime.now()),
                notice('upd', NoticeTone.success),
              ],
              failed: ['sessions (BCS 201)'],
              note: 'Checked the first 20 of 30 subjects.',
            ),
          ),
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: NotificationsPage(center: c, refresh: () {}),
              ),
            ),
          ),
        );
        expect(find.text('Notifications'), findsOneWidget);
        expect(find.text('2 unread'), findsOneWidget);
        expect(find.text('Needs attention · 1'), findsOneWidget);
        expect(find.textContaining('could not be loaded'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Title upd'));
      await tester.pump();
        await tester.tap(find.text('Title upd'));
        await tester.pump();
        expect(find.text('1 unread'), findsOneWidget);
        await tester.ensureVisible(find.text('Mark all as read'));
      await tester.pump();
      await tester.tap(find.text('Mark all as read'));
        await tester.pump();
        expect(find.text('You are all caught up.'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Bell shows the unread count', (tester) async {
    final c = center();
    await tester.runAsync(
      () => c.reload(
        'student.u1.i1',
        () async => NoticeBatch([notice('a', NoticeTone.action)]),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(actions: [NotificationBell(center: c)]),
        ),
      ),
    );
    expect(find.byTooltip('Notifications, 1 unread'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });

  test('Updates group by day, with current states first', () {
    final now = DateTime(2026, 10, 31, 12);
    AppNotice n(String id, DateTime? t) => AppNotice(
      id: id,
      title: id,
      body: '',
      tone: NoticeTone.success,
      icon: Icons.check,
      time: t,
    );
    final groups = groupByDay([
      n('old', DateTime(2026, 10, 1)),
      n('today', DateTime(2026, 10, 31, 9)),
      n('now', null),
      n('yday', DateTime(2026, 10, 30, 18)),
      n('week', DateTime(2026, 10, 27)),
    ], now: now);
    expect([for (final g in groups) g.$1], ['Current', 'Today', 'Yesterday', 'This week', 'Earlier']);
  });

  testWidgets('Swiping an unread notice marks it read and keeps it listed', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final center = NotificationCenter((_, _, _) async => NoticeBatch(const []));
    await tester.runAsync(
      () => center.reload(
        'student.u.i',
        () async => NoticeBatch([
          AppNotice(
            id: 'pub:1',
            title: 'Attendance published',
            body: 'You were marked Present.',
            tone: NoticeTone.success,
            icon: Icons.check,
            time: DateTime.now(),
          ),
        ]),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NotificationsPage(center: center, refresh: () {})),
      ),
    );
    await tester.pumpAndSettle();
    expect(center.unread, 1);
    await tester.drag(find.text('Attendance published'), const Offset(-500, 0));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(center.unread, 0);
    expect(find.text('Attendance published'), findsOneWidget);
    expect(find.text('Today · 1'), findsOneWidget);
  });
}
