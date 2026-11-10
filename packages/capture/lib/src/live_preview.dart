import 'package:camera/camera.dart';
import 'package:camera_android_camerax/camera_android_camerax.dart';
import 'package:camera_platform_interface/camera_platform_interface.dart'
    show CameraPlatform;
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
            children: [
              ValueListenableBuilder<CameraValue>(
                valueListenable: camera,
                child: camera.buildPreview(),
                builder: (context, value, preview) => value.isRecordingVideo
                    ? _StudentRecordingTexture(
                        camera: camera,
                        fallback: preview!,
                      )
                    : preview!,
              ),
              overlay,
            ],
          ),
        ),
      );
    }
    return Center(child: CameraPreview(camera, child: overlay));
  }
}

class _StudentRecordingTexture extends StatefulWidget {
  const _StudentRecordingTexture({
    required this.camera,
    required this.fallback,
  });

  final CameraController camera;
  final Widget fallback;

  @override
  State<_StudentRecordingTexture> createState() =>
      _StudentRecordingTextureState();
}

class _StudentRecordingTextureState extends State<_StudentRecordingTexture> {
  late final Future<bool> _useRawTexture = _hasPortraitBuffer();

  Future<bool> _hasPortraitBuffer() async {
    final platform = CameraPlatform.instance;
    if (platform is! AndroidCameraCameraX) return false;
    // CameraX 0.7.6 exposes its live buffer size through this member.
    // Remove this bridge when flutter/flutter#180075 is fixed upstream.
    // ignore: invalid_use_of_visible_for_testing_member
    final preview = platform.preview;
    final camera = widget.camera;
    if (preview == null || camera.value.aspectRatio <= 1) return false;
    try {
      if (await preview.surfaceProducerHandlesCropAndRotation()) return false;
      // CameraX can reconfigure Preview as VideoCapture binds. In this case
      // StreamSharing has already rotated (and, for front lenses, mirrored)
      // the buffer. Bypass the plugin's sensor transform only for that output.
      // https://github.com/flutter/flutter/issues/180075
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!mounted || !camera.value.isRecordingVideo) return false;
        final size = (await preview.getResolutionInfo())?.resolution;
        if (size != null && size.height > size.width) return true;
        if (attempt < 5)
          await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on Exception {
      // The camera may close or switch during this asynchronous check.
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
    future: _useRawTexture,
    builder: (context, snapshot) => snapshot.data == true
        ? Texture(textureId: widget.camera.cameraId)
        : widget.fallback,
  );
}
