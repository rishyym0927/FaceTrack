import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
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
    if (image.planes.length != 1) return null;
    final plane = image.planes.first;
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    final InputImageRotation? rotation;
    final InputImageFormat format;
    if (isIos) {
      // AVFoundation applies orientation to its video output before streaming.
      if (image.format.group != ImageFormatGroup.bgra8888 ||
          plane.bytesPerRow < image.width * 4 ||
          plane.bytes.length < plane.bytesPerRow * image.height) {
        return null;
      }
      format = InputImageFormat.bgra8888;
      rotation = InputImageRotation.rotation0deg;
    } else {
      // CameraX can label its converted single NV21 plane as YUV_420_888.
      if ((image.format.group != ImageFormatGroup.nv21 &&
              image.format.group != ImageFormatGroup.yuv420) ||
          plane.bytes.length < image.width * image.height * 3 ~/ 2) {
        return null;
      }
      format = InputImageFormat.nv21;
      rotation = _rotation();
    }
    if (rotation == null) return null;
    final input = InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
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
      if (isIos) {
        final pixel =
            (i ~/ image.width) * plane.bytesPerRow + (i % image.width) * 4;
        // Approximate luma from the BGRA channels.
        sum +=
            (29 * lumaBytes[pixel] +
                150 * lumaBytes[pixel + 1] +
                77 * lumaBytes[pixel + 2]) >>
            8;
      } else {
        sum += lumaBytes[i];
      }
      count++;
    }
    return PoseObservation(
      timestamp: now,
      faceCount: 1,
      bounds: rect,
      // The iOS front-camera frames are already mirrored by AVFoundation.
      yaw: face.headEulerAngleY == null
          ? null
          : !isIos &&
                camera.description.lensDirection == CameraLensDirection.front
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
