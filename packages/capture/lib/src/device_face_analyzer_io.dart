import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';

import 'orientation.dart';
import 'pose_analyzer.dart';
import 'pose_guidance.dart';

PoseFrameAnalyzer createDeviceFaceAnalyzer(
  CameraController camera, {
  bool classroom = false,
}) => _MlKitAnalyzer(camera, classroom);

class _MlKitAnalyzer implements PoseFrameAnalyzer {
  _MlKitAnalyzer(this.camera, this.classroom)
    : detector = FaceDetector(
        options: FaceDetectorOptions(
          performanceMode: FaceDetectorMode.fast,
          enableLandmarks: !classroom,
          enableTracking: classroom,
          minFaceSize: classroom ? .08 : .15,
        ),
      );

  final CameraController camera;
  final bool classroom;
  final FaceDetector detector;

  @override
  Future<PoseObservation?> analyze(CameraImage image) async {
    if (image.format.group != ImageFormatGroup.nv21 ||
        image.planes.length != 1 ||
        image.planes.first.bytes.length < image.width * image.height * 3 ~/ 2) {
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
    final now = DateTime.now();
    final faces = await detector.processImage(input);
    if (!classroom && faces.length != 1) {
      return PoseObservation(timestamp: now, faceCount: faces.length);
    }
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
    Rect normalized(Rect box) => Rect.fromLTRB(
      (box.left / orientedWidth).clamp(0, 1),
      (box.top / orientedHeight).clamp(0, 1),
      (box.right / orientedWidth).clamp(0, 1),
      (box.bottom / orientedHeight).clamp(0, 1),
    );
    if (classroom) {
      return PoseObservation(
        timestamp: now,
        faceCount: faces.length,
        trackedFaces: [
          for (final face in faces)
            (
              id: face.trackingId,
              bounds: normalized(face.boundingBox),
              framed:
                  face.boundingBox.width >= 100 &&
                  face.boundingBox.height >= 100 &&
                  face.boundingBox.left > 0 &&
                  face.boundingBox.top > 0 &&
                  face.boundingBox.right < orientedWidth &&
                  face.boundingBox.bottom < orientedHeight,
            ),
        ],
      );
    }
    final face = faces.single;
    final rect = normalized(face.boundingBox);
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
      camera.value.recordingOrientation ?? camera.value.deviceOrientation,
    );
    return InputImageRotationValue.fromRawValue(turns * 90);
  }

  @override
  Future<void> close() => detector.close();
}
