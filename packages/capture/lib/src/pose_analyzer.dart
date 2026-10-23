import 'package:camera/camera.dart';

import 'pose_guidance.dart';

abstract class PoseFrameAnalyzer {
  Future<PoseObservation?> analyze(CameraImage image);
  Future<void> close();
}
