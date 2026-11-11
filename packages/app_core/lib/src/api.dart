import 'dart:async';
import 'dart:convert';
import 'dart:collection';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:facetrack_models/facetrack_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class AppFailure implements Exception {
  const AppFailure(this.message, {this.status, this.code, this.requestId});
  final String message;
  final int? status;
  final String? code, requestId;
  @override
  String toString() => message;
}

class Mutation {
  String key = const Uuid().v4();
  Object? payload;
  String forBody(Object value) {
    if (payload != null && payload.toString() != value.toString())
      key = const Uuid().v4();
    payload = value;
    return key;
  }

  void reset() {
    key = const Uuid().v4();
    payload = null;
  }
}

class ApiClient {
  ApiClient(this.auth, String baseUrl, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          headers: {'Content-Type': 'application/json'},
        ),
      );
  final DateTime Function() _clock;
  final SupabaseClient auth;
  final Dio dio;
  final _reads = LinkedHashMap<String, ({DateTime at, Json data})>();
  final _pending = <String, Future<Json>>{};
  int _readEpoch = 0;
  static final _freshZone = Object();
  static Future<T> freshReads<T>(Future<T> Function() action) =>
      runZoned(action, zoneValues: {_freshZone: true});
  void invalidateReads() {
    _readEpoch++;
    _reads.clear();
    _pending.clear();
  }

  bool _cacheable(String path) =>
      path == '/v1/offerings' ||
      path == '/v1/me/enrollments' ||
      RegExp(r'^/v1/academics/(courses|terms|class-groups)$').hasMatch(path) ||
      RegExp(r'^/v1/offerings/[^/]+/attendance-summary$').hasMatch(path);
  String _readKey(String actor, String? institute, String path, Json? query) {
    Object? canonical(Object? value) {
      if (value is Map) {
        final keys = value.keys.map((k) => k.toString()).toList()..sort();
        return {for (final k in keys) k: canonical(value[k])};
      }
      if (value is List) return value.map(canonical).toList();
      return value;
    }

    return jsonEncode([actor, institute, path, canonical(query ?? {})]);
  }

  Json _copy(Json data) => jsonDecode(jsonEncode(data)) as Json;
  Future<Json> send(
    String method,
    String path, {
    String? institute,
    Json? body,
    Json? query,
    Mutation? mutation,
    int? version,
    bool forceRefresh = false,
  }) async {
    final actor = auth.auth.currentUser?.id;
    if (actor == null)
      throw const AppFailure('Please sign in again.', status: 401);
    Future<Json> request() => _sendNetwork(
      method,
      path,
      institute: institute,
      body: body,
      query: query,
      mutation: mutation,
      version: version,
    );
    if (method != 'GET') {
      invalidateReads();
      try {
        return await request();
      } finally {
        invalidateReads();
      }
    }
    final cacheable = _cacheable(path);
    final share =
        cacheable ||
        RegExp(
          r'^/v1/offerings/[^/]+/(roster|biometric-enrollments|attendance-disputes)$',
        ).hasMatch(path) ||
        path == '/v1/sessions';
    if (!share) return request();
    final fresh = forceRefresh || Zone.current[_freshZone] == true;
    final key = _readKey(actor, institute, path, query);
    if (!fresh && !(auth.auth.currentSession?.isExpired ?? true)) {
      final entry = _reads[key];
      if (entry != null &&
          _clock().difference(entry.at) < const Duration(seconds: 30)) {
        return _copy(entry.data);
      }
      final pending = _pending[key];
      if (pending != null) return _copy(await pending);
    }
    _reads.remove(key);
    final epoch = _readEpoch;
    late final Future<Json> future;
    future = request()
        .then((data) {
          if (cacheable &&
              epoch == _readEpoch &&
              auth.auth.currentUser?.id == actor &&
              identical(_pending[key], future)) {
            _reads[key] = (at: _clock(), data: _copy(data));
            while (_reads.length > 100) {
              _reads.remove(_reads.keys.first);
            }
          }
          return data;
        })
        .whenComplete(() {
          if (identical(_pending[key], future)) _pending.remove(key);
        });
    _pending[key] = future;
    return _copy(await future);
  }

  CancelToken _cancel = CancelToken();
  Future<void>? _refreshing;
  void clear() {
    invalidateReads();
    _cancel.cancel('Account changed');
    _cancel = CancelToken();
  }

  void Function()? onSessionLost;
  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    try {
      await auth.auth.refreshSession();
    } on AuthRetryableFetchException {
      throw const AppFailure(
        'Could not refresh your session. Check your connection and retry.',
        status: 503,
      );
    } on AuthException {
      onSessionLost?.call();
      throw const AppFailure(
        'Your session expired. Please sign in again.',
        status: 401,
      );
    } catch (_) {
      throw const AppFailure(
        'Could not refresh your session. Please retry.',
        status: 503,
      );
    }
  }

  Future<Json> _sendNetwork(
    String method,
    String path, {
    String? institute,
    Json? body,
    Json? query,
    Mutation? mutation,
    int? version,
  }) async {
    final actor = auth.auth.currentUser?.id;
    if (actor == null)
      throw const AppFailure('Please sign in again.', status: 401);
    final headers = <String, dynamic>{
      if (institute != null) 'X-Institute-ID': institute,
      if (mutation != null)
        'Idempotency-Key': mutation.forBody({'body': body, 'version': version}),
      if (version != null) 'If-Match': '$version',
    };
    final cancel = _cancel;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final session = auth.auth.currentSession;
        if (session == null)
          throw const AppFailure('Please sign in again.', status: 401);
        if (session.isExpired) await refresh();
        if (auth.auth.currentUser?.id != actor)
          throw const AppFailure('Your account changed. Please retry.');
        headers['Authorization'] =
            'Bearer ' + auth.auth.currentSession!.accessToken;
        final response = await dio.request<Json>(
          path,
          data: body,
          queryParameters: query,
          options: Options(method: method, headers: headers),
          cancelToken: cancel,
        );
        if (auth.auth.currentUser?.id != actor || cancel.isCancelled)
          throw const AppFailure('Your account changed. Please retry.');
        return response.data!;
      } on DioException catch (e) {
        if (e.response?.statusCode == 401 && attempt == 0) {
          try {
            await refresh();
            continue;
          } on AppFailure {
            rethrow;
          } catch (_) {
            onSessionLost?.call();
            throw const AppFailure(
              'Your session expired. Please sign in again.',
              status: 401,
            );
          }
        }
        if (e.response?.statusCode == 401) onSessionLost?.call();
        final host = Uri.parse(dio.options.baseUrl).host;
        if (!kIsWeb &&
            !kReleaseMode &&
            ['localhost', '127.0.0.1'].contains(host) &&
            e.response == null &&
            e.type != DioExceptionType.cancel) {
          throw const AppFailure(
            'Could not reach the development server on your Mac. Keep USB connected, '
            'restore the development connection on your Mac, then tap Retry.',
            code: 'development_api_unreachable',
          );
        }
        final raw = e.response?.data;
        final error = raw is Map ? raw['error'] : null;
        final status = e.response?.statusCode;
        final code = error is Map ? error['code'] as String? : null;
        final biometricMessage = switch (code) {
          'ENROLLMENT_NOT_READY' => 'Face enrolment is unavailable for this institute. Ask your project administrator to check the processing setup.',
          'INSUFFICIENT_TEMPLATES' => 'This session needs two students with approved face enrolments before it can accept recordings. Use manual review, or open a new session after both enrolments are approved.',
          'SESSION_STATE' => 'This session is no longer accepting recordings. Return to the session and check its status.',
          'CAPTURE_TIME' => 'The recording was made outside this session’s capture window. Check the session time and your device clock.',
          'MODEL_UNAVAILABLE' => 'Classroom recognition has not been configured. Ask your project administrator to check the processing setup.',
          'UPLOAD_EXPIRED' => 'The upload reservation expired. Discard this attempt and record a new video.',
          'MEDIA_MISMATCH' =>
            'The server could not verify this video. Record a new clip.',
          'MEDIA_CHANGED' => 'This attempt is reserved for a different recording. Discard it before recording again.',
          'MEDIA_NOT_AVAILABLE' =>
            'The video has not finished uploading. Retry upload to resume.',
          _ => null,
        };
        final text =
            biometricMessage ??
            switch (status) {
              401 => 'Your session expired. Please sign in again.',
              403 =>
                'Your account does not have access. Contact your institute.',
              404 => 'This item or code is unavailable. Check the code or contact your faculty.',
              409 => 'This record changed or already exists. Refresh and confirm your action again.',
              422 => 'Check the entered information and try again.',
              429 => 'Too many attempts. Please try again later.',
              503 => 'The service is temporarily unavailable. Please retry.',
              _ => 'Could not connect. Check your connection and retry.',
            };
        throw AppFailure(
          text,
          status: status,
          code: code,
          requestId: error is Map ? error['request_id'] as String? : null,
        );
      } on AuthException {
        throw const AppFailure(
          'Your session expired. Please sign in again.',
          status: 401,
        );
      }
    }
    throw const AppFailure('Please sign in again.', status: 401);
  }

  Future<Account> me() async => Account.fromJson(await send('GET', '/v1/me'));
  Future<PageData<Offering>> offerings(
    String institute, {
    String? cursor,
  }) async => PageData.fromJson(
    await send(
      'GET',
      '/v1/offerings',
      institute: institute,
      query: {if (cursor != null) 'cursor': cursor},
    ),
    Offering.fromJson,
  );
  Future<Offering> offering(String institute, String id) async =>
      Offering.fromJson(
        await send('GET', '/v1/offerings/$id', institute: institute),
      );
  Future<PageData<Enrollment>> enrollments(
    String institute, {
    String? cursor,
  }) async => PageData.fromJson(
    await send(
      'GET',
      '/v1/me/enrollments',
      institute: institute,
      query: {if (cursor != null) 'cursor': cursor},
    ),
    Enrollment.fromJson,
  );
  Future<PageData<Enrollment>> roster(
    String institute,
    String id,
    String status, {
    String? cursor,
  }) async => PageData.fromJson(
    await send(
      'GET',
      '/v1/offerings/$id/roster',
      institute: institute,
      query: {'status': status, if (cursor != null) 'cursor': cursor},
    ),
    Enrollment.fromJson,
  );
  Future<List<Academic>> academics(String institute, String kind) async {
    final result = <Academic>[];
    String? cursor;
    var pages = 0;
    do {
      final data = PageData.fromJson(
        await send(
          'GET',
          '/v1/academics/$kind',
          institute: institute,
          query: {'limit': 200, if (cursor != null) 'cursor': cursor},
        ),
        Academic.fromJson,
      );
      result.addAll(data.items);
      cursor = data.nextCursor;
    } while (cursor != null && ++pages < 25);
    return result;
  }

  Future<JoinCode> code(String institute, String id) async => JoinCode.fromJson(
    await send('GET', '/v1/offerings/$id/join-code', institute: institute),
  );
}
