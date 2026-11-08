import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'package:facetrack_capture/facetrack_capture.dart';


PoseFrameAnalyzer createStudentAnalyzer(CameraController camera) =>
    _MlKitAnalyzer(camera);

class _MlKitAnalyzer implements PoseFrameAnalyzer {
  _MlKitAnalyzer(this.camera)
    : detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableLandmarks: true,
          minFaceSize: .15,
        ),
      );

  final CameraController camera;
  final FaceDetector detector;

  @override
  Future<PoseObservation?> analyze(CameraImage image) async {
    if (image.planes.length != 1 || image.planes.first.bytes.isEmpty) {
      return null;
    }
    final rotation = _rotation();
    if (rotation == null) return null;
    final plane = image.planes.first;
    final input = InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: InputImageFormat.nv21,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
    final faces = await detector.processImage(input);
    final now = DateTime.now();
    if (faces.length != 1) {
      return PoseObservation(timestamp: now, faceCount: faces.length);
    }
    final face = faces.single;
    final orientedWidth =
        rotation == InputImageRotation.rotation90deg ||
            rotation == InputImageRotation.rotation270deg
        ? image.height.toDouble()
        : image.width.toDouble();
    final orientedHeight =
        rotation == InputImageRotation.rotation90deg ||
            rotation == InputImageRotation.rotation270deg
        ? image.width.toDouble()
        : image.height.toDouble();
    final rect = Rect.fromLTRB(
      (face.boundingBox.left / orientedWidth).clamp(0, 1),
      (face.boundingBox.top / orientedHeight).clamp(0, 1),
      (face.boundingBox.right / orientedWidth).clamp(0, 1),
      (face.boundingBox.bottom / orientedHeight).clamp(0, 1),
    );
    final lumaBytes = plane.bytes;
    final lumaLength = math.min(image.width * image.height, lumaBytes.length);
    var sum = 0, count = 0;
    for (var i = 0; i < lumaLength; i += 97) {
      sum += lumaBytes[i];
      count++;
    }
    return PoseObservation(
      timestamp: now,
      faceCount: 1,
      bounds: rect,
      // ML Kit reports angles in image coordinates. The front-camera preview
      // is mirrored for the student, so invert yaw to match the prompts.
      yaw: face.headEulerAngleY == null
          ? null
          : camera.description.lensDirection == CameraLensDirection.front
          ? -face.headEulerAngleY!
          : face.headEulerAngleY,
      pitch: face.headEulerAngleX,
      luminance: count == 0 ? null : sum / count,
    );
  }

  InputImageRotation? _rotation() {
    final turns = cameraQuarterTurns(
      camera.description,
      camera.value.deviceOrientation,
    );
    return InputImageRotationValue.fromRawValue(turns * 90);
  }

  @override
  Future<void> close() => detector.close();
}
