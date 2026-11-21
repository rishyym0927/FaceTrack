import 'dart:convert';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:dio/dio.dart';

/// Signed TUS only. No user token or server Storage secret is sent to this transport.
class ResumableUpload {
  final Dio dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      // A 6 MiB chunk must finish inside this on a slow classroom connection.
      sendTimeout: const Duration(seconds: 120),
      followRedirects: false,
    ),
  );
  bool cancelled = false;
  CancelToken token = CancelToken();

  /// A dropped connection costs one chunk at most: it is retried from the server's own
  /// offset with a short growing delay before the failure reaches the caller.
  static const chunkRetries = 3;
  Future<void> Function(Duration) pause = Future.delayed;
  static bool transient(DioException e) {
    if (e.type == DioExceptionType.cancel) return false;
    final status = e.response?.statusCode;
    return status == null ||
        status >= 500 ||
        status == 408 ||
        status == 429 ||
        e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout;
  }

  void cancel() {
    cancelled = true;
    token.cancel();
  }

  bool valid(Uri resource, Uri endpoint) =>
      resource.scheme == 'https' &&
      resource.origin == endpoint.origin &&
      resource.path.startsWith('/storage/v1/upload/resumable/sign/');
  Future<void> upload(
    XFile file,
    Map<String, dynamic> grant,
    String publicKey, {
    String? resumeUrl,
    required void Function(double) progress,
    required Future<void> Function(String) checkpoint,
  }) async {
    final endpoint = Uri.parse(grant['tus_url'] as String);
    if (endpoint.scheme != 'https' ||
        !endpoint.path.endsWith('/storage/v1/upload/resumable/sign'))
      throw const FormatException('Invalid upload endpoint');
    final headers = <String, dynamic>{
      'Tus-Resumable': '1.0.0',
      'x-signature': grant['token'],
      'apikey': publicKey,
    };
    final length = await file.length();
    String? location = resumeUrl;
    int offset = 0;
    if (location != null) {
      if (!valid(Uri.parse(location), endpoint))
        throw const FormatException('Invalid resume origin');
      final response = await dio.head<dynamic>(
        location,
        options: Options(
          headers: headers,
          validateStatus: (s) => s == 200 || s == 204 || s == 404 || s == 410,
        ),
        cancelToken: token,
      );
      if (response.statusCode == 404 || response.statusCode == 410) {
        location = null;
      } else {
        offset = int.parse(response.headers.value('upload-offset')!);
      }
    }
    if (location == null) {
      String part(String name, String value) =>
          '$name ${base64Encode(utf8.encode(value))}';
      final response = await dio.post<dynamic>(
        endpoint.toString(),
        data: Uint8List(0),
        options: Options(
          headers: {
            ...headers,
            'Upload-Length': '$length',
            'Upload-Metadata': [
              part('bucketName', grant['bucket']),
              part('objectName', grant['object_key']),
              part('contentType', grant['mime_type']),
            ].join(','),
          },
        ),
        cancelToken: token,
      );
      location = endpoint
          .resolve(response.headers.value('location')!)
          .toString();
      if (!valid(Uri.parse(location), endpoint))
        throw const FormatException('Invalid upload location');
      await checkpoint(location);
    }
    if (offset < 0 || offset > length)
      throw const FormatException('Invalid upload offset');
    const chunkSize = 6 * 1024 * 1024;
    var retries = 0;
    while (offset < length && !cancelled) {
      final end = (offset + chunkSize).clamp(0, length);
      final builder = BytesBuilder(copy: false);
      await for (final bytes in file.openRead(offset, end)) {
        builder.add(bytes);
      }
      try {
        final response = await dio.patch<dynamic>(
          location,
          data: builder.takeBytes(),
          options: Options(
            contentType: 'application/offset+octet-stream',
            headers: {...headers, 'Upload-Offset': '$offset'},
          ),
          cancelToken: token,
          onSendProgress: (n, _) => progress((offset + n) / length),
        );
        final next = int.parse(response.headers.value('upload-offset')!);
        if (next <= offset || next > length) {
          throw const FormatException('Invalid uploaded offset');
        }
        offset = next;
        retries = 0;
        progress(offset / length);
      } on DioException catch (e) {
        if (cancelled || !transient(e) || retries >= chunkRetries) rethrow;
        retries++;
        await pause(Duration(milliseconds: 500 * (1 << retries)));
        // The server may have kept part or all of the chunk; ask it where to continue.
        final head = await dio.head<dynamic>(
          location,
          options: Options(headers: headers),
          cancelToken: token,
        );
        final kept = int.tryParse(head.headers.value('upload-offset') ?? '');
        if (kept == null || kept < 0 || kept > length) rethrow;
        offset = kept;
      }
    }
    if (cancelled) throw StateError('Upload cancelled');
  }
}
