import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart' show CameraDescription, CameraLensDirection;
import 'package:flutter/services.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_teacher/classroom_scan.dart';
import 'package:flutter_test/flutter_test.dart';

const frontCamera = CameraDescription(
  name: 'front',
  lensDirection: CameraLensDirection.front,
  sensorOrientation: 270,
);
const rearCamera = CameraDescription(
  name: 'rear',
  lensDirection: CameraLensDirection.back,
  sensorOrientation: 90,
);

class FakeScanCamera extends GuidedCamera {
  FakeScanCamera() {
    cameras = [rearCamera, frontCamera];
    selectedCamera = rearCamera;
  }
  int starts = 0, stops = 0;
  bool available = true;
  bool failSwitch = false;
  final selections = <String>[];

  @override
  Future<void> selectCamera(CameraDescription choice) async {
    selections.add(choice.name);
    if (failSwitch && choice == frontCamera) {
      ready = false;
      return;
    }
    selectedCamera = choice;
    ready = true;
    emit();
  }

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
  Future<void> interrupt({bool lifecycle = false}) async {
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
    'bounded scan continues during upload then pauses when the queue is full',
    () async {
      final camera = FakeScanCamera();
      final first = Completer<void>();
      final calls = <String>[];
      final scan = ClassroomScan(camera, (file) async {
        calls.add(file.path);
        if (calls.length == 1) await first.future;
      }, maxQueued: 2);
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
    // No automatic retries here: exercises the manual path once automatic ones give up.
    final scan = ClassroomScan(camera, (file) async {
      calls.add(file.path);
      if (fail) throw StateError('offline');
    }, maxUploadRetries: 0);
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
  test('a flaky connection is retried automatically and the camera stays open', () async {
    final camera = FakeScanCamera();
    final waits = <Duration>[];
    var failures = 3;
    final calls = <String>[];
    final scan = ClassroomScan(camera, (file) async {
      calls.add(file.path);
      if (failures-- > 0) throw StateError('offline');
    }, wait: (d) async => waits.add(d));
    addTearDown(scan.dispose);
    await scan.start();
    camera.finish('flaky');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, ['flaky', 'flaky', 'flaky', 'flaky']);
    expect(waits.map((d) => d.inSeconds), [2, 4, 8]); // growing delay, no tight loop
    expect(scan.error, isNull);
    expect(scan.submitted, 1);
    expect(camera.ready, true); // never released
    expect(scan.reconnecting, false);
  });
  test('recording continues past two waiting segments up to the larger queue', () async {
    final camera = FakeScanCamera();
    final release = Completer<void>();
    final scan = ClassroomScan(camera, (file) => release.future);
    addTearDown(scan.dispose);
    await scan.start();
    for (final name in ['a', 'b', 'c']) {
      camera.finish(name);
      await Future<void>.delayed(Duration.zero);
    }
    expect(scan.pending, 3);
    expect(camera.starts, 4); // still recording a fourth segment
    expect(scan.recorded, 3);
    release.complete();
  });
  test('after the retry budget the scan pauses with the segments kept', () async {
    final camera = FakeScanCamera();
    final scan = ClassroomScan(camera, (file) async => throw StateError('offline'),
        maxUploadRetries: 2, wait: (_) async {});
    addTearDown(scan.dispose);
    await scan.start();
    camera.finish('kept');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(scan.error, contains('Upload paused'));
    expect(scan.pending, 1);
  });
  test('a flaky upload leaves a readable, privacy-safe trail of events', () async {
    final camera = FakeScanCamera();
    final trail = <String>[];
    var failures = 2;
    final scan = ClassroomScan(
      camera,
      (file) async {
        if (failures-- > 0) throw StateError('offline at https://secret.invalid/?token=1');
      },
      wait: (_) async {},
      onEvent: (name, {code, attempt, bytes, count, durationMs}) =>
          trail.add('$name:${code ?? ''}:${attempt ?? ''}:${count ?? ''}'),
    );
    addTearDown(scan.dispose);
    await scan.start();
    camera.finish('private-file-name');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await scan.stop();
    expect(trail, [
      'scan_started:::',
      'segment_recorded:::1',
      'upload_retry:StateError:1:',
      'upload_retry:StateError:2:',
      'upload_done::2:1',
      'scan_stopped:::1',
    ]);
    // Only a class name and numbers: neither the file name nor the error text.
    expect(trail.join(), isNot(contains('private')));
    expect(trail.join(), isNot(contains('secret')));
  });
  test('a terminal upload failure is reported once with its code', () async {
    final camera = FakeScanCamera();
    final trail = <String>[];
    final scan = ClassroomScan(
      camera,
      (file) async => throw const AppFailure('expired', code: 'UPLOAD_EXPIRED'),
      onEvent: (name, {code, attempt, bytes, count, durationMs}) =>
          trail.add('$name:${code ?? ''}'),
    );
    addTearDown(scan.dispose);
    await scan.start();
    camera.finish('x');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(trail.where((e) => e.startsWith('upload_failed')), ['upload_failed:UPLOAD_EXPIRED']);
    expect(trail.where((e) => e.startsWith('upload_retry')), isEmpty);
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

  test('Disposal keeps an unsent clip for recovery', () async {
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
    expect(await clip.exists(), true);
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

  group('switching between the front and rear camera', () {
    Future<void> pause() => Future<void>.delayed(const Duration(milliseconds: 30));

    test('mid-segment: the finished part is kept, then recording resumes on the other camera', () async {
      final camera = FakeScanCamera();
      final events = <String>[];
      final sent = <String>[];
      final scan = ClassroomScan(
        camera,
        (file) async => sent.add(file.path),
        onEvent: (name, {code, attempt, bytes, count, durationMs}) => events.add('$name:${code ?? ''}'),
      );
      addTearDown(scan.dispose);
      await scan.start();
      camera.elapsed = 12;
      expect(camera.starts, 1);
      await scan.switchCamera();
      await pause();
      expect(camera.selections, ['front']);
      expect(camera.selectedCamera, frontCamera);
      expect(camera.starts, 2, reason: 'recording continues on the new camera');
      expect(scan.scanning, isTrue);
      expect(scan.switching, isFalse);
      expect(scan.error, isNull);
      expect(scan.recorded, 1); // the part recorded so far was kept
      expect(events, contains('camera_switched:front'));
    });

    test('a very short part is dropped rather than uploaded', () async {
      final camera = FakeScanCamera();
      final scan = ClassroomScan(camera, (file) async {});
      addTearDown(scan.dispose);
      await scan.start();
      camera.elapsed = 1;
      await scan.switchCamera();
      await pause();
      expect(scan.recorded, 0);
      expect(camera.selectedCamera, frontCamera);
      expect(scan.scanning, isTrue);
    });

    test('before scanning it just swaps the camera and does not start recording', () async {
      final camera = FakeScanCamera();
      final scan = ClassroomScan(camera, (file) async {});
      addTearDown(scan.dispose);
      await camera.initialize();
      await scan.switchCamera();
      expect(camera.selectedCamera, frontCamera);
      expect(camera.starts, 0);
      expect(scan.scanning, isFalse);
    });

    test('if the other camera cannot open, the previous one is restored with a message', () async {
      final camera = FakeScanCamera()..failSwitch = true;
      final events = <String>[];
      final scan = ClassroomScan(
        camera,
        (file) async {},
        onEvent: (name, {code, attempt, bytes, count, durationMs}) => events.add('$name:${code ?? ''}'),
      );
      addTearDown(scan.dispose);
      await scan.start();
      camera.elapsed = 12;
      await scan.switchCamera();
      await pause();
      expect(camera.selections, ['front', 'rear']);
      expect(camera.selectedCamera, rearCamera);
      expect(camera.ready, isTrue);
      expect(scan.cameraError, contains('Could not switch cameras'));
      expect(events, contains('camera_failed:switch'));
      expect(scan.scanning, isTrue);
      expect(camera.starts, 2, reason: 'and recording carries on');
    });

    test('a second tap while switching is ignored', () async {
      final camera = FakeScanCamera();
      final scan = ClassroomScan(camera, (file) async {});
      addTearDown(scan.dispose);
      await scan.start();
      camera.elapsed = 12;
      await Future.wait([scan.switchCamera(), scan.switchCamera()]);
      await pause();
      expect(camera.selections, ['front']);
    });

    test('a single-camera phone cannot switch, and neither can a finished scan', () async {
      final camera = FakeScanCamera()..cameras = [rearCamera];
      final scan = ClassroomScan(camera, (file) async {});
      addTearDown(scan.dispose);
      expect(camera.canSwitch, isFalse);
      await scan.switchCamera();
      expect(camera.selections, isEmpty);
      final other = FakeScanCamera();
      final done = ClassroomScan(other, (file) async {});
      addTearDown(done.dispose);
      await done.start();
      await done.stop();
      await done.switchCamera();
      expect(other.selections, isEmpty);
    });

    test('otherCamera toggles direction and ignores extra rear lenses', () {
      const ultraWide = CameraDescription(
        name: 'ultrawide',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      );
      final camera = GuidedCamera()
        ..cameras = [rearCamera, ultraWide, frontCamera]
        ..selectedCamera = rearCamera;
      expect(camera.otherCamera, frontCamera);
      camera.selectedCamera = frontCamera;
      expect(camera.otherCamera, rearCamera); // the main lens, not the ultra-wide
      camera.selectedCamera = ultraWide;
      expect(camera.otherCamera, frontCamera);
    });
  });
}
