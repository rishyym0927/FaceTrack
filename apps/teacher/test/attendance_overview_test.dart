import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/attendance_overview.dart';
import 'package:facetrack_teacher/teacher_dashboard.dart' show belowAttendanceThreshold;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_models/facetrack_models.dart';

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
  testWidgets('Temporary failure retains attendance but access loss clears it', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var status = 200;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/offerings/class/attendance-summary') {
        return status == 200
            ? jsonResponse(_summary())
            : jsonResponse({'code': 'ERROR', 'message': 'Unavailable'}, status);
      }
      return jsonResponse({});
    });
    await _pump(tester, h);
    expect(find.text('Alice'), findsOneWidget);
    status = 503;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    status = 403;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsNothing);
  });

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

  testWidgets('Student table fills a wide page and keeps all columns', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter(
      (r) async => jsonResponse(_summary()),
    );
    tester.view.physicalSize = const Size(1440, 1400);
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
    // The % column sits at the right edge of the card, not at 620 px.
    expect(tester.getTopRight(find.text('%')).dx, greaterThan(1100));
    expect(find.text('Below 75%'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('A subject with no published sessions explains what to do', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter(
      (r) async => jsonResponse({
        'offering_id': 'class',
        'sessions_conducted': 0,
        'students': <Object>[],
      }),
    );
    await _pump(tester, h);
    expect(find.text('No published sessions yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('student filtering and sorting', () {
    Json st(String name, String en, int attended, int absent, {int un = 0}) => {
      'official_name': name,
      'enrollment_number': en,
      'present': attended,
      'late': 0,
      'absent': absent,
      'unassessed': un,
      'excused': 0,
      'attended': attended,
      'assessed': attended + absent,
      'percentage': attended + absent == 0
          ? null
          : double.parse((100 * attended / (attended + absent)).toStringAsFixed(1)),
    };
    final roster = [
      st('Zoya', 'EN003', 9, 1),
      st('Alice', 'EN001', 4, 4),
      st('Mohan', 'EN002', 0, 0, un: 3), // nothing assessed yet
      st('Bob', 'EN004', 3, 1),
    ];

    test('search matches name or enrolment; below-75 uses exact counts', () {
      List<String> names(List<Json> l) => [for (final s in l) s['official_name'] as String];
      expect(names(filterStudents(roster, query: 'en00')), hasLength(4));
      expect(names(filterStudents(roster, query: ' mOh ')), ['Mohan']);
      expect(names(filterStudents(roster, query: 'EN004')), ['Bob']);
      expect(names(filterStudents(roster, belowOnly: true)), ['Alice']);
      expect(names(filterStudents(roster, query: 'z', belowOnly: true)), isEmpty);
      // 3 of 4 is exactly 75%: not below.
      expect(belowAttendanceThreshold(roster.last), isFalse);
    });

    test('sorting by percentage keeps students without data last both ways', () {
      List<String> names(List<Json> l) => [for (final s in l) s['official_name'] as String];
      expect(names(sortStudents(roster, 3, true)), ['Alice', 'Bob', 'Zoya', 'Mohan']);
      expect(names(sortStudents(roster, 3, false)), ['Zoya', 'Bob', 'Alice', 'Mohan']);
      expect(names(sortStudents(roster, 0, true)), ['Alice', 'Bob', 'Mohan', 'Zoya']);
      expect(names(sortStudents(roster, 1, false)), ['Bob', 'Zoya', 'Mohan', 'Alice']);
      expect(names(sortStudents(roster, 2, false)).first, 'Zoya');
      expect(roster.first['official_name'], 'Zoya'); // input untouched
    });

    test('mark totals fold in legacy late and excused marks', () {
      final t = MarkTotals([
        {'present': 5, 'late': 1, 'absent': 2, 'unassessed': 1, 'excused': 1},
        {'present': 1, 'absent': 0},
      ]);
      expect((t.present, t.late, t.absent, t.unassessed), (6, 1, 2, 2));
      expect(t.total, 11);
    });
  });

  group('overview layout', () {
    Map<String, dynamic> richSummary() => {
      'offering_id': 'class',
      'sessions_conducted': 10,
      'students': [
        for (var i = 1; i <= 6; i++)
          {
            'student_id': 's$i',
            'official_name': 'Student Number $i with a Rather Long Name',
            'enrollment_number': 'ENROL-2026-00$i',
            'present': 10 - i, 'late': 0, 'absent': i, 'unassessed': i == 1 ? 1 : 0,
            'excused': 0, 'conducted': 10, 'attended': 10 - i, 'assessed': 10,
            'percentage': (10 - i) * 10.0,
          },
      ],
    };

    Future<void> pump(WidgetTester tester, Size size, double scale) async {
      final h = (await tester.runAsync(
        () => harness(role: AppRole.teacher, profileRole: 'teacher'),
      ))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter(
        (r) async => jsonResponse(richSummary()),
      );
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: AttendanceOverview(
                  api: h.services.api,
                  institute: institute,
                  offering: 'class',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    for (final (size, scale) in [
      (const Size(320, 700), 1.0),
      (const Size(320, 700), 2.0),
      (const Size(390, 844), 2.0),
      (const Size(844, 390), 1.0),
      (const Size(1440, 900), 2.0),
    ]) {
      testWidgets('Overview fits at ${size.width}x${size.height}, text x$scale', (tester) async {
        await pump(tester, size, scale);
        expect(find.text('Semester attendance'), findsOneWidget);
        expect(find.text('Attendance marks'), findsOneWidget);
        expect(find.text('Students'), findsOneWidget);
        expect(find.text('Student Number 1 with a Rather Long Name'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Phones get student cards with colour-coded percentages', (tester) async {
      await pump(tester, const Size(390, 844), 1);
      // The compact list replaces the table: no column headers.
      expect(find.text('Enrolment'), findsOneWidget); // only the sort chip
      expect(find.text('Present 9 · Absent 1 · 10 assessed · 1 unassessed'), findsOneWidget);
      expect(find.text('90.0%'), findsOneWidget);
      // Mark totals across the roster: 39 present, 21 absent, 1 unassessed.
      expect(find.text('Present 39 (64%)'), findsOneWidget);
      expect(find.text('Absent 21 (34%)'), findsOneWidget);
      expect(find.text('Unassessed 1 (2%)'), findsOneWidget);
    });

    testWidgets('Sort chips reorder the list and the below-75 chip filters it', (tester) async {
      await pump(tester, const Size(390, 3000), 1);
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      expect(y('Student Number 1 with a Rather Long Name'), lessThan(y('Student Number 2 with a Rather Long Name')));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Lowest %'));
      await tester.pumpAndSettle();
      expect(y('Student Number 6 with a Rather Long Name'), lessThan(y('Student Number 1 with a Rather Long Name')));
      await tester.tap(find.widgetWithText(FilterChip, 'Below 75%'));
      await tester.pumpAndSettle();
      expect(find.text('Student Number 1 with a Rather Long Name'), findsNothing); // 90%
      expect(find.text('Student Number 4 with a Rather Long Name'), findsOneWidget); // 60%
      expect(find.text('Showing 4 of 6'), findsOneWidget);
    });
  });
}
