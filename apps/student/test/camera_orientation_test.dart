import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:facetrack_student/student_camera_orientation.dart';

void main() {
  test('front sensor rotation follows device orientation', () {
    const front = CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 270,
    );
    expect(cameraQuarterTurns(front, DeviceOrientation.portraitUp), 3);
    expect(cameraQuarterTurns(front, DeviceOrientation.landscapeLeft), 0);
    expect(cameraQuarterTurns(front, DeviceOrientation.portraitDown), 1);
    expect(cameraQuarterTurns(front, DeviceOrientation.landscapeRight), 2);
  });

  test('rear sensor uses opposite device rotation', () {
    const rear = CameraDescription(
      name: 'rear',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    );
    expect(cameraQuarterTurns(rear, DeviceOrientation.portraitUp), 1);
    expect(cameraQuarterTurns(rear, DeviceOrientation.landscapeLeft), 0);
  });
}
