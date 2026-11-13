import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_teacher/teacher_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

Map<String, dynamic> _offering(String id, String code, String title, int sem) => {
  'id': id,
  'title': title,
  'course_code': code,
  'term_code': '2026-ODD',
  'branch': 'CSE',
  'semester': sem,
  'section': 'CSE1',
  'version': 1,
  'status': 'active',
};

Map<String, dynamic> _student(String id, String name, int attended, int absent,
        {int unassessed = 0}) =>
    {
      'student_id': id,
      'official_name': name,
      'enrollment_number': 'EN-$id',
      'present': attended, 'late': 0, 'absent': absent,
      'unassessed': unassessed, 'excused': 0,
      'conducted': attended + absent + unassessed,
      'attended': attended,
      'assessed': attended + absent,
      'percentage': attended + absent == 0
          ? null
          : double.parse((100 * attended / (attended + absent)).toStringAsFixed(1)),
    };

Map<String, dynamic> _summary(List<Map<String, dynamic>> students, int held) => {
  'sessions_conducted': held,
  'students': students,
  'policy_version': 'session-v1',
};

void main() {
  test('totals weight by classes, never count unassessed as absence', () {
    final o = Offering.fromJson(_offering('a', 'BCS 201', 'DAA', 3));
    final s = SubjectStats(o, summary: _summary([
      _student('1', 'Asha', 8, 2),
      _student('2', 'Bina', 2, 2, unassessed: 6),
    ], 10));
    final t = DashboardTotals([s]);
    expect(t.attended, 10);
    expect(t.assessed, 14);
    expect(t.overall, closeTo(71.43, .01));
    expect(t.atRiskStudents, 1);
    expect(t.lowest.single.name, 'Bina');
  });

  test('semesters group and label as the institute writes them', () {
    final subjects = [
      SubjectStats(Offering.fromJson(_offering('a', 'BCS 201', 'DAA', 3))),
      SubjectStats(Offering.fromJson(_offering('b', 'BCS 301', 'TOC', 5))),
      SubjectStats(Offering.fromJson(_offering('c', 'BIT 205', 'SW', 3))),
    ];
    final groups = groupBySemester(subjects);
    expect(groups.map((g) => g.label), ['3rd Semester', '5th Semester']);
    expect(groups.first.subjects, hasLength(2));
  });

  testWidgets('Dashboard shows overall, subject-wise and semester filtering',
      (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/teacher/attendance-dashboard') {
        return jsonResponse({
          'items': [
            {
              'offering': _offering('a', 'BCS 201', 'Design and Analysis of Algorithm', 3),
              'summary': _summary([_student('1', 'Asha', 9, 1), _student('2', 'Bina', 5, 5)], 10),
            },
            {
              'offering': _offering('b', 'BCS 301', 'Theory of Computation', 5),
              'summary': _summary([_student('3', 'Chitra', 10, 0)], 10),
            },
          ],
          'next_cursor': null,
        });
      }
      return jsonResponse({});
    });
    tester.view.physicalSize = const Size(1100, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TeacherDashboard(api: h.services.api, institute: institute),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Attendance overview'), findsOneWidget);
    expect(find.text('Design and Analysis of Algorithm'), findsOneWidget);
    expect(find.text('Theory of Computation'), findsOneWidget);
    // 24 attended of 30 assessed across the two loaded subjects.
    expect(find.text('80.0%'), findsWidgets);
    expect(find.text('Bina'), findsOneWidget); // below 75% -> needs attention

    await tester.tap(find.widgetWithText(ChoiceChip, '5th Semester'));
    await tester.pumpAndSettle();
    expect(find.text('Design and Analysis of Algorithm'), findsNothing);
    expect(find.text('Theory of Computation'), findsOneWidget);
    expect(find.text('No student is below the threshold.'), findsOneWidget);
  });

  for (final width in [360.0, 768.0, 1440.0]) {
    testWidgets('Dashboard stays usable at $width and 200% text', (tester) async {
      final h = (await tester.runAsync(
        () => harness(role: AppRole.teacher, profileRole: 'teacher'),
      ))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        return jsonResponse({
          'items': [
            {
              'offering': _offering('a', 'BCS 201', 'Design and Analysis of Algorithm', 3),
              'summary': _summary([
                _student('1', 'Asha Venkataraman-Krishnamurthy', 9, 1),
                _student('2', 'Bina', 5, 5),
              ], 10),
            },
          ],
          'next_cursor': null,
        });
      });
      tester.view.physicalSize = Size(width, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(width, 2600), textScaler: const TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: TeacherDashboard(api: h.services.api, institute: institute),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Attendance overview'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
