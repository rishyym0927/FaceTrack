import 'dart:async';

import 'package:dio/dio.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_classes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

Map<String, dynamic> _offering(
  String id,
  String title,
  String code, {
  String section = 'CSE1',
  String status = 'active',
}) => {
  'id': id,
  'title': title,
  'course_code': code,
  'term_code': '2026-ODD',
  'branch': 'CSE',
  'semester': 3,
  'section': section,
  'version': 1,
  'status': status,
};

final _items = [
  _offering('o1', 'Discrete Mathematics', 'BAS 201'),
  _offering(
    'o2',
    'Introduction to Data Structures and Algorithms with Laboratory',
    'BCS 301',
    section: 'ALL',
  ),
  _offering(
    'o3',
    'Engineering Physics',
    'BAS 101',
    section: 'CSE2',
    status: 'archived',
  ),
];

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  double height = 3000,
  double textScale = 1,
  Future<ResponseBody> Function(RequestOptions)? offerings,
  NotificationsLoader? notices,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final h = (await tester.runAsync(
    () => harness(role: AppRole.teacher, profileRole: 'teacher'),
  ))!;
  addTearDown(() => tester.runAsync(h.dispose));
  h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
    if (r.path == '/v1/me') return jsonResponse(h.account);
    if (r.path == '/v1/offerings') {
      return offerings != null
          ? offerings(r)
          : jsonResponse({'items': _items, 'next_cursor': null});
    }
    return jsonResponse({'items': [], 'next_cursor': null});
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(h.services)],
      child: ProductApp(
        classesBuilder: (_) => const TeacherClasses(),
        notificationsLoader: notices,
      ),
    ),
  );
}

void main() {
  test('Subject accent depends only on the code', () {
    expect(subjectAccent('BAS 201'), subjectAccent(' bas 201 '));
    expect(subjectAccent('BCS 301'), subjectAccent('BCS 301'));
    final colours = {
      for (final c in ['BAS 201', 'BCS 301', 'BAS 101', 'MAT 110', 'PHY 220'])
        subjectAccent(c),
    };
    expect(colours.length, greaterThan(1));
    expect(subjectGlyph('BAS 201'), 'BAS');
    expect(subjectGlyph('MATH101'), 'MAT');
    expect(subjectGlyph('101'), '');
  });

  for (final (width, scale, height) in const [
    (320.0, 1.0, 3000.0),
    (390.0, 1.0, 3000.0),
    (320.0, 2.0, 6000.0),
    (390.0, 2.0, 6000.0),
    (800.0, 1.0, 360.0),
    (1440.0, 1.0, 1600.0),
  ]) {
    testWidgets(
      'Subject cards: code, name, where and status without overflow at ${width.toInt()} px, ${scale}x text',
      (tester) async {
        await _pump(tester, width: width, height: height, textScale: scale);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Subjects'), findsWidgets);
        expect(find.text('Discrete Mathematics'), findsOneWidget);
        expect(find.text('BAS 201'), findsOneWidget);
        expect(find.text('Section CSE1 · 3rd Semester · CSE'), findsOneWidget);
        // No section line for "ALL"; the term and status are real offering fields.
        expect(find.text('3rd Semester · CSE'), findsOneWidget);
        expect(find.text('Odd Semester 2026'), findsWidgets);
        expect(find.text('Active'), findsWidgets);
        expect(find.text('Archived'), findsOneWidget);
        // The notifications section is gone from this tab.
        expect(find.byType(AttentionCard), findsNothing);
        expect(find.text('Needs attention'), findsNothing);
        expect(find.byType(SubjectCard), findsNWidgets(3));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('A subject card is a large tap target that opens the subject', (
    tester,
  ) async {
    await _pump(tester, width: 360);
    await tester.pumpAndSettle();
    final size = tester.getSize(find.byType(SubjectCard).first);
    expect(size.height, greaterThanOrEqualTo(48));
    expect(size.width, greaterThan(300));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('A subject with waiting work shows a pill on its own card only', (
    tester,
  ) async {
    await _pump(
      tester,
      width: 390,
      notices: (api, institute, auth) async => NoticeBatch([
        const AppNotice(
          id: 'join:o1:1',
          title: '1 join request',
          body: 'Waiting',
          tone: NoticeTone.action,
          icon: Icons.person_add_alt,
          route: '/classes/o1?tab=students',
        ),
        const AppNotice(
          id: 'info:o2',
          title: 'FYI',
          body: 'Info',
          tone: NoticeTone.info,
          icon: Icons.info_outline,
          route: '/classes/o2',
        ),
      ]),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text('Needs attention'), findsOneWidget);
    // Still no notifications section on the list.
    expect(find.byType(AttentionCard), findsNothing);
    expect(find.text('1 join request'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Loading shows skeleton cards, then an error can be retried', (
    tester,
  ) async {
    final pending = Completer<ResponseBody>();
    var calls = 0;
    await _pump(
      tester,
      width: 360,
      offerings: (r) {
        calls++;
        return calls == 1
            ? pending.future
            : Future.value(jsonResponse({'items': _items, 'next_cursor': null}));
      },
    );
    await tester.pumpAndSettle();
    expect(find.byType(SkelBox), findsWidgets);
    expect(find.byType(SubjectCard), findsNothing);
    pending.complete(
      jsonResponse({
        'error': {'code': 'UNAVAILABLE', 'message': 'Try later'},
      }, 503),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byType(SubjectCard), findsNWidgets(3));
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in const [320.0, 390.0]) {
    testWidgets('Empty state invites the first subject at ${width.toInt()} px', (
      tester,
    ) async {
      await _pump(
        tester,
        width: width,
        textScale: 2,
        offerings: (_) async => jsonResponse({'items': [], 'next_cursor': null}),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('No subjects yet'), findsOneWidget);
      expect(find.text('Add your first subject'), findsOneWidget);
      expect(find.byType(SubjectCard), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
