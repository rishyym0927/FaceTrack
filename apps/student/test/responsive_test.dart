import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_student/student_enrolment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  for (final width in [360.0, 390.0, 768.0, 1440.0]) {
    testWidgets('Active enrolment remains reachable at $width and 200% text', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path == '/v1/privacy/notice') {
          return jsonResponse({
            'version': 'fixture',
            'hash': 'a' * 64,
            'text': 'Fixture notice',
          });
        }
        return jsonResponse({
          'consent': {'id': 'consent', 'notice_version': 'fixture'},
          'active_sets': [
            {'id': 'active-set'},
          ],
          'attempt': null,
        });
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const Text('Classes fixture'),
            enrollmentBuilder: (_) => const StudentEnrolment(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Enrolment'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Face enrolment active'), findsOneWidget);
      await tester.ensureVisible(find.text('Replace recording'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
