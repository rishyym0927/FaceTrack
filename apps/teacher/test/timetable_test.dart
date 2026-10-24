import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_timetable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  test('Timetable preview suggests the next actual class date', () {
    final rows = [
      {
        'weekday': 'MON',
        'effective_from': '2026-10-26',
        'effective_until': '2026-11-30',
      },
    ];
    expect(
      nextTimetableDate(rows, referenceDate: DateTime(2026, 10, 23)),
      DateTime(2026, 10, 26),
    );
    expect(
      nextTimetableDate(rows, referenceDate: DateTime(2026, 12, 1)),
      isNull,
    );
  });

  testWidgets('Timetable polling stops after leaving the screen', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var polls = 0;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/offerings/class') {
        return jsonResponse({'term_id': 'term'});
      }
      if (r.path == '/v1/terms/term/schedule') {
        return jsonResponse({'schedule_revision': 1});
      }
      if (r.path == '/v1/timetable-imports/import') {
        polls++;
        return jsonResponse({'status': 'queued'});
      }
      throw StateError('Unexpected request: ${r.path}');
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TeacherTimetable(
            api: h.services.api,
            institute: institute,
            offering: 'class',
            publishableKey: 'fixture-key',
            changed: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = tester.state(find.byType(TeacherTimetable)) as dynamic;
    state.importId = 'import';
    state.poll();
    await tester.pump(const Duration(milliseconds: 100));
    expect(polls, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 3));
    expect(polls, 1);
  });
}
