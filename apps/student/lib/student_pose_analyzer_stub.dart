import 'package:camera/camera.dart';
import 'package:facetrack_capture/facetrack_capture.dart';

PoseFrameAnalyzer createStudentAnalyzer(CameraController camera) =>
    throw UnsupportedError('Native pose analyzer is unavailable on web');
