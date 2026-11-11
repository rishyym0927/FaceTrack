import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeScanCamera extends GuidedCamera {
  int starts = 0, stops = 0;
  bool available = true;
  @override
  Future<void> initialize() async {
    ready = available;
  }

  @override
  Future<void> start(List<String> order) async {
    starts++;
    recording = true;
  }

  @override
  Future<void> stop({int minimumSeconds = 10}) async {
    stops++;
    if (elapsed >= minimumSeconds) {
      finish('end');
    } else {
      recording = false;
      emit();
    }
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
  var cache = '/test-private-cache';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => cache,
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
      expect(camera.ready, false);
      expect(scan.sending, true);
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
  test('camera failure can restart without an upload retry', () async {
    final camera = FakeScanCamera()..available = false;
    final scan = ClassroomScan(camera, (_) async {});
    addTearDown(scan.dispose);
    await scan.start();
    expect(scan.cameraError, isNotNull);
    expect(scan.error, isNull);
    expect(scan.pending, 0);

    camera.available = true;
    await scan.start();
    expect(scan.cameraError, isNull);
    expect(camera.starts, 1);
  });

  test('expired upload keeps the segment until explicit discard', () async {
    final camera = FakeScanCamera();
    var attempts = 0;
    final scan = ClassroomScan(camera, (_) async {
      attempts++;
      throw const AppFailure('Reservation expired.', code: 'UPLOAD_EXPIRED');
    });
    addTearDown(scan.dispose);
    await scan.start();
    camera.finish('retained');
    await Future<void>.delayed(Duration.zero);
    expect(scan.error, 'Reservation expired.');
    expect(scan.retryable, false);
    expect(scan.pending, 1);
    await scan.retry();
    expect(attempts, 1);
    await scan.discardPending();
    expect(scan.pending, 0);
  });

  test('Disposal releases a clip while its upload is still pending', () async {
    final folder = await Directory.systemTemp.createTemp('scan-test-');
    cache = folder.path;
    addTearDown(() async {
      cache = '/test-private-cache';
      await folder.delete(recursive: true);
    });
    final clip = await File('${folder.path}/pending.mp4').writeAsString('clip');
    final upload = Completer<void>();
    final camera = FakeScanCamera();
    final scan = ClassroomScan(camera, (_) => upload.future);
    await scan.start();
    camera.finish(clip.path);
    await Future<void>.delayed(Duration.zero);
    expect(scan.pending, 1);
    scan.dispose();
    for (var i = 0; i < 50 && await clip.exists(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await clip.exists(), false);
    upload.complete();
    await Future<void>.delayed(Duration.zero);
    expect(scan.submitted, 0);
  });

  test('Stop closes the camera immediately and drops a short tail', () async {
    final camera = FakeScanCamera();
    final scan = ClassroomScan(camera, (_) async {});
    addTearDown(scan.dispose);
    await scan.start();
    camera.elapsed = 3;
    await scan.stop();
    expect(camera.stops, 1);
    expect(camera.ready, false);
    expect(scan.pending, 0);
    expect(scan.canLeave, true);
  });
}
