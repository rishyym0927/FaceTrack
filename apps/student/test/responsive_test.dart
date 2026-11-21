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

  // Every registration stage must lay out at 200% text on a small phone.
  for (final stage in const [
    'consent',
    'record',
    'awaiting',
    'processing',
    'review',
    'rejected',
  ]) {
    for (final width in const [320.0, 360.0, 1280.0]) {
      testWidgets('Enrolment "$stage" lays out at $width and 200% text', (
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
        final status = switch (stage) {
          'awaiting' => 'awaiting_upload',
          'processing' => 'processing',
          'review' => 'review_required',
          'rejected' => 'rejected',
          _ => null,
        };
        h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
          if (r.path == '/v1/me') return jsonResponse(h.account);
          if (r.path == '/v1/privacy/notice') {
            return jsonResponse({
              'version': 'fixture',
              'hash': 'a' * 64,
              'text':
                  'Synthetic notice. Your participation is voluntary and you may withdraw at any time. ' * 3,
            });
          }
          return jsonResponse({
            'consent': stage == 'consent'
                ? null
                : {'id': 'consent', 'notice_version': 'fixture'},
            'active_sets': [],
            'attempt': status == null
                ? null
                : {
                    'id': 'attempt',
                    'asset_id': 'asset',
                    'status': status,
                    'version': 1,
                    'reason': status == 'rejected' ? 'MULTIPLE_FACES' : null,
                    'pose_order': ['front', 'left', 'right', 'up', 'down'],
                    'quality_json': {},
                    'expires_at': '2099-01-01T00:00:00Z',
                  },
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
        // The progress strip is always there until registration is active.
        expect(find.text('Consent'), findsOneWidget);
        expect(find.text('Review'), findsOneWidget);
        if (stage == 'consent') {
          await tester.ensureVisible(find.text('Accept and continue'));
          await tester.pumpAndSettle();
          // Consent is never pre-accepted.
          expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, false);
        }
        if (stage == 'record' || stage == 'awaiting') {
          await tester.ensureVisible(find.text('Record guided video'));
          await tester.pumpAndSettle();
          expect(find.text('Record guided video'), findsOneWidget);
        }
        if (stage == 'rejected') {
          expect(
            find.textContaining('More than one face appeared'),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
