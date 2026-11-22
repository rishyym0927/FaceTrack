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
    test('clear() during a send leaves the next account\'s events untouched', () async {
      final gate = Completer<void>();
      final d = make(send: (_) => gate.future);
      d.record('segment_recorded', count: 1);
      final flushing = d.flush();
      d.clear(); // sign-out while the batch is out
      d.record('segment_recorded', count: 2); // the next account's first event
      d.record('segment_recorded', count: 3);
      gate.complete();
      await flushing;
      expect([for (final e in d.pending) e['count']], [2, 3]);
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

  group('timing, context and flood control', () {
    late DateTime now;
    setUp(() => now = DateTime(2026, 1, 1, 10));
    Diagnostics make({
      required Future<void> Function(Map<String, dynamic>) send,
      Map<String, Object> Function()? network,
      String? deviceClass = 'phone',
    }) {
      final d = Diagnostics(
        app: 'student',
        platform: 'android',
        version: 'abc1234',
        send: send,
        clock: () => now,
        deviceClass: deviceClass,
        networkContext: network ?? () => const {'network': 'cellular', 'net_class': '3g'},
      );
      addTearDown(d.dispose);
      return d;
    }

    Future<void> settle() => Future<void>.delayed(Duration.zero);

    test('every event says how long ago it happened, so the timeline is real', () async {
      final sent = <Map<String, dynamic>>[];
      final d = make(send: (b) async => sent.add(b));
      d.record('scan_started'); // goes out at once (first flush)
      await settle();
      now = now.add(const Duration(seconds: 3));
      d.record('segment_recorded', count: 1);
      now = now.add(const Duration(seconds: 4));
      d.record('upload_done', count: 1);
      now = now.add(const Duration(seconds: 5)); // flushAfter (10 s) has not passed
      expect(sent.length, 1);
      d.record('app_error'); // urgent: flushes the three that waited
      await settle();
      final events = sent.last['events'] as List;
      expect([for (final e in events) e['age_ms']], [9000, 5000, 0]);
      expect(sent.first['events'].single['age_ms'], 0);
    });

    test('a batch carries a device class and coarse connection details only', () async {
      final sent = <Map<String, dynamic>>[];
      final d = make(
        send: (b) async => sent.add(b),
        network: () => {
          'network': 'wifi',
          'net_class': '4g',
          'downlink_mbps': 7.5,
          'rtt_ms': 80,
          'ssid': 'Hostel-WiFi-5G', // never forwarded, whatever the platform layer returns
          'ip': '10.0.0.7',
        },
      );
      d.record('scan_started');
      await settle();
      final batch = sent.single;
      expect(batch['device_class'], 'phone');
      expect(batch['network'], 'wifi');
      expect(batch['net_class'], '4g');
      expect(batch['downlink_mbps'], 7.5);
      expect(batch['rtt_ms'], 80);
      expect(batch.containsKey('ssid'), isFalse);
      expect(batch.containsKey('ip'), isFalse);
      expect(batch.toString().contains('Hostel'), isFalse);
    });

    test('a failing network probe never costs the batch', () async {
      final sent = <Map<String, dynamic>>[];
      final d = make(send: (b) async => sent.add(b), network: () => throw StateError('nope'));
      d.record('scan_started');
      await settle();
      expect(sent.single['events'], hasLength(1));
      expect(sent.single.containsKey('network'), isFalse);
    });

    test('device classes come from the screen, never from a model name', () {
      expect(Diagnostics.deviceClassFor('android', 360, 800), 'phone');
      expect(Diagnostics.deviceClassFor('android', 800, 1280), 'tablet');
      expect(Diagnostics.deviceClassFor('web', 800, 1600), 'desktop');
      expect(Diagnostics.deviceClassFor('web', 390, 844), 'phone');
      expect(Diagnostics.deviceClassFor('web', 700, 900), 'tablet');
      expect(Diagnostics.deviceClassFor('web', 0, 0), 'unknown');
    });

    test('names the server does not know are dropped here, not sent', () {
      final d = make(send: (_) async {});
      d.record('login_form_submitted');
      d.record('camera_recovered', code: 'switched');
      d.record('scan_paused', code: 'hidden');
      d.record('scan_resumed', seconds: 4.2);
      d.record('recognition_load_failed', route: '/v1/sessions/$session/attendance', status: 503);
      expect([for (final e in d.pending) e['name']], [
        'camera_recovered',
        'scan_paused',
        'scan_resumed',
        'recognition_load_failed',
      ]);
    });

    test('a repeating api error becomes one event with a count', () {
      final d = make(send: (_) async => throw StateError('offline'));
      for (var i = 0; i < 40; i++) {
        d.record('api_error', route: '/v1/sessions/$session/attendance', status: 503);
        now = now.add(const Duration(milliseconds: 500));
      }
      d.record('api_error', route: '/v1/me', status: 502);
      final events = d.pending;
      // 20 s of a polling outage: the first 40 are one event (inside 30 s), /v1/me is another.
      expect(events.length, 2);
      expect(events.first['count'], 40);
      expect(events.last['route'], '/v1/me');
    });

    test('an error that keeps happening is reported again after the window', () {
      final d = make(send: (_) async => throw StateError('offline'));
      d.record('api_error', route: '/v1/me', status: 502);
      now = now.add(const Duration(seconds: 31));
      d.record('api_error', route: '/v1/me', status: 502);
      expect(d.pending.length, 2);
      expect(d.pending.first.containsKey('count'), isFalse);
    });

    test('different statuses and codes are not merged', () {
      final d = make(send: (_) async => throw StateError('offline'));
      d.record('api_error', route: '/v1/me', status: 502);
      d.record('api_error', route: '/v1/me', status: 503);
      d.record('api_error', route: '/v1/me', status: 503, code: 'X');
      expect(d.pending.length, 3);
    });

    test('no personal field can be added: only whitelisted keys ever appear', () async {
      final sent = <Map<String, dynamic>>[];
      final d = make(send: (b) async => sent.add(b));
      d.record(
        'camera_failed',
        sessionId: 'Asha Rao asha@example.test',
        code: '<script>@x',
        route: '/v1/me?token=secret&email=asha@example.test',
      );
      await settle();
      final text = sent.single.toString();
      for (final secret in ['Asha', 'asha@', 'token', 'secret', '<', '@']) {
        expect(text.contains(secret), isFalse, reason: secret);
      }
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
