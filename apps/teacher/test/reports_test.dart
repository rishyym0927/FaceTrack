import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_teacher/teacher_reports.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  testWidgets(
    'Report resource changes discard stale responses and draft details are not fetched',
    (tester) async {
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      final old = Completer<ResponseBody>();
      var calls = 0, detailCalls = 0;
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path.startsWith('/v1/reports/')) {
          detailCalls++;
          return jsonResponse({'deliveries': [], 'email_configured': false});
        }
        calls++;
        if (r.path.contains('/old/')) return old.future;
        return jsonResponse({
          'items': [
            {
              'id': 'new-report',
              'kind': 'draft',
              'source_version': 2,
              'status': 'ready',
            },
          ],
        });
      });
      Widget app(String id) => MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TeacherReports(
              api: h.services.api,
              institute: institute,
              sessionId: id,
              supabaseUrl: 'https://fixture.supabase.invalid',
              sessionVersion: 1,
            ),
          ),
        ),
      );
      await tester.pumpWidget(app('old'));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Refresh reports'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(app('new'));
      await tester.pumpAndSettle();
      expect(find.text('Draft report · version 2'), findsOneWidget);
      old.complete(
        jsonResponse({
          'items': [
            {
              'id': 'old-report',
              'kind': 'draft',
              'source_version': 1,
              'status': 'ready',
            },
          ],
        }),
      );
      await tester.pumpAndSettle();
      expect(find.text('Draft report · version 1'), findsNothing);
      expect(calls, 2);
      expect(detailCalls, 0);
      h.services.api.dio.httpClientAdapter = RoutesAdapter(
        (r) async => jsonResponse({
          'error': {'code': 'FORBIDDEN'},
        }, 403),
      );
      await tester.tap(find.text('Refresh reports'));
      await tester.pumpAndSettle();
      expect(find.text('Draft report · version 2'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Final report loads detail and background polling pauses', (
    tester,
  ) async {
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var lists = 0, details = 0;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/reports/final-report') {
        details++;
        return jsonResponse({'deliveries': [], 'email_configured': false});
      }
      lists++;
      return jsonResponse({
        'items': [
          {
            'id': 'final-report',
            'kind': 'final',
            'source_version': 1,
            'status': 'processing',
          },
        ],
      });
    });
    await tester.pumpWidget(MaterialApp(
      theme: appTheme(),
      home: Scaffold(
        body: TeacherReports(
          api: h.services.api,
          institute: institute,
          sessionId: 'session',
          supabaseUrl: 'https://fixture.supabase.invalid',
          sessionVersion: 1,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(lists, 1);
    expect(details, 1);
    expect(find.text('Final report · version 1'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 9));
    expect(lists, 1);
    expect(details, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(lists, 2);
    expect(details, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('A failed load shows a plain message with a Retry action', (
    tester,
  ) async {
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    var fail = true;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (fail) {
        return jsonResponse({
          'error': {
            'code': 'UNAVAILABLE',
            'message': 'Reports are temporarily unavailable.',
          },
        }, 503);
      }
      return jsonResponse({
        'items': [
          {
            'id': 'r1',
            'kind': 'draft',
            'source_version': 3,
            'status': 'ready',
          },
        ],
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TeacherReports(
              api: h.services.api,
              institute: institute,
              sessionId: 'session',
              supabaseUrl: 'https://fixture.supabase.invalid',
              sessionVersion: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Instance of'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Draft report · version 3'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Retrying a report action after a failed response reuses its idempotency key', (
    tester,
  ) async {
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    final keys = <String?>[];
    var failRetry = true;
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/reports/r1/retry') {
        keys.add(r.headers['Idempotency-Key'] as String?);
        if (failRetry) {
          return jsonResponse({
            'error': {'code': 'UNAVAILABLE'},
          }, 503);
        }
        return jsonResponse({'id': 'r1'});
      }
      return jsonResponse({
        'items': [
          {'id': 'r1', 'kind': 'draft', 'source_version': 1, 'status': 'failed'},
        ],
      });
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: TeacherReports(
              api: h.services.api,
              institute: institute,
              sessionId: 'session',
              supabaseUrl: 'https://fixture.supabase.invalid',
              sessionVersion: 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry report generation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry report generation'));
    await tester.pumpAndSettle();
    expect(keys, hasLength(2));
    expect(keys[0], isNotNull);
    expect(keys[1], keys[0], reason: 'the same action must not look like a new one to the server');
    failRetry = false;
    await tester.tap(find.text('Retry report generation'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry report generation'));
    await tester.pumpAndSettle();
    // After a success the next action is a new one.
    expect(keys, hasLength(4));
    expect(keys[2], keys[0]);
    expect(keys[3], isNot(keys[2]));
    await tester.pumpWidget(const SizedBox());
  });
}
