import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathProvider, (call) async {
        if (call.method == 'getApplicationSupportDirectory' ||
            call.method == 'getTemporaryDirectory') {
          return Directory.systemTemp.path;
        }
        return null;
      });
  const front = CameraDescription(
    name: 'front',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 270,
  );
  const back = CameraDescription(
    name: 'back',
    lensDirection: CameraLensDirection.back,
    sensorOrientation: 90,
  );
  test(
    'Analysis and camera-control failures leave classroom recording usable',
    () async {
      final controller = _RecordingOnlyCamera(back);
      final camera = GuidedCamera(analyzerFactory: (_) => _UnusedAnalyzer())
        ..controller = controller
        ..ready = true;
      addTearDown(() async {
        await camera.interrupt();
        camera.dispose();
      });
      await camera.start(const []);
      expect(controller.frameRequests, 1);
      expect(controller.plainRequests, 1);
      expect(camera.recording, true);
      expect(camera.faceTracker.available, false);

      await camera.toggleTorch();
      expect(camera.controlMessage, contains('Torch is unavailable'));
      await camera.focus(const Offset(.5, .5));
      expect(camera.controlMessage, contains('Tap-to-focus is unavailable'));
      expect(camera.recording, true);

      camera.elapsed = 15;
      await camera.stop();
      expect(camera.clip?.path, 'synthetic.mp4');
      expect(camera.recording, false);
    },
  );

  test(
    'Cancelling a classroom recording releases the camera and torch',
    () async {
      final controller = _RecordingOnlyCamera(back, torchSupported: true);
      final camera = GuidedCamera()
        ..controller = controller
        ..ready = true;
      addTearDown(camera.dispose);
      await camera.toggleTorch();
      await camera.start(const []);
      await camera.interrupt();
      expect(controller.torchWasTurnedOff, true);
      expect(camera.controller, isNull);
      expect(camera.clip, isNull);
      expect(camera.recording, false);
    },
  );

  test(
    'Retake releases the stopped camera before opening a fresh preview',
    () async {
      final first = _RecordingOnlyCamera(back);
      final camera = _RetakeCamera()
        ..controller = first
        ..ready = true
        ..clip = XFile('synthetic.mp4');
      addTearDown(camera.dispose);

      await camera.retake();

      expect(camera.opened, 1);
      expect(camera.controller, isNull);
      expect(camera.clip, isNull);
      expect(camera.recording, false);
    },
  );

  test(
    'Preview analysis stops before recording and resets challenge progress',
    () async {
      final controller = _RecordingOnlyCamera(front);
      final camera =
          GuidedCamera(
              enrollmentGuidance: true,
              analyzerFactory: (_) => _UnusedAnalyzer(),
            )
            ..controller = controller
            ..ready = true;
      addTearDown(camera.dispose);
      await camera.startPreviewAnalysis();
      expect(controller.value.isStreamingImages, true);
      final before = camera.guidance!;
      final now = DateTime.now();
      for (final ms in [0, 500, 1000]) {
        before.observe(
          PoseObservation(
            timestamp: now.add(Duration(milliseconds: ms)),
            faceCount: 1,
            bounds: const Rect.fromLTWH(.3, .2, .4, .6),
            yaw: 0,
            pitch: 0,
          ),
          allowCompletion: false,
        );
      }
      expect(before.faceFramed, true);
      expect(before.completed, isEmpty);
      await camera.start(const ['front', 'left']);
      expect(controller.value.isStreamingImages, false);
      expect(camera.guidance, isNot(same(before)));
      expect(camera.guidance!.completed, isEmpty);
      expect(camera.recording, true);
      await camera.interrupt();
    },
  );

  test('Classroom prefers the rear camera and falls back when absent', () {
    expect(preferredCamera([front, back], enrollment: false), back);
    expect(preferredCamera([front], enrollment: false), front);
    expect(preferredCamera([back, front], enrollment: true), front);
  });

  test(
    'Face outline shares the fitted rectangle and mirrors only for front',
    () {
      const bounds = Rect.fromLTWH(.125, .25, .25, .5);
      expect(
        previewFaceRect(bounds, const Size(640, 480), mirrored: false),
        const Rect.fromLTWH(80, 120, 160, 240),
      );
      expect(
        previewFaceRect(bounds, const Size(640, 480), mirrored: true),
        const Rect.fromLTWH(400, 120, 160, 240),
      );
    },
  );

  testWidgets(
    'Portrait preview delegates sensor rotation and fits the overlay',
    (tester) async {
      final controller = _RecordingOnlyCamera(front);
      addTearDown(controller.dispose);
      controller.value = controller.value.copyWith(
        isInitialized: true,
        previewSize: const Size(1280, 720),
      );
      const bounds = Rect.fromLTWH(.125, .25, .25, .5);
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: SizedBox(
              width: 360,
              height: 520,
              child: LiveCameraPreview(
                camera: controller,
                faces: [(bounds: bounds, framed: true)],
              ),
            ),
          ),
        ),
      );
      final preview = tester.getRect(find.byType(AspectRatio));
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        0,
      );
      expect(preview.width, lessThan(preview.height));
      controller.value = controller.value.copyWith(
        isRecordingVideo: true,
        recordingOrientation: const Optional.of(DeviceOrientation.portraitUp),
      );
      await tester.pump();
      expect(
        tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns,
        0,
      );
      expect(tester.getRect(find.byType(AspectRatio)), preview);
      final box = tester.getRect(find.byType(Positioned));
      expect(
        box,
        previewFaceRect(
          bounds,
          preview.size,
          mirrored: true,
        ).shift(preview.topLeft),
      );
    },
  );

  testWidgets(
    'Student Android preview stays portrait when recording reports landscape',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final controller = _RecordingOnlyCamera(front);
      addTearDown(controller.dispose);
      controller.value = controller.value.copyWith(
        isInitialized: true,
        previewSize: const Size(1280, 720),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 360,
            height: 600,
            child: LiveCameraPreview(camera: controller, showGuide: true),
          ),
        ),
      );
      final before = tester.getRect(find.byType(AspectRatio));
      expect(before.width, lessThan(before.height));
      expect(find.byType(RotatedBox), findsNothing);
      controller.value = controller.value.copyWith(
        isRecordingVideo: true,
        recordingOrientation: const Optional.of(
          DeviceOrientation.landscapeLeft,
        ),
      );
      await tester.pump();
      expect(tester.getRect(find.byType(AspectRatio)), before);
      expect(find.byType(RotatedBox), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    },
  );

  test(
    'Tracking qualifies only continuously framed faces and clears stale boxes',
    () {
      final tracker = LiveFaceTracker();
      addTearDown(tracker.dispose);
      final start = DateTime.utc(2026, 11, 9);
      void frame(int ms, {int? id = 1, bool framed = true}) => tracker.observe(
        PoseObservation(
          timestamp: start.add(Duration(milliseconds: ms)),
          faceCount: 1,
          trackedFaces: [
            (
              id: id,
              bounds: const Rect.fromLTWH(.25, .25, .5, .5),
              framed: framed,
            ),
          ],
        ),
      );
      frame(0);
      frame(399);
      expect(tracker.faces.single.framed, false);
      frame(400);
      expect(tracker.faces.single.framed, true);
      frame(600, framed: false);
      frame(800);
      expect(tracker.faces.single.framed, false);
      frame(1200, id: null);
      expect(tracker.faces.single.framed, false);
      tracker.expire(start.add(const Duration(milliseconds: 2200)));
      expect(tracker.faces, isEmpty);
      expect(tracker.available, false);
    },
  );

  test(
    'Stale Student guidance clears the outline without marking a pose complete',
    () {
      final guidance = PoseGuidance(order: ['front']);
      addTearDown(guidance.dispose);
      final start = DateTime.utc(2026, 11, 9);
      guidance.observe(
        PoseObservation(
          timestamp: start,
          faceCount: 1,
          bounds: const Rect.fromLTWH(.25, .25, .5, .5),
          yaw: 0,
          pitch: 0,
        ),
      );
      expect(guidance.faceBounds, isNotNull);
      guidance.unavailable(start.add(const Duration(seconds: 3)));
      expect(guidance.faceBounds, isNull);
      expect(guidance.analysisUnavailable, true);
      expect(guidance.completed, isEmpty);
    },
  );
}

class _RecordingOnlyCamera extends CameraController {
  _RecordingOnlyCamera(
    CameraDescription description, {
    this.torchSupported = false,
  }) : super(description, ResolutionPreset.high);
  final bool torchSupported;
  bool torchWasTurnedOff = false;
  int frameRequests = 0, plainRequests = 0;

  @override
  Future<void> startImageStream(void Function(CameraImage) onAvailable) async {
    value = value.copyWith(isStreamingImages: true);
  }

  @override
  Future<void> stopImageStream() async {
    value = value.copyWith(isStreamingImages: false);
  }

  @override
  Widget buildPreview() => const SizedBox.expand();

  @override
  Future<void> startVideoRecording({
    void Function(CameraImage)? onAvailable,
    bool enablePersistentRecording = true,
  }) async {
    if (value.isStreamingImages)
      throw StateError('Preview stream still active');
    if (onAvailable != null) {
      frameRequests++;
      throw CameraException(
        'Unsupported',
        'Concurrent frame analysis unavailable.',
      );
    }
    plainRequests++;
    value = value.copyWith(isRecordingVideo: true);
  }

  @override
  Future<void> setFlashMode(FlashMode mode) async {
    if (!torchSupported) throw CameraException('Unsupported', 'No torch.');
    torchWasTurnedOff = mode == FlashMode.off;
    value = value.copyWith(flashMode: mode);
  }

  @override
  Future<XFile> stopVideoRecording() async {
    value = value.copyWith(isRecordingVideo: false);
    return XFile('synthetic.mp4');
  }
}

class _UnusedAnalyzer implements PoseFrameAnalyzer {
  @override
  Future<PoseObservation?> analyze(CameraImage image) async => null;

  @override
  Future<void> close() async {}
}

class _RetakeCamera extends GuidedCamera {
  int opened = 0;

  @override
  Future<void> initialize() async {
    opened++;
  }
}
