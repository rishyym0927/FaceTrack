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

  for (final (width, scale, height) in const [
    (320.0, 1.0, 3000.0),
    (390.0, 1.0, 3000.0),
    (320.0, 2.0, 7000.0),
    (390.0, 2.0, 7000.0),
    (800.0, 1.0, 360.0),
    (1440.0, 1.0, 1600.0),
  ]) {
    testWidgets(
      'Faculty tools and app note lay out at ${width.toInt()} px, ${scale}x text',
      (tester) async {
        tester.view.physicalSize = Size(width, height);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final h = (await tester.runAsync(
          () => harness(role: AppRole.teacher, profileRole: 'teacher'),
        ))!;
        addTearDown(() => tester.runAsync(h.dispose));
        h.services.api.dio.httpClientAdapter = RoutesAdapter(
          (r) async => r.path == '/v1/me'
              ? jsonResponse(h.account)
              : jsonResponse({'items': [], 'next_cursor': null}),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(h.services)],
            child: ProductApp(
              classesBuilder: (_) => AccountPage(
                statsBuilder: (_) =>
                    const TeacherAccountStats(version: '1.2.3'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('FACULTY TOOLS'), findsOneWidget);
        expect(find.text('Attendance'), findsOneWidget);
        expect(find.text('Open attendance'), findsOneWidget);
        expect(find.text('Open subjects'), findsOneWidget);
        expect(find.text('ABOUT THIS APP'), findsOneWidget);
        expect(find.text('FaceTrack Faculty'), findsOneWidget);
        expect(find.text('Version 1.2.3'), findsOneWidget);
        // Sign out stays the shared page's single, outlined action.
        expect(find.text('Sign out'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('The version pill is hidden when the build has none', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: TeacherAccountStats())),
      ),
    );
    expect(find.textContaining('Version'), findsNothing);
    expect(find.text('FaceTrack Faculty'), findsOneWidget);
  });
}
