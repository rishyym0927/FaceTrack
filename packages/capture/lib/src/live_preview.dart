import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
    // The Student screen is portrait-locked. CameraPreview switches from
    // deviceOrientation to recordingOrientation at recording start, which can
    // rotate its texture even though the route and sensor have not moved.
    // Keep the same portrait display transform for both states.
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.android &&
        showGuide) {
      return Center(
        child: AspectRatio(
          aspectRatio: 1 / camera.value.aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [camera.buildPreview(), overlay],
          ),
        ),
      );
    }
    return Center(child: CameraPreview(camera, child: overlay));
  }
}
