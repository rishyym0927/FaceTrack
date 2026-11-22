import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_teacher/teacher_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

Map<String, dynamic> _offering(String id, String code, String title, int sem) =>
    {
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

Map<String, dynamic> _student(
  String id,
  String name,
  int attended,
  int absent, {
  int unassessed = 0,
}) => {
  'student_id': id,
  'official_name': name,
  'enrollment_number': 'EN-$id',
  'present': attended,
  'late': 0,
  'absent': absent,
  'unassessed': unassessed,
  'excused': 0,
  'conducted': attended + absent + unassessed,
  'attended': attended,
  'assessed': attended + absent,
  'percentage': attended + absent == 0
      ? null
      : double.parse((100 * attended / (attended + absent)).toStringAsFixed(1)),
};

Map<String, dynamic> _summary(List<Map<String, dynamic>> students, int held) =>
    {
      'sessions_conducted': held,
      'students': students,
      'policy_version': 'session-v1',
    };

void main() {
  testWidgets('Subjects does not load analytics until Attendance opens', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var dashboardReads = 0;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/teacher/attendance-dashboard') {
        dashboardReads++;
        return jsonResponse({'items': [], 'next_cursor': null});
      }
      return jsonResponse({'items': [], 'next_cursor': null});
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(h.services)],
      child: ProductApp(
        classesBuilder: (_) => const Center(child: Text('Subject list')),
        attendanceBuilder: (_) => const TeacherAttendancePage(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Subject list'), findsOneWidget);
    expect(dashboardReads, 0);
    await tester.tap(find.text('Attendance').first);
    await tester.pumpAndSettle();
    expect(find.text('No published attendance yet'), findsOneWidget);
    expect(find.text('Go to subjects'), findsOneWidget);
    expect(dashboardReads, 1);
    expect(tester.takeException(), isNull);
  });

  test('totals weight by classes, never count unassessed as absence', () {
    final o = Offering.fromJson(_offering('a', 'BCS 201', 'DAA', 3));
    final s = SubjectStats(
      o,
      summary: _summary([
        _student('1', 'Asha', 8, 2),
        _student('2', 'Bina', 2, 2, unassessed: 6),
      ], 10),
    );
    final t = DashboardTotals([s]);
    expect(t.attended, 10);
    expect(t.assessed, 14);
    expect(t.overall, closeTo(71.43, .01));
    expect(t.atRiskStudents, 1);
    expect(t.lowest.single.name, 'Bina');
  });

  test('below 75 uses exact counts even when display rounds to 75.0', () {
    final data = _student('1', 'Asha', 1499, 501)..['percentage'] = 75.0;
    expect(belowAttendanceThreshold(data), isTrue);
    final stats = SubjectStats(
      Offering.fromJson(_offering('a', 'BCS 201', 'DAA', 3)),
      summary: _summary([data], 2000),
    );
    expect(stats.below, 1);
    expect(DashboardTotals([stats]).atRiskStudents, 1);
  });

  test('monthly trend combines subjects with assessed-weighted totals', () {
    SubjectStats subject(String id, int attended, int assessed) => SubjectStats(
      Offering.fromJson(_offering(id, 'BCS 201', 'DAA', 3)),
      summary: {
        ..._summary([], 1),
        'monthly': [
          {
            'month': '2026-11',
            'attended': attended,
            'assessed': assessed,
            'percentage': 100 * attended / assessed,
          },
        ],
      },
    );
    final trend = attendanceTrend([subject('a', 1, 2), subject('b', 8, 8)]);
    expect(trend.single.attended, 9);
    expect(trend.single.assessed, 10);
    expect(trend.single.percentage, 90);
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

  testWidgets('Dashboard shows overall, subject-wise and semester filtering', (
    tester,
  ) async {
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
              'offering': _offering(
                'a',
                'BCS 201',
                'Design and Analysis of Algorithm',
                3,
              ),
              'summary': _summary([
                _student('1', 'Asha', 9, 1),
                _student('2', 'Bina', 5, 5),
              ], 10),
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TeacherDashboard(api: h.services.api, institute: institute),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Overview'), findsOneWidget);
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
    testWidgets('Dashboard stays usable at $width and 200% text', (
      tester,
    ) async {
      final h = (await tester.runAsync(
        () => harness(role: AppRole.teacher, profileRole: 'teacher'),
      ))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        return jsonResponse({
          'items': [
            {
              'offering': _offering(
                'a',
                'BCS 201',
                'Design and Analysis of Algorithm',
                3,
              ),
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
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 2600),
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: TeacherDashboard(
                  api: h.services.api,
                  institute: institute,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Overview'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  group('subject filtering and sorting', () {
    SubjectStats subject(
      String id,
      String code,
      String title,
      int sem, {
      List<Map<String, dynamic>> students = const [],
      List<Map<String, dynamic>>? monthly,
    }) => SubjectStats(
      Offering.fromJson(_offering(id, code, title, sem)),
      summary: {
        ..._summary(students, students.isEmpty ? 0 : 10),
        'monthly': ?monthly,
      },
    );
    final daa = subject(
      'a',
      'BCS 201',
      'Design and Analysis',
      3,
      students: [_student('1', 'Asha', 9, 1), _student('2', 'Bina', 5, 5)],
    ); // 70%, below the threshold
    final toc = subject(
      'b',
      'BCS 301',
      'Theory of Computation',
      5,
      students: [_student('3', 'Chitra', 10, 0)],
    ); // 100%
    final se = subject('c', 'BIT 205', 'Software Engineering', 3); // no data
    final all = [daa, toc, se];

    test('semester group narrows the list', () {
      expect(
        filterSubjects(all, group: subjectGroupKey(toc)).map((s) => s.offering.id),
        ['b'],
      );
      expect(filterSubjects(all, group: subjectGroupKey(daa)), hasLength(2));
      expect(filterSubjects(all, group: 'nope|9'), isEmpty);
    });

    test('query matches title, code and section words, ignoring case', () {
      List<String> ids(String q) =>
          filterSubjects(all, query: q).map((s) => s.offering.id).toList();
      expect(ids('theory'), ['b']);
      expect(ids('bit 205'), ['c']);
      expect(ids('  CSE1 '), ['a', 'b', 'c']);
      expect(ids('analysis computation'), isEmpty); // every word must match
      expect(ids(''), ['a', 'b', 'c']);
    });

    test('below-75 keeps subjects whose own aggregate is below the threshold', () {
      expect(
        filterSubjects(all, belowOnly: true).map((s) => s.offering.id),
        ['a'],
      );
      final failed = SubjectStats(
        Offering.fromJson(_offering('d', 'X 1', 'Broken', 3)),
        error: const AppFailure('No access'),
      );
      expect(
        filterSubjects([...all, failed], belowOnly: true).map((s) => s.offering.id),
        ['a', 'd'],
      );
    });

    test('filters combine', () {
      expect(
        filterSubjects(
          all,
          group: subjectGroupKey(daa),
          query: 'design',
          belowOnly: true,
        ).map((s) => s.offering.id),
        ['a'],
      );
      expect(filterSubjects(all, query: 'theory', belowOnly: true), isEmpty);
    });

    test('sorting puts subjects without data last and never mutates the input', () {
      List<String> ids(SubjectSort sort) =>
          sortSubjects(all, sort).map((s) => s.offering.id).toList();
      expect(ids(SubjectSort.lowest), ['a', 'b', 'c']);
      expect(ids(SubjectSort.highest), ['b', 'a', 'c']);
      expect(ids(SubjectSort.name), ['a', 'c', 'b']);
      expect(all.map((s) => s.offering.id), ['a', 'b', 'c']);
    });

    test('subject trend compares the last two months with assessed marks', () {
      Map<String, dynamic> m(String month, int attended, int assessed) => {
        'month': month,
        'attended': attended,
        'assessed': assessed,
      };
      final up = subject(
        'e',
        'A 1',
        'Up',
        3,
        monthly: [m('2026-09', 6, 10), m('2026-10', 8, 10), m('2026-11', 0, 0)],
      );
      final t = subjectTrend(up)!;
      expect(t.month, '2026-10'); // an empty month is not "last published"
      expect(t.previousMonth, '2026-09');
      expect(t.delta, closeTo(20, .001));
      final single = subjectTrend(subject('f', 'A 2', 'One', 3, monthly: [m('2026-10', 1, 2)]))!;
      expect(single.delta, isNull);
      expect(subjectTrend(se), isNull);
      expect(subjectTrend(SubjectStats(Offering.fromJson(_offering('g', 'A', 'B', 3)))), isNull);
    });

    test('month labels and the 75% colour boundary', () {
      expect(monthLabel('2026-11'), 'Nov 2026');
      expect(monthLabel('2026-13'), '2026-13');
      expect(monthLabel('bad'), 'bad');
      final borderline = _student('1', 'Asha', 1499, 501)..['percentage'] = 75.0;
      expect(attendanceTone(borderline), isNot(AppTone.success));
      expect(attendanceTone(_student('2', 'Bina', 3, 1)), AppTone.success);
      expect(attendanceTone(_student('3', 'Chitra', 1, 3)), AppTone.danger);
      expect(attendanceTone(_student('4', 'Dev', 0, 0)), AppTone.neutral);
    });
  });

  group('dashboard layout and controls', () {
    Future<Harness> pump(
      WidgetTester tester, {
      required Size size,
      double scale = 1,
      Map<String, dynamic>? response,
    }) async {
      final h = (await tester.runAsync(
        () => harness(role: AppRole.teacher, profileRole: 'teacher'),
      ))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        return jsonResponse(response ?? _fullResponse());
      });
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: SingleChildScrollView(
                child: TeacherDashboard(
                  api: h.services.api,
                  institute: institute,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return h;
    }

    for (final (size, scale) in [
      (const Size(320, 700), 1.0),
      (const Size(320, 700), 2.0),
      (const Size(390, 844), 2.0),
      (const Size(844, 390), 1.0),
      (const Size(1440, 900), 1.0),
    ]) {
      testWidgets('Dashboard sections fit at ${size.width}x${size.height}, text x$scale', (
        tester,
      ) async {
        await pump(tester, size: size, scale: scale);
        expect(find.text('Overview'), findsOneWidget);
        expect(find.text('Needs attention'), findsOneWidget);
        expect(find.text('Subject-wise statistics'), findsOneWidget);
        expect(find.text('Students below 75%'), findsOneWidget);
        expect(find.text('Sessions held'), findsOneWidget);
        expect(find.text('Design and Analysis of Algorithm'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('Summary tiles and subject cards show only loaded figures', (
      tester,
    ) async {
      await pump(tester, size: const Size(1100, 2400));
      // 24 attended of 30 assessed across all three loaded subjects.
      expect(find.text('80.0%'), findsWidgets);
      expect(find.text('3'), findsWidgets); // subjects
      expect(find.text('+20.0 pts vs Oct 2026'), findsOneWidget);
      expect(find.text('Last published Nov 2026'), findsNWidgets(2));
      // The subject with no marks has no trend and no invented figure.
      expect(find.text('No data'), findsOneWidget);
      expect(find.text('1 below 75%'), findsOneWidget);
    });

    testWidgets('Search, below-75 toggle and sort really filter the list', (
      tester,
    ) async {
      await pump(tester, size: const Size(1100, 2400));
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      // Default: lowest first, no-data subjects last.
      expect(y('Design and Analysis of Algorithm'), lessThan(y('Theory of Computation')));
      expect(y('Theory of Computation'), lessThan(y('Software Engineering')));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Name'));
      await tester.pumpAndSettle();
      expect(y('Software Engineering'), lessThan(y('Theory of Computation')));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Highest %'));
      await tester.pumpAndSettle();
      expect(y('Theory of Computation'), lessThan(y('Design and Analysis of Algorithm')));

      await tester.tap(find.widgetWithText(FilterChip, 'Below 75% only'));
      await tester.pumpAndSettle();
      expect(find.text('Design and Analysis of Algorithm'), findsOneWidget);
      expect(find.text('Theory of Computation'), findsNothing);
      expect(find.text('Showing 1 of 3 subjects'), findsOneWidget);

      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('Theory of Computation'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pumpAndSettle();
      expect(find.text('No subjects match this filter.'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'theory');
      await tester.pumpAndSettle();
      expect(find.text('Theory of Computation'), findsOneWidget);
      expect(find.text('Design and Analysis of Algorithm'), findsNothing);
      // The attention list follows the subject search: Bina is in DAA only.
      expect(find.text('Bina'), findsNothing);
      expect(find.text('No student is below the threshold.'), findsOneWidget);
    });

    testWidgets('The attention list previews five students and expands', (
      tester,
    ) async {
      final many = {
        'items': [
          {
            'offering': _offering('a', 'BCS 201', 'Algorithms', 3),
            'summary': _summary([
              for (var i = 1; i <= 7; i++) _student('$i', 'Student $i', i, 10),
            ], 20),
          },
        ],
        'next_cursor': null,
      };
      await pump(tester, size: const Size(1100, 2400), response: many);
      expect(find.text('Student 1'), findsOneWidget);
      expect(find.text('Student 5'), findsOneWidget);
      expect(find.text('Student 6'), findsNothing);
      await tester.tap(find.text('Show all 7'));
      await tester.pumpAndSettle();
      expect(find.text('Student 7'), findsOneWidget);
      await tester.tap(find.text('Show fewer'));
      await tester.pumpAndSettle();
      expect(find.text('Student 7'), findsNothing);
    });
  });
}

Map<String, dynamic> _fullResponse() => {
  'items': [
    {
      'offering': _offering('a', 'BCS 201', 'Design and Analysis of Algorithm', 3),
      'summary': {
        ..._summary([
          _student('1', 'Asha', 9, 1),
          _student('2', 'Bina', 5, 5),
        ], 10),
        'monthly': [
          {'month': '2026-10', 'attended': 6, 'assessed': 10},
          {'month': '2026-11', 'attended': 8, 'assessed': 10},
        ],
      },
    },
    {
      'offering': _offering('b', 'BCS 301', 'Theory of Computation', 5),
      'summary': {
        ..._summary([_student('3', 'Chitra', 10, 0)], 10),
        'monthly': [
          {'month': '2026-11', 'attended': 10, 'assessed': 10},
        ],
      },
    },
    {
      'offering': _offering('c', 'BIT 205', 'Software Engineering', 3),
      'summary': _summary([], 0),
    },
  ],
  'next_cursor': null,
};
