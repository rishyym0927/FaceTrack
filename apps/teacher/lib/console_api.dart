import 'dart:typed_data';

import 'package:dio/dio.dart';

/// Talks to the local FaceTrack Test Console service (`python -m facetrack_worker.console`).
class ConsoleException implements Exception {
  ConsoleException(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class ConsoleBackend {
  Future<Map<String, dynamic>> status();
  Future<List<Map<String, dynamic>>> scenarios();
  Future<Map<String, dynamic>> summary();
  Future<Map<String, dynamic>> exportData();
  Future<Map<String, dynamic>> enrol({
    required String label,
    required Uint8List video,
    required String extension,
  });
  Future<void> removePerson(String id);
  Future<Map<String, dynamic>> run({
    required String scenario,
    required List<String> present,
    required bool stranger,
    required Uint8List video,
    required String extension,
  });
  Future<void> wipe();
}

class HttpConsoleBackend implements ConsoleBackend {
  HttpConsoleBackend({String? base, Dio? client})
    : _dio =
          client ??
          Dio(
            BaseOptions(
              baseUrl: base ?? _defaultBase(),
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(minutes: 3),
              receiveTimeout: const Duration(minutes: 8),
              headers: const {'X-FaceTrack-Console': '1'},
              validateStatus: (_) => true,
            ),
          );

  final Dio _dio;

  static String _defaultBase() {
    const configured = String.fromEnvironment('CONSOLE_API');
    return configured.isNotEmpty ? configured : Uri.base.origin;
  }

  Map<String, dynamic> _body(Response<dynamic> response) {
    final data = response.data;
    final status = response.statusCode ?? 0;
    if (status >= 200 && status < 300 && data is Map<String, dynamic>) {
      return data;
    }
    if (data is Map && data['error'] is Map) {
      throw ConsoleException('${(data['error'] as Map)['message']}');
    }
    throw ConsoleException('The test service did not respond correctly (code $status).');
  }

  Future<Map<String, dynamic>> _call(Future<Response<dynamic>> Function() send) async {
    try {
      return _body(await send());
    } on DioException {
      throw ConsoleException(
        'Cannot reach the test service. Make sure it is running, then reload this page.',
      );
    }
  }

  @override
  Future<Map<String, dynamic>> status() => _call(() => _dio.get('/api/status'));

  @override
  Future<List<Map<String, dynamic>>> scenarios() async {
    final data = await _call(() => _dio.get('/api/scenarios'));
    return [for (final item in data['scenarios'] as List) Map<String, dynamic>.from(item as Map)];
  }

  @override
  Future<Map<String, dynamic>> summary() => _call(() => _dio.get('/api/summary'));

  @override
  Future<Map<String, dynamic>> exportData() => _call(() => _dio.get('/api/export'));

  Options _video(String extension) => Options(contentType: 'video/$extension');

  @override
  Future<Map<String, dynamic>> enrol({
    required String label,
    required Uint8List video,
    required String extension,
  }) => _call(
    () => _dio.post(
      '/api/people/enrol',
      queryParameters: {'label': label, 'consent': '1', 'supervised': '1'},
      data: video,
      options: _video(extension),
    ),
  );

  @override
  Future<void> removePerson(String id) async {
    await _call(() => _dio.delete('/api/people/$id'));
  }

  @override
  Future<Map<String, dynamic>> run({
    required String scenario,
    required List<String> present,
    required bool stranger,
    required Uint8List video,
    required String extension,
  }) => _call(
    () => _dio.post(
      '/api/runs',
      queryParameters: {
        'scenario': scenario,
        'present': present.join(','),
        'stranger': stranger ? '1' : '0',
      },
      data: video,
      options: _video(extension),
    ),
  );

  @override
  Future<void> wipe() async {
    await _call(() => _dio.post('/api/wipe', queryParameters: {'confirm': 'DELETE'}));
  }
}
