import 'dart:async';

import 'package:flutter/services.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeScanCamera extends GuidedCamera {
  int starts = 0, stops = 0;
  @override
  Future<void> initialize() async {
    ready = true;
  }

  @override
  Future<void> start(List<String> order) async {
    starts++;
    recording = true;
  }

  @override
  Future<void> stop({int minimumSeconds = 10}) async {
    stops++;
    finish('end');
  }

  void finish(String path) {
    recording = false;
    clip = XFile(path);
    emit();
  }

  @override
  Future<void> interrupt() async {
    recording = false;
    ready = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => '/test-private-cache',
      );
  test(
    'bounded scan continues during upload then pauses when two segments wait',
    () async {
      final camera = FakeScanCamera();
      final first = Completer<void>();
      final calls = <String>[];
      final scan = ClassroomScan(camera, (file) async {
        calls.add(file.path);
        if (calls.length == 1) await first.future;
      });
      // Test-owned fake paths are outside the private cache and never deleted.
      addTearDown(scan.dispose);
      await scan.start();
      expect(camera.starts, 1);
      camera.finish('first');
      await Future<void>.delayed(Duration.zero);
      expect(camera.starts, 2);
      camera.finish('second');
      await Future<void>.delayed(Duration.zero);
      expect(scan.pending, 2);
      expect(camera.starts, 2);
      expect(calls, ['first']);
      await scan.stop();
      first.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(scan.pending, 0);
      expect(calls, ['first', 'second']);
      expect(scan.submitted, 2);
      expect(scan.canLeave, true);
    },
  );
  test('failed segment remains queued and retries the same file', () async {
    final camera = FakeScanCamera();
    final calls = <String>[];
    var fail = true;
    final scan = ClassroomScan(camera, (file) async {
      calls.add(file.path);
      if (fail) throw StateError('offline');
    });
    addTearDown(scan.dispose);
    await scan.start();
    camera.finish('retained');
    await Future<void>.delayed(Duration.zero);
    expect(scan.pending, 1);
    expect(scan.error, isNotNull);
    fail = false;
    await scan.retry();
    expect(calls, ['retained', 'retained']);
    expect(scan.pending, 0);
  });
  test(
    'Stop waits for minimum segment duration instead of saving a short clip',
    () async {
      final camera = FakeScanCamera();
      final scan = ClassroomScan(camera, (_) async {});
      addTearDown(scan.dispose);
      await scan.start();
      camera.elapsed = 3;
      await scan.stop();
      expect(camera.stops, 0);
      expect(scan.finishing, true);
    },
  );
}
