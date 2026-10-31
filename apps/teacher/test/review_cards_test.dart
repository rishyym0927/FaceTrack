import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/review_card.dart';
import 'package:facetrack_teacher/teacher_disputes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  test('Initials come from the first two names', () {
    expect(initialsOf('Asha Verma Rao'), 'AV');
    expect(initialsOf('  '), '?');
  });

  for (final width in const [360.0, 1280.0]) {
    testWidgets(
      'A query shows the class, the published result and the student reason at ${width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = Size(width, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = (await tester.runAsync(
          () => harness(role: AppRole.teacher, profileRole: 'teacher'),
        ))!;
        addTearDown(() => tester.runAsync(h.dispose));
        h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
          if (r.path == '/v1/offerings/o1/attendance-disputes') {
            return jsonResponse({
              'items': [
                {
                  'id': 'd1',
                  'session_id': 's1',
                  'student_id': 'st1',
                  'status': 'open',
                  'official_name': 'Asha Verma',
                  'enrollment_number': '0101',
                  'starts_at': '2026-10-30T05:00:00Z',
                  'student_reason': 'I was in the front row.',
                  'version': 1,
                },
              ],
              'next_cursor': null,
            });
          }
          return jsonResponse({'items': [], 'next_cursor': null});
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: TeacherDisputes(
                  api: h.services.api,
                  institute: institute,
                  offering: 'o1',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Asha Verma'), findsOneWidget);
        expect(find.text('Published as Absent'), findsOneWidget);
        expect(find.text('Student says'), findsOneWidget);
        expect(find.text('I was in the front row.'), findsOneWidget);
        expect(find.text('Accept and correct'), findsOneWidget);
      },
    );
  }
}
