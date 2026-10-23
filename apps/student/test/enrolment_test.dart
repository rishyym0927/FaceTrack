import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_student/student_enrolment.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  testWidgets(
    'Consent is explicit before capture and processing cannot start another upload',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      String? consent;
      bool queued = false, active = false;
      var consentWrites = 0;
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path == '/v1/privacy/notice') {
          return jsonResponse({
            'version': 'fixture-notice',
            'hash': 'a' * 64,
            'text': 'Synthetic notice: your participation is voluntary.',
          });
        }
        if (r.path == '/v1/consents') {
          consentWrites++;
          consent = 'consent-fixture';
          return jsonResponse({
            'id': consent,
            'notice_version': 'fixture-notice',
          }, 201);
        }
        return jsonResponse({
          'consent': consent == null
              ? null
              : {'id': consent, 'notice_version': 'fixture-notice'},
          'active_sets': active
              ? [
                  {'id': 'synthetic-active-set'},
                ]
              : [],
          'attempt': queued
              ? {
                  'id': 'attempt',
                  'asset_id': 'asset',
                  'status': active ? 'active' : 'queued',
                  'version': 2,
                  'pose_order': ['front', 'up', 'down', 'left', 'right'],
                  'quality_json': {},
                  'expires_at': '2099-01-01T00:00:00Z',
                }
              : null,
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
      final button = find.widgetWithText(FilledButton, 'Accept and continue');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(find.text('Record guided video'), findsNothing);
      expect(consentWrites, 0);
      await tester.ensureVisible(find.byType(Checkbox));
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(consentWrites, 1);
      expect(find.text('Record guided video'), findsOneWidget);
      queued = true;
      await Scrollable.ensureVisible(
        tester.element(find.text('Refresh')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Waiting for processing'), findsOneWidget);
      expect(find.text('Record guided video'), findsNothing);
      expect(find.text('Upload for processing'), findsNothing);
      active = true;
      await Scrollable.ensureVisible(
        tester.element(find.text('Refresh')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Refresh'));
      await tester.pumpAndSettle();
      expect(find.text('Face enrolment active'), findsOneWidget);
      expect(find.text('Record guided video'), findsNothing);
      await tester.ensureVisible(find.text('Replace recording'));
      await tester.tap(find.text('Replace recording'));
      await tester.pumpAndSettle();
      expect(find.text('Record guided video'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
