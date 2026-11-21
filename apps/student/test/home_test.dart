import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_student/student_classes.dart';
import 'package:facetrack_student/student_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/app_core/test/harness.dart';

Map<String, dynamic> subject(String id, String title) => {
  'id': id,
  'title': title,
  'course_code': id.toUpperCase(),
  'term_code': '2026-ODD',
  'branch': 'CSE',
  'semester': 3,
  'section': 'ALL',
  'version': 1,
  'status': 'active',
};

Map<String, dynamic> enrolment(String id, String title, String status) => {
  'id': 'e-$id',
  'offering_id': id,
  'student_id': 's1',
  'status': status,
  'version': 1,
  'offering': subject(id, title),
};

Map<String, dynamic> published(String offering, String status, int daysAgo) {
  final at = DateTime.now().subtract(Duration(days: daysAgo)).toUtc();
  return {
    'id': '$offering-$daysAgo',
    'session_id': 's-$offering-$daysAgo',
    'offering_id': offering,
    'starts_at': at.toIso8601String(),
    'status': status,
    'revision': 1,
    'published_at': at.toIso8601String(),
  };
}

Map<String, dynamic> face({bool consent = true, bool active = false, String? attempt}) => {
  'consent': consent ? {'id': 'c1', 'notice_version': 'v'} : null,
  'active_sets': active
      ? [
          {'id': 'set'},
        ]
      : [],
  'attempt': attempt == null
      ? null
      : {
          'id': 'a1',
          'asset_id': 'asset',
          'status': attempt,
          'version': 1,
          'pose_order': ['front', 'left', 'right', 'up', 'down'],
          'quality_json': {},
          'expires_at': '2099-01-01T00:00:00Z',
        },
};

void main() {
  test('Registration progress follows the real enrolment state', () {
    RegistrationProgress of(Map<String, dynamic> j, {bool clip = false}) =>
        RegistrationProgress.of(BiometricState.fromJson(j), hasClip: clip);
    expect(of(face(consent: false)).step, 0);
    expect(of(face()).step, 1);
    expect(of(face(attempt: 'awaiting_upload')).step, 1);
    expect(of(face(attempt: 'awaiting_upload'), clip: true).step, 2);
    expect(of(face(attempt: 'queued')).step, 3);
    // Review is pending, never complete, until faculty approve.
    final review = of(face(attempt: 'review_required'));
    expect([review.step, review.complete], [3, false]);
    expect(of(face(active: true)).complete, isTrue);
    // A failed recording sends the student back to Record.
    expect(of(face(attempt: 'rejected')).step, 1);
    // A replacement in progress is not shown as complete.
    expect(of(face(active: true, attempt: 'queued')).complete, isFalse);
  });

  for (final (width, scale) in const [
    (360.0, 1.0),
    (360.0, 2.0),
    (1280.0, 1.0),
  ]) {
    testWidgets('Home shows next step, attendance and subjects at $width x $scale', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 2400);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path == '/v1/me/enrollments') {
          return jsonResponse({
            'items': [
              enrolment('ds', 'Data Structures', 'active'),
              enrolment('dm', 'Discrete Maths', 'requested'),
            ],
            'next_cursor': null,
          });
        }
        if (r.path == '/v1/me/biometric-enrollment') {
          return jsonResponse(face(consent: false));
        }
        if (r.path == '/v1/me/attendance') {
          return jsonResponse({
            'items': [
              published('ds', 'present', 1),
              published('ds', 'present', 2),
              published('ds', 'absent', 3),
              published('ds', 'present', 4),
            ],
            'next_cursor': null,
          });
        }
        return jsonResponse({'items': [], 'next_cursor': null});
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const StudentClasses(),
            enrollmentBuilder: (_) => const Text('Enrolment fixture'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Synthetic'), findsOneWidget);
      expect(find.text('Register your face'), findsOneWidget);
      expect(find.text('Start registration'), findsOneWidget);
      expect(find.text('Consent'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('Data Structures'), findsOneWidget);
      expect(find.text('Discrete Maths'), findsOneWidget);
      expect(find.text('75% attended'), findsOneWidget);
      expect(find.text('Waiting for faculty approval.'), findsOneWidget);
      expect(find.text('Join subject'), findsOneWidget);
      await tester.ensureVisible(find.text('Start registration'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start registration'));
      await tester.pumpAndSettle();
      expect(find.text('Enrolment fixture'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Home confirms an active registration and survives failures', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var attendanceFails = true;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/me/enrollments') {
        return jsonResponse({
          'items': [enrolment('ds', 'Data Structures', 'active')],
          'next_cursor': null,
        });
      }
      if (r.path == '/v1/me/biometric-enrollment') {
        return jsonResponse(face(active: true));
      }
      if (r.path == '/v1/me/attendance') {
        if (attendanceFails) {
          return jsonResponse({
            'error': {'code': 'UNAVAILABLE'},
          }, 503);
        }
        return jsonResponse({
          'items': [published('ds', 'present', 1)],
          'next_cursor': null,
        });
      }
      return jsonResponse({'items': [], 'next_cursor': null});
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(classesBuilder: (_) => const StudentClasses()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Face registration complete'), findsOneWidget);
    expect(find.text('Register your face'), findsNothing);
    // Attendance failed on its own: the subject list still works and the
    // student gets a plain message with a retry.
    expect(find.text('We could not load your attendance.'), findsOneWidget);
    expect(find.text('Data Structures'), findsOneWidget);
    attendanceFails = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('We could not load your attendance.'), findsNothing);
    expect(find.text('Your attendance'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Join subject opens the join-code dialog and empty state is friendly', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/me/biometric-enrollment') {
        return jsonResponse(face(consent: false));
      }
      return jsonResponse({'items': [], 'next_cursor': null});
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(classesBuilder: (_) => const StudentClasses()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('No subjects yet'), findsOneWidget);
    await tester.ensureVisible(find.text('Join subject'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Join subject'));
    await tester.pumpAndSettle();
    expect(find.text('Join a subject'), findsOneWidget);
    expect(find.text('Join code'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
