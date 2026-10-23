import 'dart:async';

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
  ApiClient(this.auth, String baseUrl)
    : dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          headers: {'Content-Type': 'application/json'},
        ),
      );
  final SupabaseClient auth;
  final Dio dio;
  CancelToken _cancel = CancelToken();
  Future<void>? _refreshing;
  void clear() {
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

  Future<Json> send(
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
          'UPLOAD_EXPIRED' => 'The upload reservation expired. Discard this attempt and record a new video.',
          'MEDIA_MISMATCH' => 'The uploaded video metadata could not be verified. Retry upload; contact support if this persists.',
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
              404 => 'This item or code is unavailable. Check the code or contact your teacher.',
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
    } while (cursor != null);
    return result;
  }

  Future<JoinCode> code(String institute, String id) async => JoinCode.fromJson(
    await send('GET', '/v1/offerings/$id/join-code', institute: institute),
  );
}
