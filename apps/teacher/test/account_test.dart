import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  for (final width in const [360.0, 1280.0]) {
    testWidgets(
      'Faculty account shows profile and teaching stats at ${width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = (await tester.runAsync(
          () => harness(role: AppRole.teacher, profileRole: 'teacher'),
        ))!;
        addTearDown(() => tester.runAsync(h.dispose));
        h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
          if (r.path == '/v1/me') return jsonResponse(h.account);
          if (r.path == '/v1/offerings') {
            return jsonResponse({
              'items': [
                {
                  'id': 'a',
                  'title': 'Data Structures',
                  'course_code': 'CS401',
                  'term_code': '2026-ODD',
                  'branch': 'CSE',
                  'semester': 5,
                  'section': 'A',
                  'version': 1,
                  'status': 'active',
                },
              ],
              'next_cursor': null,
            });
          }
          if (r.path == '/v1/offerings/a/attendance-summary') {
            return jsonResponse({
              'sessions_conducted': 4,
              'policy_version': 'session-v1',
              'students': [
                {
                  'student_id': '1',
                  'official_name': 'Asha',
                  'enrollment_number': '1',
                  'present': 2,
                  'late': 1,
                  'absent': 1,
                  'unassessed': 0,
                  'excused': 1,
                  'conducted': 5,
                  'attended': 3,
                  'assessed': 4,
                  'percentage': 75.0,
                },
              ],
            });
          }
          return jsonResponse({'items': [], 'next_cursor': null});
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(h.services)],
            child: ProductApp(
              classesBuilder: (_) =>
                  AccountPage(statsBuilder: (_) => const TeacherAccountStats()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Teaching at a glance'), findsOneWidget);
        expect(find.text('Employee number'), findsNothing);
        // Late counts as Present; excused folds into Unassessed.
        expect(
          find.text('Marked across your subjects: Present 3 · Absent 1'),
          findsOneWidget,
        );
        expect(find.text('Sign out'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
