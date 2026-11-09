import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:facetrack_core/facetrack_core.dart';

import 'harness.dart';

void main() {
  test(
    'cache expires, is isolated by query and tenant, returns independent data',
    () async {
      final h = await harness();
      addTearDown(h.dispose);
      var now = DateTime(2026);
      var calls = 0;
      final api = ApiClient(
        h.services.client,
        'https://api.invalid',
        clock: () => now,
      );
      api.dio.httpClientAdapter = RoutesAdapter(
        (_) async => jsonResponse({'n': ++calls}),
      );
      final a = await api.send('GET', '/v1/offerings', institute: 'a');
      a['n'] = 99;
      expect((await api.send('GET', '/v1/offerings', institute: 'a'))['n'], 1);
      await api.send('GET', '/v1/offerings', institute: 'b');
      await api.send(
        'GET',
        '/v1/offerings',
        institute: 'a',
        query: {'cursor': 'next'},
      );
      expect(calls, 3);
      now = now.add(const Duration(seconds: 30));
      await api.send('GET', '/v1/offerings', institute: 'a');
      expect(calls, 4);
    },
  );
  test(
    'duplicate reads share work; refresh and writes defeat older responses',
    () async {
      final h = await harness();
      addTearDown(h.dispose);
      final api = h.services.api;
      var calls = 0;
      final gate = Completer<void>();
      final started = Completer<void>();
      api.dio.httpClientAdapter = RoutesAdapter((_) async {
        final n = ++calls;
        if (n == 1) {
          started.complete();
          await gate.future;
        }
        return jsonResponse({'n': n});
      });
      final first = api.send('GET', '/v1/offerings');
      final second = api.send('GET', '/v1/offerings');
      await started.future;
      expect(calls, 1);
      await api.send('POST', '/v1/example', body: {});
      await api.send('GET', '/v1/offerings');
      gate.complete();
      await first;
      await second;
      expect((await api.send('GET', '/v1/offerings'))['n'], 3);
      await ApiClient.freshReads(() => api.send('GET', '/v1/offerings'));
      expect(calls, 4);
      api.clear();
      await api.send('GET', '/v1/offerings');
      expect(calls, 5);
    },
  );
  test('live sensitive reads never reuse completed responses and errors are not cached', () async {
    final h = await harness();
    addTearDown(h.dispose);
    final api = h.services.api;
    var calls = 0;
    api.dio.httpClientAdapter = RoutesAdapter(
      (_) async => jsonResponse({'n': ++calls}),
    );
    for (final path in [
      '/v1/me',
      '/v1/me/biometric-enrollment',
      '/v1/sessions/a',
      '/v1/reports/a/download',
    ]) {
      await api.send('GET', path);
      await api.send('GET', path);
    }
    expect(calls, 8);
    api.dio.httpClientAdapter = RoutesAdapter(
      (_) async => jsonResponse({}, 503),
    );
    await expectLater(
      api.send('GET', '/v1/offerings'),
      throwsA(isA<AppFailure>()),
    );
    api.dio.httpClientAdapter = RoutesAdapter(
      (_) async => jsonResponse({'ok': true}),
    );
    expect((await api.send('GET', '/v1/offerings'))['ok'], true);
  });
  test('forced refresh wins over older requests and equivalent queries coalesce', () async {
    final h = await harness(); addTearDown(h.dispose); final api = h.services.api;
    final started = Completer<void>(), gate = Completer<void>(); var calls = 0;
    api.dio.httpClientAdapter = RoutesAdapter((_) async {
      final n = ++calls;
      if (n == 1) { started.complete(); await gate.future; }
      return jsonResponse({'n':n});
    });
    final old = api.send('GET', '/v1/offerings', query: {'limit':10,'cursor':'a'});
    await started.future;
    await api.send('GET', '/v1/offerings', query: {'cursor':'a','limit':10}, forceRefresh:true);
    gate.complete(); await old;
    expect((await api.send('GET', '/v1/offerings', query: {'limit':10,'cursor':'a'}))['n'],2);
  });
  test('another account never receives a cached result', () async {
    final h = await harness(); addTearDown(h.dispose); final api = h.services.api; var calls=0;
    api.dio.httpClientAdapter=RoutesAdapter((_) async => jsonResponse({'n':++calls}));
    await api.send('GET','/v1/offerings');
    final next = sessionJson(); (next['user'] as Map)['id']='33333333-3333-4333-8333-333333333333';
    await h.services.client.auth.recoverSession(jsonEncode(next));
    expect((await api.send('GET','/v1/offerings'))['n'],2);
  });
  test('cache is bounded to 100 entries', () async {
    final h = await harness();
    addTearDown(h.dispose);
    final api = h.services.api;
    var calls = 0;
    api.dio.httpClientAdapter = RoutesAdapter(
      (_) async => jsonResponse({'n': ++calls}),
    );
    for (var i = 0; i < 101; i++) {
      await api.send('GET', '/v1/offerings', query: {'cursor': '$i'});
    }
    await api.send('GET', '/v1/offerings', query: {'cursor': '0'});
    expect(calls, 102);
  });
}
