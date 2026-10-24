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
      expect(find.text('75.0%'), findsOneWidget);
      expect(find.text('25.0%'), findsNothing);
      final denied = controller.load();
      await tester.pumpAndSettle();
      unawaited(denied);
      expect(find.text('75.0%'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
