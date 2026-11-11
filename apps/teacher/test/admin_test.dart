import 'package:dio/dio.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_admin.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
}) => RoutesAdapter((r) async {
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
          'id': 't1',
          'official_name': 'Dr Rao',
          'employee_number': 'E10',
          'official_email': 'rao@example.edu',
          'status': 'approved',
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
          'id': 'o1',
          'title': 'Compilers',
          'course_code': 'BCS 401',
          'term_code': '2026-ODD',
          'branch': 'CSE',
          'semester': 6,
          'section': 'CSE1',
          'version': 1,
          'status': 'active',
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
  // The tour is covered by its own tests; elsewhere it has already been seen.
  setUp(
    () =>
        SharedPreferences.setMockInitialValues({adminTourSeenKey(actor): true}),
  );

  Future<void> section(WidgetTester tester, String name) async {
    await tester.tap(find.text(name).first);
    await tester.pumpAndSettle();
  }

  testWidgets('Admin opens on a console that names the next step', (
    tester,
  ) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(h.account, []);
    await _pumpAdmin(tester, h);
    expect(find.text('Administration'), findsOneWidget);
    expect(find.text('Take the tour'), findsOneWidget);
    expect(find.text('Setup checklist'), findsOneWidget);
    expect(find.text('Next: create the semester term.'), findsOneWidget);
    // Faculty and allocations exist in the fixture; terms do not.
    expect(find.textContaining('of 6 setup steps done'), findsOneWidget);
    expect(find.text('2/6'), findsOneWidget);
    expect(find.text('Quick actions'), findsOneWidget);
  });

  testWidgets(
    '"Do it now" opens the next form in a dialog, and Cancel closes it',
    (tester) async {
      final h = await _admin(tester);
      h.services.api.dio.httpClientAdapter = _adapter(
        h.account,
        [],
        academics: {
          'terms': [
            {
              'id': 'term1',
              'code': '2026-ODD',
              'starts_on': '2026-08-03',
              'ends_on': '2026-12-15',
              'version': 1,
            },
          ],
        },
      );
      await _pumpAdmin(tester, h);
      expect(find.text('Next: add subjects.'), findsOneWidget);
      await tester.tap(find.text('Do it now'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Subject code (e.g. BCS 201)'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    },
  );

  testWidgets('Creating a record posts it, closes the form and refreshes', (
    tester,
  ) async {
    final h = await _admin(tester);
    final posts = <RequestOptions>[];
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await section(tester, 'Academic setup');
    await tester.tap(find.text('Add term'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Semester term code (e.g. 2026-ODD)'),
      '2026-ODD',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Start date (YYYY-MM-DD)'),
      '2026-08-03',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'End date (YYYY-MM-DD)'),
      '2026-12-15',
    );
    await tester.tap(find.text('Create semester term'));
    await tester.pumpAndSettle();
    final body =
        posts.singleWhere((p) => p.path == '/v1/admin/terms').data as Map;
    expect(body, {
      'code': '2026-ODD',
      'starts_on': '2026-08-03',
      'ends_on': '2026-12-15',
    });
    expect(find.byType(Dialog), findsNothing);
    expect(find.text('Semester term created.'), findsOneWidget);
  });

  testWidgets('A failed create keeps the form open with the reason', (
    tester,
  ) async {
    final h = await _admin(tester);
    final inner = _adapter(h.account, []);
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.method == 'POST') {
        return jsonResponse({
          'error': {
            'code': 'CONFLICT',
            'message': 'That code already exists.',
            'request_id': 'r',
            'retryable': false,
          },
        }, 409);
      }
      return inner.fetch(r, null, null);
    });
    await _pumpAdmin(tester, h);
    await section(tester, 'Academic setup');
    await tester.tap(find.text('Add subject'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Subject code (e.g. BCS 201)'),
      'BCS 201',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Subject name'),
      'Algorithms',
    );
    await tester.tap(find.text('Create subject'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.textContaining('already exists'), findsWidgets);
  });

  testWidgets('Academic cards lock Add until the prerequisite exists', (
    tester,
  ) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(h.account, []);
    await _pumpAdmin(tester, h);
    await section(tester, 'Academic setup');
    expect(find.text('Create a semester term first.'), findsOneWidget);
    final add = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Add section'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(add.onPressed, isNull);
    expect(find.text('Add a subject first.'), findsOneWidget);
  });

  testWidgets('Every academic building block has its own card and help', (
    tester,
  ) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(
      h.account,
      [],
      academics: {
        'terms': [
          {
            'id': 'term1',
            'code': '2026-ODD',
            'starts_on': '2026-08-03',
            'ends_on': '2026-12-15',
            'version': 1,
          },
        ],
      },
    );
    await _pumpAdmin(tester, h);
    await section(tester, 'Academic setup');
    for (final t in ['Semester terms', 'Subjects', 'Sections', 'Allocations']) {
      expect(find.text(t), findsWidgets);
    }
    expect(find.text('Odd Semester 2026 (2026-ODD)'), findsOneWidget);
    await tester.tap(find.text('View all 1').first);
    await tester.pumpAndSettle();
    expect(find.text('Semester terms (1)'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    // Help explains a term on tap.
    await tester.tap(find.byIcon(Icons.info_outline).first);
    await tester.pumpAndSettle();
    expect(find.text('Got it'), findsOneWidget);
  });

  testWidgets(
    'People: tabs, search, login filter and a hidden-by-default password',
    (tester) async {
      final h = await _admin(tester);
      h.services.api.dio.httpClientAdapter = _adapter(
        h.account,
        [],
        students: [
          {
            'id': 's1',
            'official_name': 'Asha Verma',
            'enrollment_number': '0001',
            'official_email': 'asha@example.edu',
            'status': 'approved',
          },
          {
            'id': 's2',
            'official_name': 'Bina Rao',
            'enrollment_number': '0002',
            'official_email': 'bina@example.edu',
            'status': 'approved',
            'auth_user_id': '66666666-6666-4666-8666-666666666666',
          },
        ],
      );
      await _pumpAdmin(tester, h);
      await section(tester, 'People');
      expect(find.text('Faculty directory (1)'), findsOneWidget);
      await tester.tap(find.text('Students 2'));
      await tester.pumpAndSettle();
      expect(find.text('Student directory (2)'), findsOneWidget);
      await tester.tap(find.text('Needs login 1'));
      await tester.pumpAndSettle();
      expect(find.text('Asha Verma'), findsOneWidget);
      expect(find.text('Bina Rao'), findsNothing);
      await tester.tap(find.text('All 2'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search name, number or email'),
        'bina',
      );
      await tester.pumpAndSettle();
      expect(find.text('Bina Rao'), findsOneWidget);
      expect(find.text('Asha Verma'), findsNothing);
      // Add student: the temporary password appears only with a login, and is hidden.
      await tester.tap(find.text('Add student'));
      await tester.pumpAndSettle();
      expect(find.text('Temporary password (min 8)'), findsNothing);
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.widgetWithText(TextFormField, 'Temporary password (min 8)'),
          matching: find.byType(TextField),
        ),
      );
      expect(field.obscureText, isTrue);
    },
  );

  testWidgets(
    'An existing student without a login gets one from the directory',
    (tester) async {
      final h = await _admin(tester);
      final posts = <RequestOptions>[];
      h.services.api.dio.httpClientAdapter = _adapter(
        h.account,
        posts,
        students: [
          {
            'id': 's1',
            'official_name': 'Asha Verma',
            'enrollment_number': '0101',
            'official_email': 'asha@example.edu',
            'status': 'approved',
          },
        ],
      );
      await _pumpAdmin(tester, h);
      await section(tester, 'People');
      await tester.tap(find.text('Students 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create login'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('asha@example.edu and this temporary password'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Temporary password (min 8)').last,
        'short',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create login'));
      await tester.pumpAndSettle();
      expect(find.text('At least 8 characters.'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Temporary password (min 8)').last,
        'long-enough-1',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create login'));
      await tester.pumpAndSettle();
      final login = posts.singleWhere(
        (p) => p.path == '/v1/admin/students/s1/login',
      );
      expect((login.data as Map)['password'], 'long-enough-1');
    },
  );

  testWidgets('Granting a role picks a person instead of pasting an id', (
    tester,
  ) async {
    final h = await _admin(tester);
    final posts = <RequestOptions>[];
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await section(tester, 'Access');
    await tester.tap(find.text('Grant or change a role'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Person with a login account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dr Rao (E10) · Faculty').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Update role'));
    await tester.pumpAndSettle();
    final membershipPosts = posts
        .where((p) => p.path == '/v1/admin/memberships')
        .toList();
    expect(membershipPosts, hasLength(1));
    final body = membershipPosts.first.data as Map;
    expect(body['role'], 'teacher');
    expect(body['auth_user_id'], '55555555-5555-4555-8555-555555555555');
  });

  testWidgets('Advanced role grant still accepts an account id', (
    tester,
  ) async {
    final h = await _admin(tester);
    final posts = <RequestOptions>[];
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await section(tester, 'Access');
    await tester.tap(find.text('Grant or change a role'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced: enter an account ID'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Account user id (UUID)'),
      '44444444-4444-4444-8444-444444444444',
    );
    await tester.tap(find.text('Update role'));
    await tester.pumpAndSettle();
    final body =
        posts.singleWhere((p) => p.path == '/v1/admin/memberships').data as Map;
    expect(body['auth_user_id'], '44444444-4444-4444-8444-444444444444');
  });

  testWidgets('Assigning faculty posts the chosen subject and faculty', (
    tester,
  ) async {
    final h = await _admin(tester);
    final posts = <RequestOptions>[];
    h.services.api.dio.httpClientAdapter = _adapter(h.account, posts);
    await _pumpAdmin(tester, h);
    await section(tester, 'Access');
    await tester.tap(find.text('Assign faculty'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subject').last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Compilers').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Faculty').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dr Rao (E10)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Assign'));
    await tester.pumpAndSettle();
    final body =
        posts.singleWhere((p) => p.path == '/v1/admin/assignments').data as Map;
    expect(body, {
      'offering_id': 'o1',
      'teacher_id': 't1',
      'can_finalize': true,
    });
  });

  testWidgets(
    'The guided tour opens on request, walks the sections and can be restarted',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final h = await _admin(tester);
      h.services.api.dio.httpClientAdapter = _adapter(h.account, []);
      await _pumpAdmin(tester, h);
      expect(find.text('Welcome to the Admin console'), findsNothing);
      await tester.tap(find.text('Take the tour'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome to the Admin console'), findsOneWidget);
      expect(find.text('Step 1 of 11'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Your setup progress'), findsOneWidget);
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 11'), findsOneWidget);
      // Walk to the Academic setup step: the tour opens that section itself.
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Step 6 of 11'), findsOneWidget);
      expect(find.text('Semester terms'), findsWidgets);
      await tester.tap(find.text('Skip tour'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Step '), findsNothing);
      final prefs = await tester.runAsync(SharedPreferences.getInstance);
      expect(prefs!.getBool(adminTourSeenKey(actor)), isTrue);
      await tester.tap(find.text('Take the tour'));
      await tester.pumpAndSettle();
      expect(find.text('Step 1 of 11'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.textContaining('Step '), findsNothing);
    },
  );

  testWidgets('A seen tour does not start again', (tester) async {
    final h = await _admin(tester);
    h.services.api.dio.httpClientAdapter = _adapter(h.account, []);
    await _pumpAdmin(tester, h);
    expect(find.text('Welcome to the Admin console'), findsNothing);
  });

  for (final width in [360.0, 768.0, 1440.0]) {
    testWidgets('Admin stays usable at $width and 200% text, tour included', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
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
              data: MediaQueryData(
                size: Size(width, 3000),
                textScaler: const TextScaler.linear(2),
              ),
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
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Take the tour'));
      await tester.pumpAndSettle();
      // Walk the whole tour: every step must lay out at this width.
      for (var i = 0; i < 11; i++) {
        expect(find.text('Step ${i + 1} of 11'), findsOneWidget);
        await tester.tap(find.text(i == 10 ? 'Finish' : 'Next'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'tour step ${i + 1}');
      }
      for (final name in ['Academic setup', 'People', 'Access', 'Overview']) {
        await section(tester, name);
        expect(tester.takeException(), isNull, reason: name);
      }
    });
  }

  testWidgets('Admin navigation tab is offered to an admin account', (
    tester,
  ) async {
    final h = (await tester.runAsync(
      () => harness(role: AppRole.teacher, profileRole: 'teacher'),
    ))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.account = _teacherAndAdminAccount();
    h.services.api.dio.httpClientAdapter = _adapter(
      h.account,
      <RequestOptions>[],
    );
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
