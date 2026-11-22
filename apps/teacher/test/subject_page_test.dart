import 'dart:async';

import 'package:dio/dio.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_teacher/teacher_classes.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../packages/app_core/test/harness.dart';

Map<String, dynamic> _session(
  String id,
  String status,
  String day, {
  String room = 'E301',
}) => {
  'id': id,
  'offering_id': 'o1',
  'status': status,
  'starts_at': '2026-$day T05:00:00Z'.replaceAll(' ', ''),
  'ends_at': '2026-$day T06:00:00Z'.replaceAll(' ', ''),
  'room_label': room,
  'version': 1,
};

Map<String, dynamic> _person(String id, String name, String status) => {
  'id': id,
  'offering_id': 'o1',
  'student_id': 's$id',
  'status': status,
  'version': 1,
  'official_name': name,
  'enrollment_number': '00$id',
};

const _offering = {
  'id': 'o1',
  'title': 'Discrete Mathematics',
  'course_code': 'BAS 201',
  'term_code': '2026-ODD',
  'branch': 'CSE',
  'semester': 3,
  'section': 'CSE1',
  'version': 1,
  'status': 'active',
};

Map<String, dynamic> _summary(int queries) => {
  'items': [
    {
      ..._offering,
      'join_requests': 1,
      'face_reviews': 0,
      'open_queries': queries,
      'sessions_to_review': 1,
      'sessions': [],
    },
  ],
  'truncated': false,
};

RoutesAdapter _adapter(Harness h) => RoutesAdapter((r) async {
  if (r.path == '/v1/offerings/o1/attendance-disputes') {
    return jsonResponse({
      'error': {'code': 'UNAVAILABLE'},
    }, 503);
  }
  if (r.path == '/v1/teacher/work-summary') return jsonResponse(_summary(0));
  if (r.path == '/v1/me') return jsonResponse(h.account);
  if (r.path == '/v1/offerings/o1') {
    return jsonResponse(_offering);
  }
  if (r.path == '/v1/offerings/o1/roster') {
    final status = r.queryParameters['status'];
    return jsonResponse({
      'items': switch (status) {
        'requested' => [_person('1', 'Asha Verma', 'requested')],
        'pending_face' => [_person('3', 'Chitra Das', 'active')],
        _ => [_person('2', 'Bina Rao', 'active')],
      },
      'next_cursor': null,
    });
  }
  if (r.path == '/v1/sessions') {
    return jsonResponse({
      'items':
          [
                _session('a', 'review_required', '10-30'),
                _session('b', 'scheduled', '11-03'),
                _session('c', 'finalized', '10-27'),
                _session('d', 'cancelled', '10-20'),
              ]
              .where(
                (row) =>
                    r.queryParameters['group'] == null ||
                    sessionGroup(row).name == r.queryParameters['group'],
              )
              .toList(),
      'next_cursor': null,
    });
  }
  return jsonResponse({'items': [], 'next_cursor': null});
});

void main() {
  test('Sessions fall into the group that says what to do next', () {
    expect(sessionGroup({'status': 'review_required'}), SessionGroup.todo);
    expect(sessionGroup({'status': 'open'}), SessionGroup.todo);
    expect(sessionGroup({'status': 'closed'}), SessionGroup.todo);
    expect(sessionGroup({'status': 'scheduled'}), SessionGroup.upcoming);
    expect(sessionGroup({'status': 'finalized'}), SessionGroup.published);
    expect(sessionGroup({'status': 'cancelled'}), SessionGroup.cancelled);
  });

  testWidgets('Late pending-work response cannot replace refreshed counts', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    final older = Completer<ResponseBody>();
    var disputeCalls = 0;
    final base = _adapter(h);
    h.services.api.dio.httpClientAdapter = RoutesAdapter((request) async {
      if (request.path != '/v1/teacher/work-summary') {
        return base.handler(request);
      }
      if (++disputeCalls == 1) return older.future;
      return jsonResponse(_summary(1));
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(
          classesBuilder: (_) => const TeacherClassDetail(id: 'o1'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(disputeCalls, 1);
    await tester.tap(find.byTooltip('Refresh subject'));
    await tester.pumpAndSettle();
    expect(disputeCalls, 2);
    expect(find.text('1 open query'), findsOneWidget);
    older.complete(jsonResponse(_summary(0)));
    await tester.pumpAndSettle();
    expect(find.text('1 open query'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Real subject route keeps panels and fetches only on first visit',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = (await tester.runAsync(
        () => harness(role: AppRole.teacher, profileRole: 'teacher'),
      ))!;
      addTearDown(() => tester.runAsync(h.dispose));
      final reads = <String, int>{};
      final base = _adapter(h);
      h.services.api.dio.httpClientAdapter = RoutesAdapter((request) {
        reads.update(request.path, (count) => count + 1, ifAbsent: () => 1);
        return base.handler(request);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (context) => TextButton(
              onPressed: () => context.push('/classes/o1?tab=queries'),
              child: const Text('Open subject'),
            ),
            detailBuilder: (_, id) => TeacherClassDetail(id: id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open subject'));
      await tester.pumpAndSettle();
      expect(reads['/v1/sessions'], isNull);
      expect(reads['/v1/offerings/o1/attendance-disputes'], 1);
      await tester.tap(find.text('Sessions'));
      await tester.pumpAndSettle();
      expect(reads['/v1/sessions'], 1);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Published'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Queries'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sessions'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Published'))
            .selected,
        isTrue,
      );
      expect(reads['/v1/sessions'], 2);
      expect(reads['/v1/offerings/o1/attendance-disputes'], 1);
      expect(reads['/v1/offerings/o1'], 1);
      expect(reads['/v1/teacher/work-summary'], 1);
      await tester.tap(find.text('All subjects'));
      await tester.pumpAndSettle();
      expect(find.text('Open subject'), findsOneWidget);
    },
  );

  for (final width in const [360.0, 1280.0]) {
    testWidgets(
      'Subject page: hero, pending work, grouped sessions and tabs at ${width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = Size(width, 3000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = (await tester.runAsync(
          () => harness(role: AppRole.teacher, profileRole: 'teacher'),
        ))!;
        addTearDown(() => tester.runAsync(h.dispose));
        h.services.api.dio.httpClientAdapter = _adapter(h);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(h.services)],
            child: ProductApp(
              classesBuilder: (_) => const TeacherClassDetail(id: 'o1'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Discrete Mathematics'), findsOneWidget);
        expect(find.textContaining('BAS 201'), findsOneWidget);
        expect(find.textContaining('Odd Semester 2026'), findsOneWidget);
        // Pending work is a shortcut to its tab.
        expect(find.text('1 session to review'), findsOneWidget);
        expect(find.text('1 join request'), findsOneWidget);
        expect(find.textContaining('All caught up'), findsNothing);
        // Sessions are grouped by what to do next, with filters.
        expect(find.text('Needs your action'), findsWidgets);
        expect(find.text('Upcoming'), findsWidgets);
        expect(find.text('Review attendance'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Published'));
        await tester.pumpAndSettle();
        expect(find.text('Review attendance'), findsNothing);
        expect(find.text('View attendance'), findsOneWidget);
        // The join-request chip opens Students, with requests first.
        await tester.tap(find.text('1 join request'));
        await tester.pumpAndSettle();
        expect(find.text('Waiting for approval · 1'), findsOneWidget);
        expect(find.text('Asha Verma'), findsOneWidget);
        expect(find.text('Approved students'), findsOneWidget);
        expect(find.text('Bina Rao'), findsOneWidget);
        expect(find.text('Pending face enrolment'), findsOneWidget);
        expect(find.text('Chitra Das'), findsOneWidget);
        expect(find.text('Approve'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final (width, scale, height) in const [
    (320.0, 1.0, 3000.0),
    (390.0, 1.0, 3000.0),
    (320.0, 2.0, 7000.0),
    (390.0, 2.0, 7000.0),
    (800.0, 1.0, 360.0),
  ]) {
    testWidgets(
      'Subject page layout: header, tabs, sessions and students at ${width.toInt()} px, ${scale}x text',
      (tester) async {
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final h = (await tester.runAsync(
          () => harness(role: AppRole.teacher, profileRole: 'teacher'),
        ))!;
        addTearDown(() => tester.runAsync(h.dispose));
        h.services.api.dio.httpClientAdapter = _adapter(h);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(h.services)],
            child: ProductApp(
              classesBuilder: (_) => const TeacherClassDetail(id: 'o1'),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        // Header: name once, code and where once, term and status as pills.
        expect(find.text('Discrete Mathematics'), findsOneWidget);
        expect(find.textContaining('BAS 201'), findsOneWidget);
        expect(find.text('Odd Semester 2026'), findsOneWidget);
        expect(find.text('Active'), findsOneWidget);
        // The student count is hidden until the roster has really loaded.
        expect(find.textContaining('enrolled'), findsNothing);
        expect(find.text('Join code'), findsOneWidget);
        // On the Sessions tab the header offers no duplicate session shortcut.
        expect(find.text('Open sessions'), findsNothing);
        expect(find.text('Create session'), findsWidgets);
        await tester.ensureVisible(find.text('1 join request'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('1 join request'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Open sessions'), findsOneWidget);
        expect(find.text('Waiting for approval · 1'), findsOneWidget);
        expect(find.text('Awaiting approval'), findsOneWidget);
        expect(find.text('Approved'), findsOneWidget);
        expect(find.text('Face enrolment pending'), findsOneWidget);
        expect(find.text('1 student enrolled'), findsOneWidget);
        expect(find.text('Approve'), findsOneWidget);
        expect(find.text('Decline'), findsOneWidget);
        // Back to Sessions through the header shortcut.
        await tester.ensureVisible(find.text('Open sessions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open sessions'));
        await tester.pumpAndSettle();
        expect(find.text('Open sessions'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  test('A subject accent never depends on anything but its code', () {
    expect(subjectAccent('BAS 201'), subjectAccent('BAS 201'));
    expect(subjectWhere(Offering.fromJson(_offering)), 'Section CSE1 · 3rd Semester · CSE');
  });
}
