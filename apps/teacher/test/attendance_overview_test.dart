import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/attendance_overview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

Map<String, dynamic> _summary() => {
  'offering_id': 'class',
  'sessions_conducted': 4,
  'students': [
    {
      'student_id': 's1',
      'official_name': 'Alice',
      'enrollment_number': 'EN001',
      'present': 4, 'late': 0, 'absent': 0, 'unassessed': 0, 'excused': 0,
      'conducted': 4, 'attended': 4, 'assessed': 4, 'percentage': 100.0,
    },
    {
      'student_id': 's2',
      'official_name': 'Bob',
      'enrollment_number': 'EN002',
      'present': 2, 'late': 0, 'absent': 2, 'unassessed': 0, 'excused': 0,
      'conducted': 4, 'attended': 2, 'assessed': 4, 'percentage': 50.0,
    },
  ],
  'policy_version': 'session-v1',
};

Future<void> _pump(WidgetTester tester, h) async {
  tester.view.physicalSize = const Size(1100, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AttendanceOverview(
            api: h.services.api,
            institute: institute,
            offering: 'class',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Shows per-student totals and percentages', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/offerings/class/attendance-summary') {
        return jsonResponse(_summary());
      }
      return jsonResponse({});
    });
    await _pump(tester, h);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('100.0%'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.textContaining('4 classes conducted'), findsOneWidget);
  });

  testWidgets('Below-75% filter keeps only low-attendance students',
      (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/offerings/class/attendance-summary') {
        return jsonResponse(_summary());
      }
      return jsonResponse({});
    });
    await _pump(tester, h);
    await tester.tap(find.widgetWithText(FilterChip, 'Below 75%'));
    await tester.pumpAndSettle();
    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('Alice'), findsNothing);
  });

  testWidgets('Search filters by name', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/offerings/class/attendance-summary') {
        return jsonResponse(_summary());
      }
      return jsonResponse({});
    });
    await _pump(tester, h);
    await tester.enterText(find.byType(TextField), 'Alice');
    await tester.pumpAndSettle();
    // 'Alice' now also appears inside the search field, so just assert the
    // non-matching student is filtered out.
    expect(find.text('Bob'), findsNothing);
    expect(find.text('Alice'), findsWidgets);
  });
}
