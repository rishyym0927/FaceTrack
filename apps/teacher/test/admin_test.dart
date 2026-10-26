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
  // academics + offerings + admin teachers list, enough to populate dropdowns.
  return jsonResponse({'items': [], 'next_cursor': null});
}

/// Routes every lookup the admin screen loads, and records POST bodies.
RoutesAdapter _adapter(Map<String, dynamic> account, List<RequestOptions> posts) =>
    RoutesAdapter((r) async {
      if (r.method == 'POST') {
        posts.add(r);
        return jsonResponse({'id': '33333333-3333-4333-8333-333333333333'}, 201);
      }
      if (r.path == '/v1/me') return jsonResponse(account);
      if (r.path == '/v1/admin/teachers') {
        return jsonResponse({
          'items': [
            {'id': 't1', 'official_name': 'Dr Rao', 'employee_number': 'E10', 'status': 'approved'},
          ],
        });
      }
      if (r.path == '/v1/offerings') {
        return jsonResponse({
          'items': [
            {
              'id': 'o1', 'title': 'Compilers', 'course_code': 'CS401', 'term_code': 'T1',
              'branch': 'CSE', 'semester': 6, 'section': 'A', 'version': 1, 'status': 'active',
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

void main() {
  testWidgets('Admin screen shows academic creation forms', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    final posts = <RequestOptions>[];
    h.account = _teacherAndAdminAccount();
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    expect(find.text('Administration'), findsOneWidget);
    expect(find.text('Add term'), findsOneWidget);
    expect(find.text('Add course'), findsOneWidget);
    expect(find.text('Add class group'), findsOneWidget);
    expect(find.text('Add class (offering)'), findsOneWidget);
  });

  testWidgets('People section reveals a password field for login accounts', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    final posts = <RequestOptions>[];
    h.account = _teacherAndAdminAccount();
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await tester.tap(find.text('People'));
    await tester.pumpAndSettle();
    expect(find.text('Add teacher'), findsOneWidget);
    expect(find.text('Temporary password (min 8)'), findsNothing);
    // Toggle the first "create login" switch (teacher form).
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(find.text('Temporary password (min 8)'), findsOneWidget);
  });

  testWidgets('Granting a role posts to the admin memberships endpoint', (tester) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    final posts = <RequestOptions>[];
    h.account = _teacherAndAdminAccount();
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await tester.tap(find.text('Roles & assignments'));
    await tester.pumpAndSettle();
    // The Roles section has a single free-text field: the account UUID.
    await tester.enterText(find.byType(TextFormField), '44444444-4444-4444-8444-444444444444');
    await tester.tap(find.text('Update role'));
    await tester.pumpAndSettle();
    final membershipPosts = posts.where((p) => p.path == '/v1/admin/memberships').toList();
    expect(membershipPosts, hasLength(1));
    final body = membershipPosts.first.data as Map;
    expect(body['role'], 'teacher');
    expect(body['auth_user_id'], '44444444-4444-4444-8444-444444444444');
  });

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
