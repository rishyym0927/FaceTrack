// Opt-in synthetic transport probe. Grant file stays private and is deleted by the operator.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Explicit live synthetic transport probe', () async {
    HttpOverrides.global = null;
    final config = jsonDecode(
      await File(Platform.environment['FACETRACK_PROBE_FILE']!).readAsString(),
    );
    final upload = ResumableUpload();
    upload.dio.interceptors.add(
      InterceptorsWrapper(
        onResponse: (r, h) {
          print('${r.requestOptions.method}: HTTP ${r.statusCode}');
          h.next(r);
        },
      ),
    );
    try {
      await upload.upload(
        XFile.fromData(Uint8List(50)),
        Map<String, dynamic>.from(config['grant']),
        config['key'],
        progress: (_) {},
        checkpoint: (_) async {},
      );
      print('Synthetic Dart transport passed.');
    } on DioException catch (e) {
      print('Transport failed: ${e.type.name}, HTTP ${e.response?.statusCode}');
      fail('Synthetic transport failed; see sanitized status.');
    } catch (e) {
      print('Transport failed: ${e.runtimeType}');
      fail('Synthetic transport failed; see sanitized status.');
    }
  });
}
