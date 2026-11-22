import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:facetrack_student/student_projection.dart';

import '../../../packages/app_core/test/harness.dart';

Json base({
  int remaining = 4,
  int canMiss = 1,
  bool reachable = true,
  int waiting = 0,
  num best = 87.5,
}) => {
  'basis': 'timetable',
  'remaining': remaining,
  'max_can_miss': canMiss,
  'reachable': reachable,
  'awaiting_publication': waiting,
  'best_possible_percentage': best,
  'threshold_percent': 75,
};

void main() {
  test('Says how many of the remaining classes can be missed', () {
    expect(
      projectionAdvice(base()),
      'Of the 4 classes left, you can miss up to 1 and still finish at or above 75%.',
    );
  });

  test('Singular and the zero-miss case', () {
    expect(
      projectionAdvice(base(remaining: 1, canMiss: 0)),
      'You need to attend all 1 class left to stay at or above 75%.',
    );
  });

  test('An unreachable threshold reports the best possible result', () {
    expect(
      projectionAdvice(
        base(remaining: 2, canMiss: 0, reachable: false, best: 66.7),
      ),
      'Even if you attend all 2 classes left, you cannot reach 75% (best possible 66.7%).',
    );
    expect(
      projectionAdvice(
        base(remaining: 2, canMiss: 0, reachable: false, best: 70),
      ),
      contains('best possible 70%'),
    );
  });

  test('No classes left and unpublished classes are explained', () {
    expect(
      projectionAdvice(base(remaining: 0, canMiss: 0)),
      'No more classes are left on the timetable.',
    );
    expect(
      projectionAdvice(base(waiting: 1)),
      endsWith('(Includes 1 class held but not published yet.)'),
    );
  });

  test('Nothing is said without a timetable or with bad data', () {
    expect(projectionAdvice(null), isNull);
    expect(projectionAdvice({'basis': 'none', 'remaining': null}), isNull);
    expect(projectionAdvice({...base(), 'remaining': 'many'}), isNull);
    expect(projectionAdvice({...base(), 'remaining': -1}), isNull);
    expect(projectionAdvice({...base(), 'max_can_miss': null}), isNull);
    expect(projectionAdvice({'basis': 'timetable'}), isNull);
  });

  test(
    'The threshold from the server is used, with the app value as fallback',
    () {
      expect(
        projectionAdvice({...base(), 'threshold_percent': 80}),
        contains('80%'),
      );
      final fallback = base()..remove('threshold_percent');
      expect(projectionAdvice(fallback), contains('75%'));
    },
  );

  for (final fail in [false, true]) {
    testWidgets(
      fail
          ? 'The note stays silent when the request fails'
          : 'The note shows the answer for the chosen subject',
      (tester) async {
        final h = (await tester.runAsync(() => harness()))!;
        addTearDown(() => tester.runAsync(h.dispose));
        final asked = <String>[];
        h.services.api.dio.httpClientAdapter = RoutesAdapter((r) async {
          if (r.path == '/v1/me') return jsonResponse(h.account);
          if (r.path == '/v1/me/attendance-projection') {
            asked.add('${r.queryParameters['offering_id']}');
            return fail
                ? jsonResponse({
                    'error': {'code': 'X'},
                  }, 500)
                : jsonResponse(base());
          }
          return jsonResponse({}, 404);
        });
        await tester.pumpWidget(
          ProviderScope(
            overrides: [servicesProvider.overrideWithValue(h.services)],
            child: ProductApp(classesBuilder: _note),
          ),
        );
        await tester.pumpAndSettle();
        expect(asked, ['ds']);
        expect(
          find.textContaining('you can miss up to 1'),
          fail ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Widget _note(BuildContext _) =>
    const Scaffold(body: ProjectionNote(offeringId: 'ds'));
