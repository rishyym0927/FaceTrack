import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_teacher/teacher_classes.dart';
import 'package:facetrack_teacher/teacher_notifications.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../packages/app_core/test/harness.dart';

Json _row(String id, String status, {String? code}) => {
  'student_id': id,
  'official_name': 'Student $id',
  'enrollment_number': '00$id',
  'status': status,
  'recognition_eligible': true,
  'assessment_code': ?code,
};

void main() {
  test('The step tracker follows the session status', () {
    expect(SessionSteps.current('scheduled', false), 0);
    expect(SessionSteps.current('open', false), 1);
    expect(SessionSteps.current('open', true), 2);
    expect(SessionSteps.current('review_required', true), 3);
    expect(SessionSteps.current('no_data', false), 3);
    expect(SessionSteps.current('finalized', true), SessionSteps.steps.length);
    expect(SessionSteps.current('cancelled', false), -1);
  });

  test('Decision counts use the teacher choice over the suggestion', () {
    final rows = [
      _row('1', 'proposed_present'),
      _row('2', 'proposed_absent'),
      _row('3', 'unassessed'),
      _row('4', 'late'),
    ];
    final before = DecisionCounts.of(rows, {});
    expect([before.present, before.absent, before.toCheck], [1, 0, 3]);
    final after = DecisionCounts.of(rows, {'1': 'present', '2': 'absent'});
    expect([after.present, after.absent, after.toCheck], [2, 1, 1]);
  });

  test('Published note says corrections, not revision numbers', () {
    expect(publishedNote(1), 'Published · students can see their attendance');
    expect(publishedNote(3), endsWith('corrected 2 times'));
  });

  for (final width in const [360.0, 1280.0]) {
    testWidgets(
      'Review: banner, steps, pinned bar and publish summary at ${width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = (await tester.runAsync(
          () => harness(role: AppRole.teacher, profileRole: 'teacher'),
        ))!;
        addTearDown(() => tester.runAsync(h.dispose));
        Map<String, String>? submitted;
        h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
          if (r.path == '/v1/me') return jsonResponse(h.account);
          if (r.path == '/v1/offerings/class') {
            return jsonResponse({
              'id': 'class',
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
          if (r.path == '/v1/sessions/session/finalize') {
            submitted = {
              for (final mark in (r.data as Json)['decisions'] as List)
                mark['student_id'] as String: mark['status'] as String,
            };
            return jsonResponse({'id': 'publication'});
          }
          if (r.path == '/v1/sessions/session/attendance') {
            return jsonResponse({
              'session': {
                'id': 'session',
                'offering_id': 'class',
                'status': submitted == null ? 'review_required' : 'finalized',
                'starts_at': '2026-10-30T05:00:00Z',
                'ends_at': '2026-10-30T06:00:00Z',
                'room_label': 'E301',
                'version': 1,
                'attendance_revision': submitted == null ? 0 : 1,
              },
              'items': [
                _row(
                  '1',
                  submitted?['1'] ?? 'proposed_present',
                  code: 'matched',
                ),
                _row(
                  '2',
                  submitted?['2'] ?? 'unassessed',
                  code: 'limited_capture',
                ),
                _row(
                  '3',
                  submitted?['3'] ?? 'proposed_absent',
                  code: 'not_recognized',
                ),
              ],
            });
          }
          return jsonResponse({'items': [], 'next_cursor': null});
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(h.services)],
            child: ProductApp(
              classesBuilder: (_) => Builder(
                builder: (context) => TextButton(
                  onPressed: () => context.go('/sessions/session'),
                  child: const Text('Open session fixture'),
                ),
              ),
              sessionBuilder: (_, id) => TeacherSessionDetail(id: id),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Open session fixture'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Discrete Mathematics'), findsOneWidget);
        expect(find.text('E301'), findsOneWidget);
        expect(find.text('Ready for review'), findsWidgets);
        // The bar is pinned: Publish is on screen without scrolling.
        final publish = find.widgetWithText(FilledButton, 'Publish attendance');
        expect(publish, findsOneWidget);
        expect(tester.getRect(publish).bottom, lessThanOrEqualTo(2400));
        expect(tester.widget<FilledButton>(publish).onPressed, isNotNull);
        await tester.tap(publish);
        await tester.pumpAndSettle();
        expect(submitted, {'1': 'present', '2': 'absent', '3': 'absent'});
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Home subject cards show pending work and the next class', (
    tester,
  ) async {
    final o = Offering.fromJson({
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
    final now = DateTime(2026, 10, 31, 9);
    final w = SubjectWork(o)
      ..joinRequests = 2
      ..sessions = [
        {'status': 'review_required', 'starts_at': '2026-10-30T05:00:00Z'},
        {
          'status': 'scheduled',
          'starts_at': DateTime(2026, 11, 3, 10, 30).toUtc().toIso8601String(),
          'ends_at': DateTime(2026, 11, 3, 11, 30).toUtc().toIso8601String(),
        },
      ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubjectWorkChips(work: w, now: now),
        ),
      ),
    );
    expect(find.text('1 session to review'), findsOneWidget);
    expect(find.text('2 join requests'), findsOneWidget);
    expect(find.textContaining('Next class:'), findsOneWidget);
    expect(find.text('All caught up'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SubjectWorkChips(work: SubjectWork(o), now: now),
        ),
      ),
    );
    expect(find.text('All caught up'), findsOneWidget);
  });

  testWidgets('Manual review requires a mark for every student', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/sessions/session/attendance') {
        return jsonResponse({
          'session': {
            'id': 'session',
            'offering_id': 'class',
            'status': 'no_data',
            'starts_at': '2026-10-30T05:00:00Z',
            'version': 1,
            'attendance_revision': 0,
          },
          'items': [
            _row('1', 'present'),
            _row('2', 'absent'),
            _row('3', 'unassessed'),
          ],
        });
      }
      return jsonResponse({'items': [], 'next_cursor': null});
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(
          classesBuilder: (_) => Builder(
            builder: (context) => TextButton(
              onPressed: () => context.go('/sessions/session'),
              child: const Text('Open session fixture'),
            ),
          ),
          sessionBuilder: (_, id) => TeacherSessionDetail(id: id),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open session fixture'));
    await tester.pumpAndSettle();
    final publish = find.widgetWithText(FilledButton, 'Publish attendance');
    expect(tester.widget<FilledButton>(publish).onPressed, isNull);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Absent').at(2));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(publish).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });
}
