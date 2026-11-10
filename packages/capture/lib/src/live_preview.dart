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
    final standardPreview = Center(
      child: CameraPreview(camera, child: overlay),
    );
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return standardPreview;
    }
    return ValueListenableBuilder<CameraValue>(
      valueListenable: camera,
      builder: (context, value, _) {
        if (!value.isInitialized) return const SizedBox.shrink();
        // The Student route stays portrait even if the controller reports
        // another recording orientation. Teacher follows device orientation.
        final fallback = showGuide
            ? _fittedPreview(
                1 / value.aspectRatio,
                camera.buildPreview(),
                overlay,
              )
            : standardPreview;
        return value.isRecordingVideo
            ? _AndroidRecordingPreview(
                key: ObjectKey(camera),
                camera: camera,
                fallback: fallback,
                overlay: overlay,
              )
            : fallback;
      },
    );
  }
}

Widget _fittedPreview(double aspectRatio, Widget texture, Widget overlay) =>
    Center(
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: Stack(fit: StackFit.expand, children: [texture, overlay]),
      ),
    );

class _AndroidRecordingPreview extends StatefulWidget {
  const _AndroidRecordingPreview({
    required super.key,
    required this.camera,
    required this.fallback,
    required this.overlay,
  });

  final CameraController camera;
  final Widget fallback, overlay;

  @override
  State<_AndroidRecordingPreview> createState() =>
      _AndroidRecordingPreviewState();
}

class _AndroidRecordingPreviewState extends State<_AndroidRecordingPreview> {
  late final Future<double?> _rawAspectRatio = _portraitBufferAspectRatio();

  Future<double?> _portraitBufferAspectRatio() async {
    final platform = CameraPlatform.instance;
    if (platform is! AndroidCameraCameraX) return null;
    // CameraX 0.7.6 exposes its live buffer size through this member.
    // Remove this bridge when flutter/flutter#180075 is fixed upstream.
    // ignore: invalid_use_of_visible_for_testing_member
    final preview = platform.preview;
    final camera = widget.camera;
    if (preview == null || camera.value.aspectRatio <= 1) return null;
    try {
      if (await preview.surfaceProducerHandlesCropAndRotation()) return null;
      // CameraX can reconfigure Preview as VideoCapture binds. In this case
      // StreamSharing has already rotated (and, for front lenses, mirrored)
      // the buffer. Bypass the plugin's sensor transform only for that output.
      // https://github.com/flutter/flutter/issues/180075
      for (var attempt = 0; attempt < 6; attempt++) {
        if (!mounted || !camera.value.isRecordingVideo) return null;
        final size = (await preview.getResolutionInfo())?.resolution;
        if (size != null && size.width > 0 && size.height > size.width) {
          return size.width / size.height;
        }
        if (attempt < 5)
          await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } on Exception {
      // The camera may close or switch during this asynchronous check.
    }
    return null;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<double?>(
    future: _rawAspectRatio,
    builder: (context, snapshot) {
      final aspectRatio = snapshot.data;
      if (aspectRatio == null) return widget.fallback;
      return _fittedPreview(
        aspectRatio,
        Texture(textureId: widget.camera.cameraId),
        widget.overlay,
      );
    },
  );
}
