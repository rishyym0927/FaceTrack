import 'package:camera/camera.dart';
import 'package:facetrack_teacher/spike_app.dart';
import 'package:facetrack_teacher/spike_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeCamera implements CameraGateway {
  bool denied = false;
  int starts = 0, stops = 0, releases = 0;
  @override
  Future<void> initialize() async {
    if (denied) {
      throw CameraException(
        'CameraAccessDenied',
        'Synthetic permission failure',
      );
    }
  }

  @override
  Future<void> start() async {
    starts++;
  }

  @override
  Future<XFile> stop() async {
    stops++;
    return XFile('blob:synthetic-test-only');
  }

  @override
  Future<void> release() async {
    releases++;
  }

  @override
  Widget preview() => const Text('Synthetic preview fixture');
}

void main() {
  testWidgets('App starts with camera off and no automatic capture', (
    tester,
  ) async {
    await tester.pumpWidget(const FaceTrackCaptureApp());
    expect(find.text('Enable camera'), findsOneWidget);
    expect(find.text('Save video'), findsNothing);
    expect(find.textContaining('No cloud upload'), findsOneWidget);
  });
  test('Permission error is recoverable and consent is required', () async {
    final camera = FakeCamera()..denied = true;
    final session = CaptureSession(camera);
    await session.initialize();
    expect(session.ready, isFalse);
    expect(session.error, contains('permission'));
    camera.denied = false;
    await session.initialize();
    await session.start();
    expect(camera.starts, 0);
    session.setConsent(true);
    await session.start();
    expect(camera.starts, 1);
    expect(session.poses.first, 'front');
    expect(session.poses.toSet(), {'front', 'up', 'down', 'left', 'right'});
    session.dispose();
  });
  test('Short recordings are not offered for saving', () async {
    final session = CaptureSession(FakeCamera())..setConsent(true);
    await session.initialize();
    await session.start();
    await session.stop();
    expect(session.clip, isNull);
    expect(session.error, contains('too short'));
    session.dispose();
  });
  testWidgets('Guided recording auto-stops and preserves clip mode', (
    tester,
  ) async {
    var clock = DateTime.utc(2026, 10, 22);
    final camera = FakeCamera();
    final session = CaptureSession(camera, clock: () => clock)
      ..setConsent(true);
    await session.initialize();
    await session.start();
    session.changeMode('classroom');
    expect(session.mode, 'enrollment');
    clock = clock.add(const Duration(seconds: 15));
    await tester.pump(const Duration(milliseconds: 250));
    expect(camera.stops, 1);
    expect(session.clip, isNotNull);
    expect(session.recordedSeconds, 15);
    expect(session.recordedPoses.length, 5);
    session.changeMode('classroom');
    expect(session.clipMode, 'enrollment');
    session.dispose();
  });
  test(
    'Interruption releases camera and discards unfinished capture',
    () async {
      final camera = FakeCamera();
      final session = CaptureSession(camera)..setConsent(true);
      await session.initialize();
      await session.start();
      await session.close(interrupted: true);
      expect(session.ready, isFalse);
      expect(session.recording, isFalse);
      expect(session.clip, isNull);
      expect(camera.releases, greaterThan(0));
      session.dispose();
    },
  );
}
