import 'package:camera/camera.dart';

import 'pose_analyzer.dart';

PoseFrameAnalyzer createDeviceFaceAnalyzer(
  CameraController camera, {
  bool classroom = false,
}) => throw UnsupportedError('Live face analysis requires Android.');
