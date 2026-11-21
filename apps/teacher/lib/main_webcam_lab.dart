// Development harness for the classroom scan screen with a real or fake browser camera.
// It needs no sign-in or server: segments are "uploaded" to a delay. Run it with
//   ../../scripts/flutter run -d chrome -t lib/main_webcam_lab.dart
// (Chrome flags --use-fake-device-for-media-stream --use-fake-ui-for-media-stream give fake cameras.)
import 'dart:async';

import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter/material.dart';

import 'classroom_scan.dart';
import 'recognition_board.dart';

void main() {
  final scan = ClassroomScan(
    GuidedCamera(),
    (file) async {
      final bytes = await file.length();
      debugPrint('LAB segment ${file.path.split('/').last} bytes=$bytes');
      await Future<void>.delayed(const Duration(seconds: 2));
    },
    onEvent: (name, {code, attempt, bytes, count, durationMs}) =>
        debugPrint('LAB event $name code=$code bytes=$bytes count=$count'),
  );
  runApp(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: const Color(0xff0f766e), useMaterial3: true),
      home: ClassroomScanPage(
        scan: scan,
        results: () async => const RecognitionSnapshot([]),
        reference: 'lab',
      ),
    ),
  );
}
