/// Explicitly synthetic Auth and API transport. Never used by application entrypoints.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide Headers;
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

const actor = '11111111-1111-4111-8111-111111111111';
const institute = '22222222-2222-4222-8222-222222222222';
Json sessionJson() {
  final exp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  String part(Object x) =>
      base64Url.encode(utf8.encode(jsonEncode(x))).replaceAll('=', '');
  final token =
      part({'alg': 'test-only'}) +
      '.' +
      part({'exp': exp, 'sub': actor}) +
      '.fixture';
  return {
    'access_token': token,
    'refresh_token': 'synthetic-refresh',
    'token_type': 'bearer',
    'expires_in': 3600,
    'user': {
      'id': actor,
      'email': 'fixture@example.test',
      'aud': 'authenticated',
      'app_metadata': {},
      'user_metadata': {},
      'created_at': '2026-10-23T00:00:00Z',
    },
  };
}

Json accountJson(String? role) => {
  'user_id': actor,
  'memberships': role == null
      ? []
      : [
          {
            'id': 'm',
            'institute_id': institute,
            'institute_name': 'Test Institute',
            'role': role,
            'status': 'active',
          },
        ],
  'students': role == 'student'
      ? [
          {
            'id': 'student',
            'institute_id': institute,
            'official_name': 'Synthetic Student',
            'enrollment_number': '0001',
            'status': 'approved',
          },
        ]
      : [],
  'teachers': role == 'teacher'
      ? [
          {
            'id': 'teacher',
            'institute_id': institute,
            'official_name': 'Synthetic Teacher',
            'employee_number': 'T01',
            'status': 'approved',
          },
        ]
      : [],
};

class RoutesAdapter implements HttpClientAdapter {
  RoutesAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions) handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handler(options);
  @override
  void close({bool force = false}) {}
}

ResponseBody jsonResponse(Object data, [int status = 200]) =>
    ResponseBody.fromString(
      jsonEncode(data),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

class Harness {
  Harness(this.services, this.account);
  final AppServices services;
  Json account;
  Future<void> dispose() => services.client.dispose();
}

Future<Harness> harness({
  AppRole role = AppRole.student,
  String? profileRole = 'student',
  bool signedIn = true,
}) async {
  final client = SupabaseClient(
    'https://fixture.supabase.invalid',
    'sb_publishable_synthetic_fixture',
    authOptions: const AuthClientOptions(autoRefreshToken: false),
    httpClient: MockClient(
      (r) async => http.Response(
        jsonEncode(r.url.path.endsWith('/logout') ? {} : sessionJson()),
        200,
        headers: {'content-type': 'application/json'},
      ),
    ),
  );
  if (signedIn) await client.auth.recoverSession(jsonEncode(sessionJson()));
  final services = AppServices(
    AppConfig(
      role: role,
      apiUrl: 'https://api.invalid',
      supabaseUrl: 'https://fixture.supabase.invalid',
      publishableKey: 'sb_publishable_synthetic_fixture',
      defaultInstituteId: institute,
    ),
    client,
    const EmptyLocalStorage(),
  );
  final h = Harness(services, accountJson(profileRole));
  services.api.dio.httpClientAdapter = RoutesAdapter(
    (r) async => jsonResponse(
      r.path == '/v1/me' ? h.account : {'items': [], 'next_cursor': null},
    ),
  );
  return h;
}
