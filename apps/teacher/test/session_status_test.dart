import 'dart:async';

import 'package:dio/dio.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_sessions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  for (final width in [360.0, 390.0, 768.0, 1440.0]) {
    testWidgets('Teacher review remains usable at $width and 200% text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
              'status': 'review_required',
              'starts_at': '2026-10-24T09:00:00Z',
              'version': 1,
              'attendance_revision': 0,
            },
            'items': [
              {
                'student_id': 'student',
                'official_name': 'Synthetic Student With A Long Name',
                'enrollment_number': '0001',
                'status': 'unassessed',
                'recognition_eligible': false,
              },
            ],
          });
        }
        if (r.path == '/v1/sessions/session/reports') {
          return jsonResponse({'items': []});
        }
        throw StateError('Unexpected request: ${r.path}');
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
      await tester.ensureVisible(find.text('Publish attendance'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Capture status request is reused across unrelated rebuilds', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var captureReads = 0;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/sessions/session/attendance') {
        return jsonResponse({
          'session': {
            'id': 'session',
            'offering_id': 'class',
            'status': 'review_required',
            'starts_at': '2026-10-24T09:00:00Z',
            'version': 1,
            'attendance_revision': 0,
          },
          'items': [],
        });
      }
      if (r.path == '/v1/sessions/session/reports') {
        return jsonResponse({'items': []});
      }
      if (r.path == '/v1/captures/capture') {
        captureReads++;
        return jsonResponse({'status': 'queued'});
      }
      throw StateError('Unexpected request: ${r.path}');
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
    final state = tester.state(find.byType(TeacherSessionDetail)) as dynamic;
    state.setState(() => state.capture = {'id': 'capture'});
    await tester.pumpAndSettle();
    expect(captureReads, 1);
    state.setState(() {});
    await tester.pumpAndSettle();
    expect(captureReads, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Older session response cannot replace a newer attendance view', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    final older = Completer<ResponseBody>();
    var reads = 0;
    Map<String, dynamic> response(int version, String name) => {
      'session': {
        'id': 'session',
        'offering_id': 'class',
        'status': 'review_required',
        'starts_at': '2026-10-24T09:00:00Z',
        'version': version,
        'attendance_revision': 0,
      },
      'items': [
        {
          'student_id': 'student',
          'official_name': name,
          'enrollment_number': '0001',
          'status': 'unassessed',
          'recognition_eligible': false,
        },
      ],
    };
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/sessions/session/attendance') {
        reads++;
        if (reads == 2) return older.future;
        return jsonResponse(
          response(
            reads == 1 ? 1 : 3,
            reads == 1 ? 'Initial Student' : 'Current Student',
          ),
        );
      }
      if (r.path == '/v1/sessions/session/reports') {
        return jsonResponse({'items': []});
      }
      throw StateError('Unexpected request: ${r.path}');
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
    final state = tester.state(find.byType(TeacherSessionDetail)) as dynamic;
    unawaited(state.load(discardChanges: true) as Future<void>);
    await tester.pump();
    unawaited(state.load(discardChanges: true) as Future<void>);
    await tester.pumpAndSettle();
    expect(find.textContaining('Current Student'), findsOneWidget);
    older.complete(jsonResponse(response(2, 'Stale Student')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Current Student'), findsOneWidget);
    expect(find.textContaining('Stale Student'), findsNothing);
    expect(state.data['session']['version'], 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Terminal capture stops closed-session polling', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var attendanceReads = 0, captureReads = 0;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/sessions/session/attendance') {
        attendanceReads++;
        return jsonResponse({
          'session': {
            'id': 'session',
            'offering_id': 'class',
            'status': 'review_required',
            'starts_at': '2026-10-24T09:00:00Z',
            'version': attendanceReads,
            'attendance_revision': 0,
          },
          'items': [],
        });
      }
      if (r.path == '/v1/sessions/session/reports') {
        return jsonResponse({'items': []});
      }
      if (r.path == '/v1/captures/capture') {
        captureReads++;
        return jsonResponse({'id': 'capture', 'status': 'review_required'});
      }
      throw StateError('Unexpected request: ${r.path}');
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
    final state = tester.state(find.byType(TeacherSessionDetail)) as dynamic;
    state.setState(() => state.capture = {'id': 'capture', 'status': 'queued'});
    unawaited(state.load(discardChanges: true) as Future<void>);
    await tester.pumpAndSettle();
    expect(captureReads, 1);
    expect(find.text('Capture: ready for attendance review'), findsOneWidget);
    final settledReads = attendanceReads;
    await tester.pump(const Duration(seconds: 6));
    expect(attendanceReads, settledReads);
    await tester.pumpWidget(const SizedBox());
  });
}
