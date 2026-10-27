import 'package:dio/dio.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_admin.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/app_core/test/harness.dart';

Map<String, dynamic> _teacherAndAdminAccount() => {
  'user_id': actor,
  'memberships': [
    {
      'id': 'm1',
      'institute_id': institute,
      'institute_name': 'Test Institute',
      'role': 'teacher',
      'status': 'active',
    },
    {
      'id': 'm2',
      'institute_id': institute,
      'institute_name': 'Test Institute',
      'role': 'admin',
      'status': 'active',
    },
  ],
  'students': const [],
  'teachers': [
    {
      'id': 'teacher',
      'institute_id': institute,
      'official_name': 'Synthetic Teacher',
      'employee_number': 'T01',
      'status': 'approved',
    },
  ],
};

ResponseBody _lookups() {
  // academics + offerings + admin lists, enough to populate dropdowns.
  return jsonResponse({'items': [], 'next_cursor': null});
}

/// Routes every lookup the admin screen loads, and records POST bodies.
/// [academics] optionally returns items for `/v1/academics/{kind}`.
RoutesAdapter _adapter(
  Map<String, dynamic> account,
  List<RequestOptions> posts, {
  Map<String, List<Map<String, dynamic>>> academics = const {},
  List<Map<String, dynamic>> students = const [],
}) =>
    RoutesAdapter((r) async {
      if (r.method == 'POST') {
        posts.add(r);
        return jsonResponse({'id': '33333333-3333-4333-8333-333333333333'}, 201);
      }
      if (r.path == '/v1/me') return jsonResponse(account);
      if (r.path.startsWith('/v1/academics/')) {
        final kind = r.path.split('/').last;
        return jsonResponse({'items': academics[kind] ?? [], 'next_cursor': null});
      }
      if (r.path == '/v1/admin/teachers') {
        return jsonResponse({
          'items': [
            {
              'id': 't1', 'official_name': 'Dr Rao', 'employee_number': 'E10',
              'official_email': 'rao@example.edu', 'status': 'approved',
              'auth_user_id': '55555555-5555-4555-8555-555555555555',
            },
          ],
        });
      }
      if (r.path == '/v1/admin/students') return jsonResponse({'items': students});
      if (r.path == '/v1/offerings') {
        return jsonResponse({
          'items': [
            {
              'id': 'o1', 'title': 'Compilers', 'course_code': 'BCS 401', 'term_code': '2026-ODD',
              'branch': 'CSE', 'semester': 6, 'section': 'CSE1', 'version': 1, 'status': 'active',
            },
          ],
          'next_cursor': null,
        });
      }
      return _lookups();
    });

Future<void> _pumpAdmin(WidgetTester tester, Harness h) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [servicesProvider.overrideWithValue(h.services)],
      child: MaterialApp(
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) {
              final auth = ref.watch(authProvider);
              if (auth.institute == null) return const SizedBox.shrink();
              return const TeacherAdmin();
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<Harness> _admin(WidgetTester tester) async {
  final h = (await tester.runAsync(
    () => harness(role: AppRole.teacher, profileRole: 'teacher'),
  ))!;
  addTearDown(() => tester.runAsync(h.dispose));
  h.account = _teacherAndAdminAccount();
  return h;
}

void main() {
  testWidgets('Admin opens on a setup checklist that names the next step', (tester) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(h.account, []);
    await _pumpAdmin(tester, h);
    expect(find.text('Administration'), findsOneWidget);
    expect(find.text('Setup checklist'), findsOneWidget);
    expect(find.text('Next: create the semester term.'), findsOneWidget);
    // Faculty and allocations exist in the fixture; terms do not.
    expect(find.textContaining('of 6 setup steps done'), findsOneWidget);
  });

  testWidgets('Checklist counts follow the data and jump to the right form', (tester) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(h.account, [], academics: {
      'terms': [
        {'id': 'term1', 'code': '2026-ODD', 'starts_on': '2026-08-03', 'ends_on': '2026-12-15', 'version': 1},
      ],
    });
    await _pumpAdmin(tester, h);
    expect(find.text('Next: add subjects.'), findsOneWidget);
    await tester.tap(find.text('Do it now'));
    await tester.pumpAndSettle();
    expect(find.text('Subject code (e.g. BCS 201)'), findsOneWidget);
    // The term created earlier is listed under its form with the institute wording.
    await tester.tap(find.text('Show 1 existing semester terms'));
    await tester.pumpAndSettle();
    // Also shown as the pre-selected term in the section form's dropdown.
    expect(find.text('Odd Semester 2026 (2026-ODD)'), findsNWidgets(2));
  });

  testWidgets('Academic setup shows every creation form', (tester) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(h.account, []);
    await _pumpAdmin(tester, h);
    await tester.tap(find.text('1 · Academic setup'));
    await tester.pumpAndSettle();
    expect(find.text('Add semester term'), findsOneWidget);
    expect(find.text('Add subject'), findsOneWidget);
    expect(find.text('Add section'), findsOneWidget);
    expect(find.text('Allocate subject to a section'), findsOneWidget);
  });

  testWidgets('People section reveals a password field and searchable directories', (tester) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(h.account, [], students: [
      {'id': 's1', 'official_name': 'Asha Verma', 'enrollment_number': '0001', 'official_email': 'asha@example.edu', 'status': 'approved'},
      {'id': 's2', 'official_name': 'Bina Rao', 'enrollment_number': '0002', 'official_email': 'bina@example.edu', 'status': 'approved'},
    ]);
    await _pumpAdmin(tester, h);
    await tester.tap(find.text('2 · People'));
    await tester.pumpAndSettle();
    expect(find.text('Add faculty'), findsOneWidget);
    expect(find.text('Faculty directory (1)'), findsOneWidget);
    expect(find.text('Student directory (2)'), findsOneWidget);
    expect(find.text('Temporary password (min 8)'), findsNothing);
    // Toggle the first "create login" switch (faculty form).
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('Temporary password (min 8)'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Search name, number or email').last, 'bina');
    await tester.pumpAndSettle();
    expect(find.text('Bina Rao'), findsOneWidget);
    expect(find.text('Asha Verma'), findsNothing);
  });

  testWidgets('Granting a role picks a person instead of pasting an id', (tester) async {
    final h = await _admin(tester);
    final posts = <RequestOptions>[];
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await tester.tap(find.text('3 · Access & assignments'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Person with a login account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dr Rao (E10) · Faculty').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update role'));
    await tester.pumpAndSettle();
    final membershipPosts = posts.where((p) => p.path == '/v1/admin/memberships').toList();
    expect(membershipPosts, hasLength(1));
    final body = membershipPosts.first.data as Map;
    expect(body['role'], 'teacher');
    expect(body['auth_user_id'], '55555555-5555-4555-8555-555555555555');
  });

  testWidgets('Advanced role grant still accepts an account id', (tester) async {
    final h = await _admin(tester);
    final posts = <RequestOptions>[];
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await tester.tap(find.text('3 · Access & assignments'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced: enter an account ID'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Account user id (UUID)'),
      '44444444-4444-4444-8444-444444444444',
    );
    await tester.tap(find.text('Update role'));
    await tester.pumpAndSettle();
    final body = posts.singleWhere((p) => p.path == '/v1/admin/memberships').data as Map;
    expect(body['auth_user_id'], '44444444-4444-4444-8444-444444444444');
  });

  for (final width in [360.0, 768.0, 1440.0]) {
    testWidgets('Admin stays usable at $width and 200% text', (tester) async {
      final h = await _admin(tester);
      h.services.api.dio.httpClientAdapter = _adapter(h.account, []);
      tester.view.physicalSize = Size(width, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(size: Size(width, 3000), textScaler: const TextScaler.linear(2)),
              child: Scaffold(
                body: Consumer(
                  builder: (context, ref, _) {
                    final auth = ref.watch(authProvider);
                    if (auth.institute == null) return const SizedBox.shrink();
                    return const TeacherAdmin();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Setup checklist'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (final tab in ['1 · Academic setup', '2 · People', '3 · Access & assignments']) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: tab);
      }
    });
  }

  testWidgets('Admin navigation tab is offered to an admin account', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.account = _teacherAndAdminAccount();
    h.services.api.dio.httpClientAdapter = _adapter(h.account, <RequestOptions>[]);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              final auth = ref.watch(authProvider);
              if (auth.institute == null) return const SizedBox.shrink();
              return const ProductShell(
                path: '/classes',
                hasAdmin: true,
                child: SizedBox.shrink(),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Admin'), findsWidgets);
  });
}
