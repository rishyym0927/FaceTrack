import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'orientation.dart';

Rect previewFaceRect(Rect bounds, Size size, {required bool mirrored}) =>
    Rect.fromLTWH(
      (mirrored ? 1 - bounds.right : bounds.left) * size.width,
      bounds.top * size.height,
      bounds.width * size.width,
      bounds.height * size.height,
    );

class LiveCameraPreview extends StatelessWidget {
  const LiveCameraPreview({
    super.key,
    required this.camera,
    this.faces = const [],
    this.showGuide = false,
    this.guideAligned = false,
    this.onFocus,
  });

  final CameraController camera;
  final List<({Rect bounds, bool framed})> faces;
  final bool showGuide, guideAligned;
  final ValueChanged<Offset>? onFocus;

  @override
  Widget build(BuildContext context) {
    final mirror =
        camera.description.lensDirection == CameraLensDirection.front;
    final overlay = LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: onFocus == null
              ? null
              : (event) {
                  if (size.isEmpty) return;
                  final x = event.localPosition.dx / size.width;
                  final y = event.localPosition.dy / size.height;
                  onFocus!(Offset(x.clamp(0, 1), y.clamp(0, 1)));
                },
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (showGuide)
                Center(
                  child: FractionallySizedBox(
                    widthFactor: .56,
                    heightFactor: .72,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: guideAligned
                              ? Colors.greenAccent
                              : Colors.white,
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(300),
                      ),
                    ),
                  ),
                ),
              for (final face in faces)
                Positioned.fromRect(
                  rect: previewFaceRect(face.bounds, size, mirrored: mirror),
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        border: Border.all(
                          color: face.framed
                              ? Colors.greenAccent
                              : Colors.white,
                          width: 3,
                        ),
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
    if (!kIsWeb && defaultTargetPlatform != TargetPlatform.android) {
      return Center(child: CameraPreview(camera, child: overlay));
    }
    return ValueListenableBuilder<CameraValue>(
      valueListenable: camera,
      builder: (context, value, _) {
        if (!value.isInitialized) return const SizedBox.shrink();
        // Use the sensor mapping previously verified on the demo phone.
        // Rotate only the texture. Face bounds already use oriented coordinates.
        final turns = kIsWeb
            ? 0
            : cameraQuarterTurns(
                camera.description,
                value.recordingOrientation ?? value.deviceOrientation,
              );
        return Center(
          child: AspectRatio(
            aspectRatio: turns.isOdd
                ? 1 / value.aspectRatio
                : value.aspectRatio,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RotatedBox(quarterTurns: turns, child: camera.buildPreview()),
                overlay,
              ],
            ),
          ),
        );
      },
    );
  }
}
