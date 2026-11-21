import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

Future<void> _pump(WidgetTester tester, Harness h, List<Object> sessions) async {
  h.services.api.dio.httpClientAdapter = RoutesAdapter(
    (r) async => jsonResponse({'items': sessions, 'next_cursor': null}),
  );
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TeacherSessions(
            api: h.services.api,
            institute: institute,
            offering: 'o1',
            publishableKey: 'fixture-key',
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('An empty session list guides the first step and hides filters', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    await _pump(tester, h, const []);
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(find.text('Create session'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byTooltip('Refresh sessions'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Filters appear once the subject has sessions', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    await _pump(tester, h, [
      {
        'id': 's1',
        'offering_id': 'o1',
        'status': 'review_required',
        'starts_at': '2026-10-26T05:00:00Z',
        'ends_at': '2026-10-26T06:00:00Z',
        'room_label': 'E301',
        'version': 1,
      },
    ]);
    expect(find.widgetWithText(ChoiceChip, 'All'), findsOneWidget);
    // One filter chip and one group heading.
    expect(find.text('Needs your action'), findsNWidgets(2));
    expect(find.text('Review attendance'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
