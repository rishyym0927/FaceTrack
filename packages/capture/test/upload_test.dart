import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter_test/flutter_test.dart';

class UploadAdapter implements HttpClientAdapter {
  UploadAdapter(this.handler);
  final Future<ResponseBody> Function(RequestOptions, Stream<Uint8List>?)
  handler;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) => handler(options, stream);
  @override
  void close({bool force = false}) {}
}

const endpoint =
    'https://fixture.supabase.invalid/storage/v1/upload/resumable/sign';
const resource = '$endpoint/resource';
Map<String, dynamic> grant() => {
  'tus_url': endpoint,
  'token': 'synthetic-capability',
  'bucket': 'test',
  'object_key': 'opaque/path',
  'mime_type': 'video/webm',
};
void main() {
  test('A dropped chunk is retried from the server offset without surfacing an error', () async {
    final upload = ResumableUpload()..pause = (_) async {};
    var patches = 0;
    final delays = <int>[];
    upload.pause = (d) async => delays.add(d.inMilliseconds);
    upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
      if (r.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'upload-offset': ['0']});
      }
      patches++;
      if (patches <= 2) {
        throw DioException(requestOptions: r, type: DioExceptionType.connectionError);
      }
      return ResponseBody.fromString('', 204, headers: {'upload-offset': ['10']});
    });
    await upload.upload(
      XFile.fromData(Uint8List.fromList(List.generate(10, (n) => n))),
      grant(),
      'public-fixture',
      resumeUrl: resource,
      progress: (_) {},
      checkpoint: (_) async {},
    );
    expect(patches, 3);
    expect(delays, [1000, 2000]); // growing delay between attempts
  });
  test('A permanent rejection is not retried', () async {
    final upload = ResumableUpload()..pause = (_) async {};
    var patches = 0;
    upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
      if (r.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'upload-offset': ['0']});
      }
      patches++;
      return ResponseBody.fromString('', 403);
    });
    await expectLater(
      upload.upload(
        XFile.fromData(Uint8List.fromList(List.generate(10, (n) => n))),
        grant(),
        'public-fixture',
        resumeUrl: resource,
        progress: (_) {},
        checkpoint: (_) async {},
      ),
      throwsA(isA<DioException>()),
    );
    expect(patches, 1);
  });
  test('Interrupted upload resumes from server offset with capability-only headers', () async {
    final upload = ResumableUpload();
    var patched = false;
    upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
      expect(r.headers.containsKey('Authorization'), isFalse);
      expect(r.headers['x-signature'], 'synthetic-capability');
      if (r.method == 'HEAD')
        return ResponseBody.fromString(
          '',
          200,
          headers: {
            'upload-offset': ['4'],
          },
        );
      expect(r.method, 'PATCH');
      expect(r.headers['Upload-Offset'], '4');
      final bytes = <int>[];
      await for (final chunk in stream!) {
        bytes.addAll(chunk);
      }
      expect(bytes, [4, 5, 6, 7, 8, 9]);
      patched = true;
      return ResponseBody.fromString(
        '',
        204,
        headers: {
          'upload-offset': ['10'],
        },
      );
    });
    await upload.upload(
      XFile.fromData(Uint8List.fromList(List.generate(10, (n) => n))),
      grant(),
      'public-fixture',
      resumeUrl: resource,
      progress: (_) {},
      checkpoint: (_) async {},
    );
    expect(patched, isTrue);
  });
  test(
    'Cached resume URL cannot exfiltrate a signed capability to another host',
    () async {
      final upload = ResumableUpload();
      var calls = 0;
      upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
        calls++;
        return ResponseBody.fromString('', 200);
      });
      await expectLater(
        upload.upload(
          XFile.fromData(Uint8List(10)),
          grant(),
          'public-fixture',
          resumeUrl:
              'https://other.invalid/storage/v1/upload/resumable/sign/id',
          progress: (_) {},
          checkpoint: (_) async {},
        ),
        throwsFormatException,
      );
      expect(calls, 0);
    },
  );
  test('Fresh upload persists its resume URL before sending bytes', () async {
    final upload = ResumableUpload();
    String? saved;
    upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
      if (r.method == 'POST')
        return ResponseBody.fromString(
          '',
          201,
          headers: {
            'location': [resource],
          },
        );
      expect(saved, resource);
      return ResponseBody.fromString(
        '',
        204,
        headers: {
          'upload-offset': ['10'],
        },
      );
    });
    await upload.upload(
      XFile.fromData(Uint8List(10)),
      grant(),
      'public-fixture',
      progress: (_) {},
      checkpoint: (value) async {
        saved = value;
      },
    );
    expect(saved, resource);
  });

  test('A 409 or 423 means the server is elsewhere: ask where, then continue', () async {
    for (final status in [409, 423]) {
      final upload = ResumableUpload()..pause = (_) async {};
      var patches = 0, heads = 0;
      upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
        if (r.method == 'HEAD') {
          heads++;
          return ResponseBody.fromString('', 200, headers: {'upload-offset': ['4']});
        }
        patches++;
        if (patches == 1) return ResponseBody.fromString('', status);
        expect(r.headers['Upload-Offset'], '4', reason: 'resumed from the server offset');
        return ResponseBody.fromString('', 204, headers: {'upload-offset': ['10']});
      });
      await upload.upload(
        XFile.fromData(Uint8List(10)),
        grant(),
        'public-fixture',
        resumeUrl: resource,
        progress: (_) {},
        checkpoint: (_) async {},
      );
      expect(patches, 2, reason: 'status $status');
      expect(heads, 2, reason: 'one resume check, one resync');
    }
  });

  test('A reply without an offset is a format error, not a flaky network', () async {
    for (final onPatch in [false, true]) {
      final upload = ResumableUpload()..pause = (_) async {};
      upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
        if (r.method == 'HEAD') {
          return ResponseBody.fromString('', 200, headers: onPatch ? {'upload-offset': ['0']} : {});
        }
        return ResponseBody.fromString('', 204);
      });
      await expectLater(
        upload.upload(
          XFile.fromData(Uint8List(10)),
          grant(),
          'public-fixture',
          resumeUrl: resource,
          progress: (_) {},
          checkpoint: (_) async {},
        ),
        throwsFormatException,
      );
    }
  });

  test('Progress in the lost chunk renews the retry budget', () async {
    final upload = ResumableUpload()..pause = (_) async {};
    var patches = 0, kept = 0;
    upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
      if (r.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'upload-offset': ['$kept']});
      }
      patches++;
      if (kept < 6) {
        kept++; // the server stored a little more each time, but the reply was lost
        throw DioException(requestOptions: r, type: DioExceptionType.receiveTimeout);
      }
      return ResponseBody.fromString('', 204, headers: {'upload-offset': ['10']});
    });
    await upload.upload(
      XFile.fromData(Uint8List(10)),
      grant(),
      'public-fixture',
      resumeUrl: resource,
      progress: (_) {},
      checkpoint: (_) async {},
    );
    expect(patches, 7); // more than chunkRetries (3) failures, because each one made headway
  });

  test('Progress is reported by whole percents, not once per KiB written', () async {
    const size = 7 * 1024 * 1024; // two chunks
    final upload = ResumableUpload();
    var raw = 0;
    var offset = 0;
    upload.dio.httpClientAdapter = UploadAdapter((r, stream) async {
      if (r.method == 'HEAD') {
        return ResponseBody.fromString('', 200, headers: {'upload-offset': ['0']});
      }
      await for (final chunk in stream!) {
        offset += chunk.length;
      }
      return ResponseBody.fromString('', 204, headers: {'upload-offset': ['$offset']});
    });
    upload.dio.interceptors.add(
      InterceptorsWrapper(onRequest: (o, h) {
        final inner = o.onSendProgress;
        o.onSendProgress = (n, t) {
          raw++;
          inner?.call(n, t);
        };
        h.next(o);
      }),
    );
    final seen = <double>[];
    await upload.upload(
      XFile.fromData(Uint8List(size)),
      grant(),
      'public-fixture',
      resumeUrl: resource,
      progress: seen.add,
      checkpoint: (_) async {},
    );
    // ignore: avoid_print
    print('dio send-progress events: $raw, reported to the caller: ${seen.length}');
    expect(raw, greaterThan(1000)); // the transport really is that chatty
    expect(seen.length, lessThan(130));
    expect(seen.last, 1.0);
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
    }
  });
}
