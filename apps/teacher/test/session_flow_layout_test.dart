import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../packages/app_core/test/harness.dart';

Json _row(String id, {bool eligible = true}) => {
  'student_id': id,
  'official_name': 'Student $id',
  'enrollment_number': '00$id',
  'status': 'unassessed',
  'recognition_eligible': eligible,
};

Future<void> _openSession(
  WidgetTester tester, {
  required String status,
  required List<Json> rows,
  required double width,
  required double scale,
  double height = 900,
}) async {
  tester.view.physicalSize = Size(width, height);
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
          'status': status,
          'starts_at': '2026-10-30T05:00:00Z',
          'ends_at': '2026-10-30T06:00:00Z',
          'room_label': 'E301',
          'version': 1,
          'attendance_revision': 0,
        },
        'processing_pending': false,
        'items': rows,
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
}

void main() {
  for (final (width, scale) in const [(320.0, 2.0), (390.0, 1.0), (390.0, 2.0), (1440.0, 1.0)]) {
    testWidgets(
      'An open session offers the scan step first at ${width.toInt()} px, text ${(scale * 100).toInt()}%',
      (tester) async {
        await _openSession(
          tester,
          status: 'open',
          rows: [_row('1'), _row('2'), _row('3', eligible: false)],
          width: width,
          scale: scale,
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('capture-panel')), findsOneWidget);
        expect(find.text('2 of 3 students can be recognised'), findsOneWidget);
        final scan = find.widgetWithText(FilledButton, 'Scan classroom');
        await tester.ensureVisible(scan);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(scan).onPressed, isNotNull);
        // A comfortable touch target, as wide as the panel on a phone.
        expect(tester.getSize(scan).height, greaterThanOrEqualTo(48));
        expect(find.text('Step 2 of 5 · Record classroom'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Fewer than two enrolled students explains why scanning is unavailable', (
    tester,
  ) async {
    await _openSession(
      tester,
      status: 'open',
      rows: [_row('1'), _row('2', eligible: false)],
      width: 320,
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    expect(find.textContaining('needs at least two students'), findsOneWidget);
    final scan = find.widgetWithText(FilledButton, 'Scan classroom');
    await tester.ensureVisible(scan);
    expect(tester.widget<FilledButton>(scan).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('A scheduled session shows one clear action per row on a phone', (tester) async {
    await _openSession(
      tester,
      status: 'scheduled',
      rows: [_row('1'), _row('2')],
      width: 320,
      scale: 2,
    );
    expect(tester.takeException(), isNull);
    final open = find.widgetWithText(FilledButton, 'Open session');
    expect(open, findsOneWidget);
    expect(tester.getSize(open).width, greaterThan(200)); // full width, easy to hit
    await tester.pumpWidget(const SizedBox());
  });

  group('step tracker', () {
    Future<void> show(WidgetTester tester, double width, String status, bool captured, {double scale = 1}) async {
      tester.view.physicalSize = Size(width, 600);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: SessionSteps(status: status, captured: captured),
            ),
          ),
        ),
      );
    }

    testWidgets('names every step under its dot when there is room', (tester) async {
      await show(tester, 800, 'open', false);
      for (final name in SessionSteps.steps) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.text('Step 2 of 5 · Record classroom'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    for (final (width, scale) in const [(320.0, 1.0), (320.0, 2.0), (390.0, 2.0)]) {
      testWidgets('keeps only the current step name on a phone at ${width.toInt()} px, ${(scale * 100).toInt()}%', (
        tester,
      ) async {
        await show(tester, width, 'review_required', true, scale: scale);
        expect(tester.takeException(), isNull);
        expect(find.text('Review marks'), findsNothing);
        expect(find.text('Step 4 of 5 · Review marks'), findsOneWidget);
      });
    }
  });
}
