import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_core/src/account_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Future<Harness> _pump(
  WidgetTester tester, {
  required double width,
  double height = 3200,
  double scale = 1,
  AppRole role = AppRole.teacher,
  String profileRole = 'teacher',
  bool twoInstitutes = false,
  WidgetBuilder? stats,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final h = (await tester.runAsync(
    () => harness(role: role, profileRole: profileRole),
  ))!;
  addTearDown(() => tester.runAsync(h.dispose));
  if (twoInstitutes) {
    const second = '33333333-3333-4333-8333-333333333333';
    final base = accountJson(profileRole);
    final key = profileRole == 'student' ? 'students' : 'teachers';
    final person = Map<String, dynamic>.from((base[key] as List).first as Map);
    h.account = {
      ...base,
      key: [
        ...(base[key] as List),
        {...person, 'id': '${person['id']}-2', 'institute_id': second},
      ],
      'memberships': [
        ...(base['memberships'] as List),
        {
          'id': 'm2',
          'institute_id': second,
          'institute_name': 'Second Institute',
          'role': profileRole,
          'status': 'active',
        },
      ],
    };
  }
  h.services.api.dio.httpClientAdapter = RoutesAdapter(
    (r) async => r.path == '/v1/me'
        ? jsonResponse(h.account)
        : jsonResponse({'items': [], 'next_cursor': null}),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(h.services)],
      child: ProductApp(
        classesBuilder: (_) => AccountPage(statsBuilder: stats),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (twoInstitutes && find.text('Switch institute').evaluate().isEmpty) {
    // With several institutes the app may ask which one to open first.
    await tester.tap(find.text('Test Institute'));
    await tester.pumpAndSettle();
  }
  return h;
}

void main() {
  for (final (width, scale, height) in const [
    (320.0, 1.0, 3200.0),
    (390.0, 1.0, 3200.0),
    (320.0, 2.0, 8000.0),
    (390.0, 2.0, 8000.0),
    (800.0, 1.0, 360.0),
    (1440.0, 1.0, 1600.0),
  ]) {
    testWidgets(
      'Account header, profile and sign out at ${width.toInt()} px, ${scale}x text',
      (tester) async {
        await _pump(tester, width: width, height: height, scale: scale);
        expect(tester.takeException(), isNull);
        // Header: initials avatar, name, institute and one role pill.
        expect(find.text('ST'), findsOneWidget);
        expect(find.text('Synthetic Teacher'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(AccountHeader),
            matching: find.text('Test Institute'),
          ),
          findsOneWidget,
        );
        expect(find.text('Faculty'), findsOneWidget);
        expect(find.byType(AccountHeader), findsOneWidget);
        // Profile keeps email and identity; the institute is not repeated.
        expect(find.text('Profile'), findsOneWidget);
        expect(find.text('fixture@example.test'), findsOneWidget);
        expect(find.text('Identity'), findsOneWidget);
        // One institute: no switch row.
        expect(find.text('Switch institute'), findsNothing);
        expect(find.text('Sign out'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Sign out is a danger-coloured button that signs out', (
    tester,
  ) async {
    final h = await _pump(tester, width: 390);
    final button = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Sign out'),
        matching: find.byType(OutlinedButton),
      ),
    );
    expect(
      button.style?.foregroundColor?.resolve(const {}),
      AppTone.danger,
    );
    await tester.ensureVisible(find.text('Sign out'));
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(h.services.client.auth.currentUser, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final (width, scale) in const [(320.0, 2.0), (390.0, 1.0), (1440.0, 1.0)]) {
    testWidgets(
      'Switch institute row shows the current institute at ${width.toInt()} px, ${scale}x text',
      (tester) async {
        await _pump(
          tester,
          width: width,
          scale: scale,
          height: scale > 1 ? 8000 : 3200,
          twoInstitutes: true,
        );
        expect(tester.takeException(), isNull);
        expect(find.text('INSTITUTE'), findsOneWidget);
        expect(find.text('Switch institute'), findsOneWidget);
        await tester.ensureVisible(find.text('Switch institute'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Switch institute'));
        await tester.pumpAndSettle();
        expect(find.text('Choose institute'), findsOneWidget);
        expect(find.byIcon(Icons.check), findsOneWidget);
        await tester.tap(find.text('Second Institute').last);
        await tester.pumpAndSettle();
        expect(find.text('Choose institute'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Student account keeps its enrolment number and stats slot', (
    tester,
  ) async {
    await _pump(
      tester,
      width: 360,
      role: AppRole.student,
      profileRole: 'student',
      stats: (_) => const Text('Student stats slot'),
    );
    expect(find.text('Student stats slot'), findsOneWidget);
    expect(find.text('Enrolment number'), findsOneWidget);
    expect(find.text('0001'), findsOneWidget);
    expect(find.text('Student'), findsOneWidget);
    expect(find.text('SS'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
