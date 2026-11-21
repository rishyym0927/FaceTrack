import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_student/student_history.dart';

import '../../../packages/app_core/test/harness.dart';

void main() {
  testWidgets(
    'Attendance summary ignores stale refresh and clears on forbidden',
    (tester) async {
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      final old = Completer<ResponseBody>(), fresh = Completer<ResponseBody>();
      var calls = 0;
      ResponseBody data(int percentage) => jsonResponse({
        'items': [],
        'next_cursor': null,
        'summary': {
          'percentage': percentage,
          'present_or_late': 1,
          'assessed': 2,
          'unassessed': 0,
        },
      });
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path == '/v1/offerings/class') return jsonResponse({}, 404);
        if (r.path == '/v1/me/attendance-disputes') {
          return jsonResponse({'items': [], 'next_cursor': null});
        }
        calls++;
        if (calls == 2) return old.future;
        if (calls == 3) return fresh.future;
        if (calls == 4) {
          return jsonResponse({
            'error': {'code': 'FORBIDDEN'},
          }, 403);
        }
        return data(50);
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const StudentHistory(offering: 'class'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final controller = tester
          .widget<PagedList<Json>>(find.byType(PagedList<Json>))
          .controller;
      final first = controller.load();
      await tester.pump();
      final second = controller.load();
      await tester.pump();
      fresh.complete(data(75));
      await tester.pumpAndSettle();
      await second;
      old.complete(data(25));
      await tester.pumpAndSettle();
      // The older transport may still be completing; the UI must already
      // reflect the accepted newer response.
      unawaited(first);
      await tester.pumpAndSettle();
      // The summary is shown up front, not behind an expander.
      expect(find.text('Attendance summary'), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      expect(find.text('25%'), findsNothing);
      final denied = controller.load();
      await tester.pumpAndSettle();
      unawaited(denied);
      expect(find.text('75%'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Resolved query stays visible after a correction changes the publication id',
    (tester) async {
      final h = (await tester.runAsync(() => harness()))!;
      addTearDown(() => tester.runAsync(h.dispose));
      var disputeCalls = 0;
      h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
        if (r.path == '/v1/me') return jsonResponse(h.account);
        if (r.path == '/v1/me/attendance-disputes') {
          disputeCalls++;
          if (r.queryParameters['cursor'] == null) {
            return jsonResponse({'items': [], 'next_cursor': 'older-queries'});
          }
          expect(r.queryParameters['cursor'], 'older-queries');
          // The query was raised against the original Absent publication
          // ('pub1'); accepting it created a new publication ('pub2').
          return jsonResponse({
            'items': [
              {
                'id': 'dispute1',
                'session_id': 'sess1',
                'source_publication_id': 'pub1',
                'status': 'accepted',
                'resolution_reason': 'Corrected after review',
              },
            ],
            'next_cursor': null,
          });
        }
        if (r.queryParameters['cursor'] == 'older-records') {
          return jsonResponse({'items': [], 'next_cursor': null});
        }
        return jsonResponse({
          'items': [
            {
              'id': 'pub2',
              'session_id': 'sess1',
              'status': 'present',
              'revision': 2,
              'starts_at': '2026-10-20T09:00:00Z',
            },
          ],
          'next_cursor': 'older-records',
          'summary': {
            'percentage': 100,
            'present_or_late': 1,
            'assessed': 1,
            'unassessed': 0,
          },
        });
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [servicesProvider.overrideWithValue(h.services)],
          child: ProductApp(
            classesBuilder: (_) => const StudentHistory(offering: 'class'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Matched by session, not by the now-superseded publication id.
      expect(
        find.text(
          'Your query was accepted and a corrected publication was created.',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Faculty response: Corrected after review'),
        findsOneWidget,
      );
      expect(disputeCalls, 2);
      final loadMore = find.text('Load more');
      await tester.ensureVisible(loadMore);
      await tester.pumpAndSettle();
      await tester.tap(loadMore);
      await tester.pumpAndSettle();
      expect(disputeCalls, 2);
      expect(loadMore, findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Subject history shows summary first and lays out at 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1200);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final h = (await tester.runAsync(() => harness()))!;
    addTearDown(() => tester.runAsync(h.dispose));
    h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
      if (r.path == '/v1/me') return jsonResponse(h.account);
      if (r.path == '/v1/me/attendance-disputes') {
        return jsonResponse({'items': [], 'next_cursor': null});
      }
      if (r.path == '/v1/me/attendance') {
        return jsonResponse({
          'items': [
            {
              'id': 'p1',
              'session_id': 's1',
              'status': 'absent',
              'revision': 2,
              'reason': 'Left early',
              'starts_at': '2026-10-20T09:00:00Z',
            },
            {
              'id': 'p2',
              'session_id': 's2',
              'status': 'present',
              'revision': 1,
              'starts_at': '2026-10-21T09:00:00Z',
            },
          ],
          'next_cursor': null,
          'summary': {
            'percentage': 50,
            'present_or_late': 1,
            'assessed': 2,
            'unassessed': 0,
          },
        });
      }
      return jsonResponse({}, 404);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [servicesProvider.overrideWithValue(h.services)],
        child: ProductApp(
          classesBuilder: (_) => const StudentHistory(offering: 'class'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Attendance summary'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('Corrected by faculty'), findsOneWidget);
    expect(find.text('Faculty note: Left early'), findsOneWidget);
    // Only a published Absent result can be queried.
    await tester.ensureVisible(find.text('Raise query'));
    await tester.pumpAndSettle();
    expect(find.text('Raise query'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
