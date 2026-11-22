import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../packages/app_core/test/harness.dart';

/// Every decision a teacher submits is stored with source `teacher`, including a camera
/// suggestion they simply confirmed, so the fixtures say so too.
Json _row(
  String id,
  String name,
  String status, {
  String? code,
  String? reason,
  bool eligible = true,
}) => {
  'student_id': id,
  'official_name': name,
  'enrollment_number': 'EN$id',
  'status': status,
  'source': 'teacher',
  'recognition_eligible': eligible,
  'assessment_code': code,
  'reason': reason,
};

final _rows = [
  _row('1', 'Asha Rao', 'present', code: 'recognized'),
  _row('2', 'Ben Cole', 'absent', code: 'not_recognized'),
  _row('3', 'Chitra Das', 'present', code: 'template_ineligible', eligible: false),
  _row('4', 'Dev Nair', 'absent', code: 'recognized', reason: 'He was in the lab.'),
];

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(padding: const EdgeInsets.all(16), child: child)),
);

void main() {
  group('how a mark came about', () {
    test('a confirmed camera suggestion stays "recognised" although its source is teacher', () {
      expect(markOrigin(_rows[0]), MarkOrigin.recognised);
      expect(markOrigin(_rows[0]).label, contains('Recognised by camera'));
    });
    test('a recognised student the teacher marked Absent says so', () {
      expect(markOrigin(_rows[3]), MarkOrigin.overridden);
      expect(markOrigin(_rows[3]).label, contains('you marked Absent'));
    });
    test('no enrolment or no scan means a hand mark', () {
      expect(markOrigin(_rows[2]), MarkOrigin.byHandNoEnrolment);
      expect(markOrigin(_rows[1]), MarkOrigin.byHand);
      expect(markOrigin(_row('9', 'Eve', 'present')), MarkOrigin.byHand);
    });
    test('only a typed reason makes a correction', () {
      expect(correctionReason(_rows[3]), 'He was in the lab.');
      expect(correctionReason(_rows[0]), isNull);
      expect(correctionReason(_row('9', 'Eve', 'present', reason: '  ')), isNull);
    });
  });

  group('published totals', () {
    test('count present and absent and the percentage of those assessed', () {
      final s = PublishedSummary.of(_rows);
      expect([s.total, s.present, s.absent], [4, 2, 2]);
      expect(s.percent, 50);
      expect([s.recognised, s.byHand, s.corrected], [1, 3, 1]);
      expect(s.scanned, isTrue);
    });
    test('older late marks count as present and excused as not assessed', () {
      final s = PublishedSummary.of([
        _row('1', 'A', 'late'),
        _row('2', 'B', 'excused'),
        _row('3', 'C', 'absent'),
      ]);
      expect([s.present, s.absent, s.notAssessed], [1, 1, 1]);
      expect(s.percent, 50);
    });
    test('an empty roster has no percentage, and no scan means no camera split', () {
      expect(PublishedSummary.of(const []).percent, isNull);
      expect(PublishedSummary.of([_row('1', 'A', 'present')]).scanned, isFalse);
    });
  });

  for (final width in const [320.0, 390.0]) {
    for (final scale in const [1.0, 2.0]) {
      testWidgets(
        'Published list fits at ${width.toInt()} px, text ${(scale * 100).toInt()}%',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await tester.pumpWidget(
            _host(
              PublishedAttendance(
                session: const {'attendance_revision': 3},
                rows: _rows,
                busy: false,
                onCorrect: (_) {},
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Attendance published'), findsOneWidget);
          expect(find.text('Corrected 2 times'), findsOneWidget);
          expect(find.byKey(const ValueKey('published-summary')), findsOneWidget);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('published-corrections')),
            400,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.takeException(), isNull);
          expect(find.textContaining('Reason: He was in the lab.'), findsOneWidget);
        },
      );
    }
  }

  testWidgets('Rows are grouped, searchable and filterable; Correct hands over the row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Json? corrected;
    await tester.pumpWidget(
      _host(
        PublishedAttendance(
          session: const {'attendance_revision': 2},
          rows: _rows,
          busy: false,
          onCorrect: (row) => corrected = row,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Present first (Asha, Chitra), then Absent (Ben, Dev), each group by name.
    double top(String id) => tester.getTopLeft(find.byKey(ValueKey('published-row-$id'))).dy;
    expect(top('1'), lessThan(top('3')));
    expect(top('3'), lessThan(top('2')));
    expect(top('2'), lessThan(top('4')));
    expect(find.text('Recognised by camera · confirmed by you'), findsOneWidget);
    expect(find.text('Marked by hand · no face enrolment'), findsOneWidget);
    expect(find.text('Corrected'), findsOneWidget); // the row pill, not the filter chip

    await tester.enterText(find.byKey(const ValueKey('published-search')), 'ben');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('published-row-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('published-row-1')), findsNothing);
    await tester.enterText(find.byKey(const ValueKey('published-search')), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No students match.'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('published-search')), '');

    await tester.tap(find.text('Absent · 2'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('published-row-1')), findsNothing);
    expect(find.byKey(const ValueKey('published-row-4')), findsOneWidget);
    await tester.tap(find.text('Corrected · 1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('published-row-2')), findsNothing);

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('published-row-4')),
      matching: find.text('Correct'),
    ));
    expect(corrected?['student_id'], '4');
  });

  testWidgets('Without a camera scan or corrections only the plain totals show', (tester) async {
    await tester.pumpWidget(
      _host(
        PublishedAttendance(
          session: const {'attendance_revision': 1},
          rows: [_row('1', 'Asha Rao', 'present'), _row('2', 'Ben Cole', 'absent')],
          busy: false,
          onCorrect: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Corrected'), findsNothing);
    expect(find.text('By camera'), findsNothing);
    expect(find.byKey(const ValueKey('published-corrections')), findsNothing);
    expect(find.text('Students'), findsOneWidget);
  });

  for (final (width, scale) in const [(320.0, 2.0), (390.0, 1.0), (1440.0, 1.0)]) {
    testWidgets(
      'A published session page shows success, list, corrections and reports at ${width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
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
                'status': 'finalized',
                'starts_at': '2026-10-30T05:00:00Z',
                'ends_at': '2026-10-30T06:00:00Z',
                'room_label': 'E301',
                'version': 4,
                'attendance_revision': 2,
              },
              'items': _rows,
            });
          }
          if (r.path == '/v1/sessions/session/reports') {
            return jsonResponse({
              'items': [
                {
                  'id': 'r1',
                  'kind': 'final',
                  'source_version': 2,
                  'status': 'ready',
                  'created_at': '2026-10-30T06:10:00Z',
                  'deliveries': [],
                  'email_configured': false,
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
        expect(find.text('Attendance published'), findsOneWidget);
        // No decision bar once published.
        expect(find.text('Publish attendance'), findsNothing);
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('published-row-4')),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('reports-section')),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Download PDF'), findsOneWidget);
        // Correct opens the existing correction dialog.
        final correct = find.descendant(
          of: find.byKey(const ValueKey('published-row-1')),
          matching: find.text('Correct'),
        );
        await tester.ensureVisible(correct);
        await tester.pumpAndSettle();
        await tester.tap(correct);
        await tester.pumpAndSettle();
        expect(find.text('Correct published attendance'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
