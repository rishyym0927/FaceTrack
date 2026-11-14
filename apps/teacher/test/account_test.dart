import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_account.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  for (final width in const [360.0, 1280.0]) {
    testWidgets(
      'Faculty account links to attendance without loading its statistics at ${width.toInt()} px',
      (tester) async {
        tester.view.physicalSize = Size(width, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final h = (await tester.runAsync(
          () => harness(role: AppRole.teacher, profileRole: 'teacher'),
        ))!;
        addTearDown(() => tester.runAsync(h.dispose));
        var dashboardReads = 0;
        h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
          if (r.path == '/v1/me') return jsonResponse(h.account);
          if (r.path == '/v1/teacher/attendance-dashboard') {
            dashboardReads++;
          }
          return jsonResponse({'items': [], 'next_cursor': null});
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(h.services)],
            child: ProductApp(
              classesBuilder: (_) =>
                  AccountPage(statsBuilder: (_) => const TeacherAccountStats()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Open attendance'), findsOneWidget);
        expect(find.text('Employee number'), findsNothing);
        expect(dashboardReads, 0);
        expect(find.text('Sign out'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
