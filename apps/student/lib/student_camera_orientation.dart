import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// Rotation from camera sensor coordinates into the current device view.
/// The Android preview texture and ML Kit input must use the same convention.
int cameraQuarterTurns(
  CameraDescription description,
  DeviceOrientation orientation,
) {
  final deviceDegrees = switch (orientation) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };
  final sensorDegrees = description.sensorOrientation;
  final degrees = description.lensDirection == CameraLensDirection.front
      ? (sensorDegrees + deviceDegrees) % 360
      : (sensorDegrees - deviceDegrees + 360) % 360;
  return degrees ~/ 90;
}
