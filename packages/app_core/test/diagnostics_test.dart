import 'dart:async';

import 'package:dio/dio.dart' show DioException, DioExceptionType, RequestOptions, Response;
import 'package:facetrack_core/facetrack_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const session = '33333333-3333-3333-3333-333333333333';

void main() {
  group('what may be recorded', () {
    test('routes lose ids and query strings', () {
      expect(
        Diagnostics.routeTemplate('/v1/sessions/$session/attendance?cursor=x'),
        '/v1/sessions/{id}/attendance',
      );
      expect(Diagnostics.routeTemplate('/v1/offerings/42'), '/v1/offerings/{n}');
      expect(Diagnostics.routeTemplate('v1/me'), '/v1/me');
      expect(Diagnostics.routeTemplate('/v1/x/${'a' * 300}').length, 100);
    });
    test('codes keep only safe characters', () {
      expect(Diagnostics.safeCode('TimeoutException'), 'TimeoutException');
      expect(Diagnostics.safeCode('a b "c" <d@e.f>'), 'a_b__c___d_e.f_');
      expect(Diagnostics.safeCode(''), isNull);
      expect(Diagnostics.safeCode(null), isNull);
      expect(Diagnostics.safeCode('x' * 100)!.length, 60);
    });
    test('an event carries only the whitelisted fields and bounded numbers', () {
      final d = Diagnostics(app: 'teacher', platform: 'android');
      addTearDown(d.dispose);
      d.record(
        'upload_retry',
        sessionId: session,
        code: 'CONNECTION',
        route: '/v1/captures/$session/upload-grant',
        status: 503,
        attempt: 5000,
        seconds: 99999,
        bytes: 1234,
        durationMs: 12,
        count: 3,
      );
      final event = d.pending.single;
      expect(event.keys.toSet(), {
        'name', 'session_id', 'code', 'route', 'status', 'attempt', 'seconds',
        'bytes', 'duration_ms', 'count',
      });
      expect(event['route'], '/v1/captures/{id}/upload-grant');
      expect(event['attempt'], 1000);
      expect(event['seconds'], 3600);
    });
    test('a session id that is not a UUID is dropped, never sent', () {
      final d = Diagnostics(app: 'student', platform: 'web');
      addTearDown(d.dispose);
      d.record('app_error', sessionId: 'Asha Rao');
      d.record('app_error', status: 42, attempt: -1, bytes: -5);
      expect(d.pending[0].containsKey('session_id'), isFalse);
      expect(d.pending[1].keys, ['name']); // out-of-range numbers are left out
    });
  });

  group('sending', () {
    late DateTime now;
    setUp(() => now = DateTime(2026, 1, 1, 10));
    Diagnostics make({
      required Future<void> Function(Map<String, dynamic>) send,
      String version = '1.2.3',
      int maxBuffered = 100,
    }) {
      final d = Diagnostics(
        app: 'teacher',
        platform: 'web',
        version: version,
        maxBuffered: maxBuffered,
        send: send,
        clock: () => now,
      );
      addTearDown(d.dispose);
      return d;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('the first event goes out with app, platform and version; later ones batch', () async {
      final sent = <Map<String, dynamic>>[];
      final d = make(send: (batch) async => sent.add(batch));
      d.record('scan_started', sessionId: session);
      await settle();
      expect(sent.length, 1);
      expect(sent.single['app'], 'teacher');
      expect(sent.single['platform'], 'web');
      expect(sent.single['version'], '1.2.3');
      // Within the interval, events wait and are sent together with the next due one.
      now = now.add(const Duration(seconds: 3));
      d.record('segment_recorded', bytes: 1000);
      d.record('segment_recorded', bytes: 2000);
      await settle();
      expect(sent.length, 1);
      expect(d.pending.length, 2);
      now = now.add(const Duration(seconds: 10));
      d.record('upload_done', count: 1);
      await settle();
      expect(sent.length, 2);
      expect((sent.last['events'] as List).length, 3);
      expect(d.pending, isEmpty);
    });
    test('an invalid version is never sent', () async {
      final sent = <Map<String, dynamic>>[];
      final d = make(send: (batch) async => sent.add(batch), version: 'has spaces!');
      d.record('scan_started');
      await settle();
      expect(sent.single.containsKey('version'), isFalse);
    });
    test('twenty waiting events are sent at once, never more than 50 per request', () async {
      final sizes = <int>[];
      final d = make(send: (batch) async => sizes.add((batch['events'] as List).length));
      d.record('scan_started');
      await settle();
      sizes.clear();
      for (var i = 0; i < 20; i++) {
        d.record('segment_recorded', count: i);
      }
      await settle();
      expect(sizes, [20]);
      for (var i = 0; i < 60; i++) {
        d.record('segment_recorded', count: i);
      }
      await d.flush();
      await d.flush();
      expect(sizes.every((n) => n <= 50), isTrue);
    });
    test('urgent events are sent immediately, ordinary ones wait', () async {
      final sent = <int>[];
      final d = make(send: (batch) async => sent.add((batch['events'] as List).length));
      d.record('scan_started');
      await settle();
      d.record('segment_recorded', count: 1);
      await settle();
      expect(sent, [1]); // ordinary: waits for the interval
      for (final urgent in Diagnostics.urgent) {
        sent.clear();
        d.record(urgent);
        await settle();
        expect(sent, isNotEmpty, reason: urgent);
      }
    });
    test('a failed send keeps the events and backs off, then succeeds later', () async {
      var fail = true;
      final sent = <int>[];
      final d = make(send: (batch) async {
        if (fail) throw StateError('offline');
        sent.add((batch['events'] as List).length);
      });
      d.record('upload_failed', code: 'OFFLINE');
      await settle();
      expect(d.pending.length, 1); // kept, not lost
      fail = false;
      now = now.add(const Duration(seconds: 20));
      d.record('upload_failed', code: 'OFFLINE'); // still inside the back-off window
      await settle();
      expect(sent, isEmpty);
      now = now.add(const Duration(minutes: 2));
      d.record('upload_failed', code: 'OFFLINE');
      await settle();
      expect(sent, [3]);
      expect(d.pending, isEmpty);
    });
    test('going to the background flushes even during a back-off', () async {
      var fail = true;
      final sent = <int>[];
      final d = make(send: (batch) async {
        if (fail) throw StateError('offline');
        sent.add((batch['events'] as List).length);
      });
      d.record('app_error');
      await settle();
      fail = false;
      await d.flush(); // what the app does when it is backgrounded
      expect(sent, [1]);
    });
    test('a batch the server rejects is dropped so it cannot block the rest', () async {
      var calls = 0;
      final d = make(send: (batch) async {
        calls++;
        throw DioException(
          requestOptions: RequestOptions(path: '/v1/client-events'),
          response: Response(
            requestOptions: RequestOptions(path: '/v1/client-events'),
            statusCode: 422,
          ),
        );
      });
      d.record('upload_failed', code: 'X');
      await settle();
      expect(calls, 1);
      expect(d.pending, isEmpty); // not retried forever
    });
    test('a throttled or unreachable server keeps the events', () async {
      for (final status in [429, 503, null]) {
        final d = make(send: (batch) async {
          throw DioException(
            requestOptions: RequestOptions(path: '/v1/client-events'),
            response: status == null
                ? null
                : Response(
                    requestOptions: RequestOptions(path: '/v1/client-events'),
                    statusCode: status,
                  ),
          );
        });
        d.record('upload_failed', code: 'X');
        await settle();
        expect(d.pending.length, 1, reason: '$status');
      }
    });
    test('bytes are clamped to what the server accepts, and clear() forgets everything', () async {
      final d = make(send: (_) async => throw StateError('offline'));
      d.record('segment_recorded', bytes: 5000000000);
      expect(d.pending.single['bytes'], 1000000000);
      d.clear();
      expect(d.pending, isEmpty);
    });
    test('the buffer is bounded: the oldest events are dropped', () async {
      final d = make(send: (_) async => throw StateError('offline'), maxBuffered: 5);
      for (var i = 0; i < 8; i++) {
        d.record('segment_recorded', count: i);
      }
      expect(d.pending.length, 5);
      expect(d.pending.first['count'], 3);
      expect(d.dropped, 3);
    });
    test('nothing is sent while signed out, and nothing ever throws', () async {
      final d = make(send: (_) async => throw StateError('Not signed in.'));
      d.record('app_error');
      await d.flush();
      expect(d.pending.length, 1);
    });
    test('uses no timers, so it can never leave one pending', () {
      var created = 0;
      final d = make(send: (_) async {});
      runZoned(
        () {
          for (var i = 0; i < 30; i++) {
            d.record('segment_recorded');
          }
        },
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, f) {
            created++;
            return parent.createTimer(zone, duration, f);
          },
        ),
      );
      expect(created, 0);
    });
  });

  group('api errors', () {
    test('a failed request records route template, status and code only', () async {
      final h = await harness();
      addTearDown(h.dispose);
      final api = h.services.api;
      api.dio.httpClientAdapter = RoutesAdapter(
        (_) async => jsonResponse({
          'error': {
            'code': 'SESSION_STATE',
            'message': 'Secret message for Asha Rao',
            'request_id': 'r1',
          },
        }, 409),
      );
      await expectLater(
        api.send('GET', '/v1/sessions/$session/attendance', institute: 'inst'),
        throwsA(isA<AppFailure>()),
      );
      final event = h.services.diagnostics.pending.single;
      expect(event, {
        'name': 'api_error',
        'route': '/v1/sessions/{id}/attendance',
        'status': 409,
        'code': 'SESSION_STATE',
      });
      expect(event.toString(), isNot(contains('Asha')));
      expect(event.toString(), isNot(contains(session)));
    });
    test('a dropped connection is recorded by its type, not its message', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.services.api.dio.httpClientAdapter = RoutesAdapter((o) async {
        throw DioException(
          requestOptions: o,
          type: DioExceptionType.connectionTimeout,
          message: 'timed out talking to https://secret.invalid/?token=abc',
        );
      });
      await expectLater(
        h.services.api.send('GET', '/v1/me'),
        throwsA(isA<AppFailure>()),
      );
      expect(h.services.diagnostics.pending.single['code'], 'connectionTimeout');
      expect(h.services.diagnostics.pending.toString(), isNot(contains('secret')));
    });
    test('failures of the diagnostics endpoint itself are never recorded', () async {
      final h = await harness();
      addTearDown(h.dispose);
      h.services.api.dio.httpClientAdapter = RoutesAdapter(
        (_) async => jsonResponse({'error': {'code': 'RATE_LIMITED'}}, 429),
      );
      await expectLater(
        h.services.api.send('POST', '/v1/client-events', body: {}),
        throwsA(isA<AppFailure>()),
      );
      expect(h.services.diagnostics.pending, isEmpty);
    });
  });

  group('error reference', () {
    Future<void> show(WidgetTester tester, Object error) => tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ErrorView(error, retry: () {}))),
    );
    testWidgets('shows the first characters of the server request id', (tester) async {
      await show(
        tester,
        const AppFailure(
          'Could not load.',
          status: 503,
          requestId: '5c1b883a-39a4-4a7b-97f5-4738699c5660',
        ),
      );
      expect(find.textContaining('Reference: 5c1b883a'), findsOneWidget);
      expect(find.textContaining('4738699c5660'), findsNothing); // not the whole id
    });
    testWidgets('shows no reference when the server sent none', (tester) async {
      await show(tester, const AppFailure('Could not load.'));
      expect(find.textContaining('Reference'), findsNothing);
    });
  });
}
