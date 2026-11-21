import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_student/student_classes.dart';
import 'package:facetrack_student/student_notifications.dart';
import 'package:facetrack_student/student_account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  testWidgets('Opening the app reads each account endpoint once, not once per widget', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    final counts = <String, int>{};
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      counts[r.path] = (counts[r.path] ?? 0) + 1;
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/me/biometric-enrollment') return jsonResponse({'consent': null, 'active_sets': [], 'attempt': null});
      return jsonResponse({'items': [], 'next_cursor': null});
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [servicesProvider.overrideWithValue(h.services)],
      child: ProductApp(
        classesBuilder: (_) => const StudentClasses(),
        notificationsLoader: studentNotifications,
        accountStatsBuilder: (_) => const StudentAccountStats(),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    // The shell's notices and the home page ask for the same data at the same moment. (The face
    // enrolment state is intentionally fetched by each, see ApiClient.)
    expect(counts, {
      '/v1/me': 1,
      '/v1/me/enrollments': 1,
      '/v1/me/biometric-enrollment': 2,
      '/v1/me/attendance': 1,
      '/v1/me/attendance-disputes': 1,
    });
    await tester.pumpWidget(const SizedBox());
  });
}
