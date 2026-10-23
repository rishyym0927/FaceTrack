import 'dart:async';

import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'harness.dart';

void main() {
  test('Mutation retries retain a key, changes require a fresh key', () {
    final m = Mutation();
    final first = m.forBody({'value': 'code', 'version': 1});
    expect(m.forBody({'value': 'code', 'version': 1}), first);
    expect(m.forBody({'value': 'different', 'version': 1}), isNot(first));
    final second = m.key;
    expect(m.forBody({'value': 'different', 'version': 2}), isNot(second));
  });
  test('Old page responses cannot overwrite a newer refresh', () async {
    final a = Completer<PageData<String>>(), b = Completer<PageData<String>>();
    var calls = 0;
    final controller = PagedController<String>(
      (_) => calls++ == 0 ? a.future : b.future,
    );
    final first = controller.load(), second = controller.load();
    b.complete(PageData(['new'], null));
    await second;
    a.complete(PageData(['old'], null));
    await first;
    expect(controller.items, ['new']);
    controller.dispose();
  });
  test(
    'A failed refresh retries as replacement without duplicate rows',
    () async {
      var calls = 0;
      final controller = PagedController<String>((_) async {
        if (++calls == 2) throw const AppFailure('Offline');
        return PageData(['one'], null);
      });
      await controller.load();
      await controller.load();
      expect(controller.items, ['one']);
      await controller.retry();
      expect(controller.items, ['one']);
      controller.dispose();
    },
  );
  test('Forbidden refresh removes previously visible protected rows', () async {
    var calls = 0;
    final controller = PagedController<String>((_) async {
      if (++calls == 2) throw const AppFailure('Forbidden', status: 403);
      return PageData(['private'], null);
    });
    await controller.load();
    await controller.load();
    expect(controller.items, isEmpty);
    controller.dispose();
  });
  test('A response from a signed-out account is discarded', () async {
    final h = await harness();
    addTearDown(h.dispose);
    final gate = Completer<void>();
    h.services.api.dio.httpClientAdapter = RoutesAdapter((_) async {
      await gate.future;
      return jsonResponse({'value': 'private'});
    });
    final response = h.services.api.send('GET', '/delayed');
    final expectation = expectLater(response, throwsA(isA<AppFailure>()));
    await Future<void>.delayed(Duration.zero);
    h.services.api.clear();
    await h.services.client.auth.signOut();
    gate.complete();
    await expectation;
  });
  test('Disconnected local native API gives actionable guidance without masking HTTP errors', () async {
    final h = await harness();
    addTearDown(h.dispose);
    h.services.api.dio.options.baseUrl = 'http://127.0.0.1:8000';
    h.services.api.dio.httpClientAdapter = RoutesAdapter((request) async {
      throw DioException(
        requestOptions: request,
        type: DioExceptionType.connectionError,
      );
    });
    await expectLater(
      h.services.api.send('GET', '/v1/offerings'),
      throwsA(
        isA<AppFailure>().having(
          (e) => e.code,
          'code',
          'development_api_unreachable',
        ),
      ),
    );
    h.services.api.dio.httpClientAdapter = RoutesAdapter(
      (_) async => jsonResponse({}, 403),
    );
    await expectLater(
      h.services.api.send('GET', '/v1/offerings'),
      throwsA(isA<AppFailure>().having((e) => e.status, 'status', 403)),
    );
  });
  test(
    'Upload expiry explains recovery instead of a generic record conflict',
    () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.services.api.dio.httpClientAdapter = RoutesAdapter(
        (_) async => jsonResponse({
          'error': {'code': 'UPLOAD_EXPIRED', 'request_id': 'fixture'},
        }, 409),
      );
      await expectLater(
        h.services.api.send(
          'POST',
          '/v1/biometric-enrollments/fixture/upload-grant',
        ),
        throwsA(
          isA<AppFailure>()
              .having((e) => e.code, 'code', 'UPLOAD_EXPIRED')
              .having(
                (e) => e.message,
                'actionable message',
                contains('record a new video'),
              ),
        ),
      );
    },
  );
  testWidgets(
    'Narrow large-text login validates input and supports password visibility',
    (tester) async {
      final h = (await tester.runAsync(() => harness(signedIn: false)))!;
      addTearDown(() => tester.runAsync(h.dispose));
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: MaterialApp(
            theme: appTheme(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: const LoginPage(),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Sign in'));
      await tester.tap(find.text('Sign in'));
      await tester.pump();
      expect(find.text('Enter a valid email address.'), findsOneWidget);
      expect(find.text('This field is required.'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Show password'));
      await tester.tap(find.byTooltip('Show password'));
      await tester.pump();
      expect(find.byTooltip('Hide password'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'A student cannot enter Teacher screens and logout removes protected state',
    (tester) async {
      final h = (await tester.runAsync(
        () => harness(role: AppRole.teacher, profileRole: 'student'),
      ))!;
      var mediaCleared = false;
      h.services.clearPrivateMedia = () async {
        mediaCleared = true;
      };
      addTearDown(() => tester.runAsync(h.dispose));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const Text('Protected teacher content'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Account access unavailable'), findsOneWidget);
      expect(find.text('FaceTrack Teacher'), findsOneWidget);
      expect(find.text('Signed in as fixture@example.test'), findsOneWidget);
      expect(find.text('Protected teacher content'), findsNothing);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Welcome back'), findsOneWidget);
      expect(h.services.client.auth.currentUser, isNull);
      expect(mediaCleared, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'Unlinked students see identity claim, never teacher provisioning',
    (tester) async {
      final h = (await tester.runAsync(() => harness(profileRole: null)))!;
      addTearDown(() => tester.runAsync(h.dispose));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const Text('Classes content'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Link your student identity'), findsOneWidget);
      expect(find.text('Classes content'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('Navigation adapts between rail and bottom bar', (tester) async {
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(classesBuilder: (_) => const Text('Classes content')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NavigationRail), findsOneWidget);
    tester.view.physicalSize = const Size(390, 844);
    await tester.pumpAndSettle();
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Mutation dialogs suppress repeated taps while saving', (
    tester,
  ) async {
    final gate = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => ActionDialog(
                  title: 'Approve student?',
                  child: const Text('Confirm membership.'),
                  submit: (_) async {
                    calls++;
                    await gate.future;
                  },
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Confirm'));
    await tester.pump();
    expect(find.text('Saving…'), findsOneWidget);
    expect(calls, 1);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Approve student?'), findsNothing);
  });
}
