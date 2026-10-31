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
}
