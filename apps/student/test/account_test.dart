import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_student/student_account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  for (final scale in const [1.0, 2.0]) {
    testWidgets('Account overview shows face status at 360 px, $scale x text', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path == '/v1/me/biometric-enrollment') {
          return jsonResponse({
            'consent': null,
            'active_sets': [],
            'attempt': null,
          });
        }
        return jsonResponse({'items': [], 'next_cursor': null});
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const Text('Classes fixture'),
            accountStatsBuilder: (_) => const StudentAccountStats(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Face enrolment'));
      await tester.pumpAndSettle();
      expect(find.text('Not registered yet. Tap to start.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
