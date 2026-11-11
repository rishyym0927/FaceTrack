import 'dart:async';

import 'package:dio/dio.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_classes.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

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

RoutesAdapter _adapter(Harness h) => RoutesAdapter((r) async {
  if (r.path == '/v1/offerings/o1/attendance-disputes') {
    return jsonResponse({
      'error': {'code': 'UNAVAILABLE'},
    }, 503);
  }
  if (r.path == '/v1/me') return jsonResponse(h.account);
  if (r.path == '/v1/offerings/o1') {
    return jsonResponse({
      'id': 'o1',
      'title': 'Discrete Mathematics',
      'course_code': 'BAS 201',
      'term_code': '2026-ODD',
      'branch': 'CSE',
      'semester': 3,
      'section': 'CSE1',
      'version': 1,
      'status': 'active',
    });
  }
  if (r.path == '/v1/offerings/o1/roster') {
    final requested = r.queryParameters['status'] == 'requested';
    return jsonResponse({
      'items': requested
          ? [_person('1', 'Asha Verma', 'requested')]
          : [
              _person('2', 'Bina Rao', 'active'),
              _person('3', 'Chitra Das', 'active'),
            ],
      'next_cursor': null,
    });
  }
  if (r.path == '/v1/sessions') {
    return jsonResponse({
      'items': [
        _session('a', 'review_required', '10-30'),
        _session('b', 'scheduled', '11-03'),
        _session('c', 'finalized', '10-27'),
        _session('d', 'cancelled', '10-20'),
      ],
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
      if (request.path != '/v1/offerings/o1/attendance-disputes') {
        return base.handler(request);
      }
      if (++disputeCalls == 1) return older.future;
      return jsonResponse({
        'items': [
          {'id': 'new-query'},
        ],
        'next_cursor': null,
      });
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
    older.complete(jsonResponse({'items': [], 'next_cursor': null}));
    await tester.pumpAndSettle();
    expect(find.text('1 open query'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

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
        expect(find.text('Could not load attendance queries.'), findsOneWidget);
        expect(find.text('Retry counts'), findsOneWidget);
        expect(find.textContaining('All caught up'), findsNothing);
        // Sessions are grouped by what to do next, with filters.
        expect(find.text('Needs your action'), findsOneWidget);
        expect(find.text('Upcoming'), findsWidgets);
        expect(find.text('Review attendance'), findsOneWidget);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Published 1'));
        await tester.pumpAndSettle();
        expect(find.text('Needs your action'), findsNothing);
        expect(find.text('View attendance'), findsOneWidget);
        // The join-request chip opens Students, with requests first.
        await tester.tap(find.text('1 join request'));
        await tester.pumpAndSettle();
        expect(find.text('Waiting for approval · 1'), findsOneWidget);
        expect(find.text('Asha Verma'), findsOneWidget);
        expect(find.text('Bina Rao'), findsOneWidget);
        expect(find.text('Approve'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
