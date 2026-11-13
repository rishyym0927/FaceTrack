import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_student/student_attendance.dart';

import '../../../packages/app_core/test/harness.dart';

Json record(String offering, String status, DateTime at, {String? id}) => {
  'id': id ?? '$offering-${at.toIso8601String()}',
  'session_id': 's-${at.toIso8601String()}',
  'offering_id': offering,
  'starts_at': at.toUtc().toIso8601String(),
  'status': status,
  'reason': null,
  'revision': 1,
  'published_at': at.toUtc().toIso8601String(),
};

void main() {
  final now = DateTime.now();
  final rows = [
    record('ds', 'present', now),
    record('ds', 'late', now.subtract(const Duration(days: 1))),
    record('ds', 'absent', now.subtract(const Duration(days: 2))),
    record('ds', 'excused', now.subtract(const Duration(days: 3))),
    record('dm', 'absent', DateTime(now.year, now.month - 4, 10)),
    record('dm', 'unassessed', DateTime(now.year, now.month - 4, 11)),
  ];

  test('Stats fold late into Present and excused into Unassessed', () {
    final s = AttendanceStats(rows);
    expect([s.present, s.absent, s.unassessed], [2, 2, 2]);
    expect(s.percentage, 50);
  });

  test('Threshold advice counts classes to attend or to miss', () {
    // 1 of 4 → needs 8 more in a row: (1+8)/(4+8) = 75%.
    final low = AttendanceStats([
      for (final s in ['present', 'absent', 'absent', 'absent'])
        record('x', s, now),
    ]);
    expect(low.toReachThreshold, 8);
    expect(low.canMiss, 0);
    // 9 of 10 → can miss 2: 9/12 = 75%.
    final high = AttendanceStats([
      for (var i = 0; i < 10; i++)
        record('x', i == 0 ? 'absent' : 'present', now),
    ]);
    expect(high.toReachThreshold, 0);
    expect(high.canMiss, 2);
  });

  test(
    'Advice does not call an above-threshold student exactly at the limit',
    () {
      final above = AttendanceStats([
        for (var i = 0; i < 5; i++)
          record('x', i == 0 ? 'absent' : 'present', now),
      ]);
      expect(above.percentage, 80);
      expect(above.canMiss, 0);
      expect(attendanceAdvice(above), contains('On track'));
      expect(attendanceAdvice(above), isNot(contains('Exactly at the limit')));
      expect(
        attendanceAdvice(AttendanceStats([])),
        contains('No assessed classes'),
      );
    },
  );

  test('Filters narrow by subject, status and period', () {
    expect(filterRecords(rows, subject: 'dm').length, 2);
    expect(filterRecords(rows, status: 'present').length, 2);
    expect(filterRecords(rows, status: 'unassessed').length, 2);
    expect(
      filterRecords(rows, range: AttendanceRange.quarter, now: now).length,
      4,
    );
  });

  for (final width in const [360.0, 1280.0]) {
    testWidgets('Attendance tab renders at ${width.toInt()} px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path == '/v1/me/attendance') {
          return jsonResponse({
            'items': rows,
            'next_cursor': null,
            'summary': {},
          });
        }
        if (r.path == '/v1/me/enrollments') {
          // Subject names fail: the page still shows attendance.
          return jsonResponse({
            'error': {'code': 'UNAVAILABLE'},
          }, 503);
        }
        return jsonResponse({'items': [], 'next_cursor': null});
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(classesBuilder: (_) => const StudentAttendance()),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Your attendance'), findsOneWidget);
      expect(
        find.textContaining('Could not load subject names'),
        findsOneWidget,
      );
      expect(find.text('50%'), findsNothing);
      expect(find.text('Unassessed'), findsNothing);
      // The status chips filter the record list.
      await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Absent'));
      await tester.tap(find.widgetWithText(ChoiceChip, 'Absent'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Absent'), findsNWidgets(2));
      final trends = find.text('Attendance trends');
      await tester.ensureVisible(trends);
      await tester.tap(trends);
      await tester.pumpAndSettle();
      expect(find.text('50%'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'Attendance labels bounded results, retains transient data, and clears denied data',
    (tester) async {
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      var failure = 0;
      var attendanceCalls = 0;
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path != '/v1/me/attendance') {
          return jsonResponse({'items': [], 'next_cursor': null});
        }
        attendanceCalls++;
        if (failure != 0) {
          return jsonResponse({
            'error': {'code': 'TEST', 'message': 'Attendance refresh failed'},
          }, failure);
        }
        return jsonResponse({
          'items': [rows.first],
          'next_cursor': 'page-$attendanceCalls',
        });
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(classesBuilder: (_) => const StudentAttendance()),
        ),
      );
      await tester.pumpAndSettle();
      expect(attendanceCalls, 1);
      expect(find.textContaining('latest 1 published records'), findsOneWidget);
      expect(find.text('Records'), findsOneWidget);

      failure = 503;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Service temporarily unavailable'), findsOneWidget);
      expect(find.text('Records'), findsOneWidget);

      failure = 403;
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Access unavailable'), findsOneWidget);
      expect(find.text('Records'), findsNothing);
      expect(find.textContaining('latest 1 published records'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
