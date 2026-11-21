import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'browser_capture_stub.dart'
    if (dart.library.js_interop) 'browser_capture_web.dart'
    as browser;
import 'framing.dart';
import 'files_stub.dart'
    if (dart.library.io) 'files_io.dart'
    if (dart.library.js_interop) 'files_web.dart'
    as files;
import 'pose_analyzer.dart';
import 'pose_guidance.dart';
import 'web_framing_stub.dart'
    if (dart.library.js_interop) 'web_framing_web.dart'
    as web;

/// Names a laptop's own webcam; a camera that is not one of these is probably a USB webcam
/// plugged in on purpose, which is what a teacher scanning a room wants by default.
final _builtInCamera = RegExp(r'built-?in|integrated|facetime|internal', caseSensitive: false);

CameraDescription preferredCamera(
  List<CameraDescription> cameras, {
  required bool enrollment,
  String? remembered,
}) {
  if (remembered != null) {
    for (final camera in cameras) {
      if (camera.name == remembered) return camera;
    }
  }
  final lens = enrollment ? CameraLensDirection.front : CameraLensDirection.back;
  for (final camera in cameras) {
    if (camera.lensDirection == lens) return camera;
  }
  if (!enrollment) {
    for (final camera in cameras) {
      if (!_builtInCamera.hasMatch(camera.name)) return camera;
    }
  }
  return cameras.first;
}

/// A readable name for the camera list: the browser's device label, or front / rear / external.
String describeCamera(CameraDescription camera, List<CameraDescription> all) {
  final name = camera.name
      .replaceAll(RegExp(r'\s*\([0-9a-f]{4}:[0-9a-f]{4}\)\s*$'), '')
      .trim();
  if (kIsWeb && name.isNotEmpty) return name;
  final same = all.where((c) => c.lensDirection == camera.lensDirection).toList();
  final number = same.length > 1 ? ' ${same.indexOf(camera) + 1}' : '';
  return switch (camera.lensDirection) {
    CameraLensDirection.front => 'Front camera$number',
    CameraLensDirection.back => 'Rear camera$number',
    CameraLensDirection.external => 'External camera$number',
  };
}

class LiveFaceTracker extends ChangeNotifier {
  final _since = <int, DateTime>{};
  List<({Rect bounds, bool framed})> faces = [];
  DateTime? _last;
  bool get available => _last != null;

  void observe(PoseObservation observation) {
    expire(observation.timestamp);
    _last = observation.timestamp;
    final visible = <int>{};
    faces = [
      for (final face in observation.trackedFaces)
        (
          bounds: face.bounds,
          framed: _qualified(face, observation.timestamp, visible),
        ),
    ];
    _since.removeWhere((id, _) => !visible.contains(id));
    notifyListeners();
  }

  /// Faces already judged by the caller (fully in view and steady), as the browser detector does.
  void observeBoxes(
    List<({int id, Rect bounds, bool framed})> found,
    DateTime now,
  ) {
    _last = now;
    final next = [for (final f in found) (bounds: f.bounds, framed: f.framed)];
    // The browser reports five times a second; a steady picture repaints nothing.
    if (next.length == faces.length) {
      var same = true;
      for (var i = 0; same && i < next.length; i++) {
        same = next[i].bounds == faces[i].bounds && next[i].framed == faces[i].framed;
      }
      if (same) return;
    }
    faces = next;
    notifyListeners();
  }

  bool _qualified(
    ({int? id, Rect bounds, bool framed}) face,
    DateTime now,
    Set<int> visible,
  ) {
    final id = face.id;
    if (!face.framed || id == null) return false;
    visible.add(id);
    return now.difference(_since.putIfAbsent(id, () => now)) >=
        const Duration(milliseconds: 400);
  }

  void expire(DateTime now) {
    if (_last == null || now.difference(_last!) >= const Duration(seconds: 1))
      clear();
  }

  void clear() {
    final changed = _last != null;
    faces = [];
    _since.clear();
    _last = null;
    if (changed) notifyListeners();
  }
}

class GuidedCamera extends ChangeNotifier {
  GuidedCamera({this.enrollmentGuidance = false, this.analyzerFactory});
  static const enrollmentMinimumSeconds = 10;
  // The file starts at the first encoded frame, which can lag camera startup.
  static const enrollmentStopSeconds = enrollmentMinimumSeconds + 2;
  static const enrollmentMaximumSeconds = 25;

  final bool enrollmentGuidance;

  /// Optional hook for diagnostics: `camera_failed` / `camera_interrupted` with a short code.
  void Function(String name, {String? code})? onEvent;

  /// Classroom segment length. The default bitrate of the phone made 15 s clips 12-23 MB,
  /// so a fixed rate (below) is what makes longer segments fit the 25 MiB upload limit.
  static const classroomBitrate = 6000000;
  static const classroomFps = 15;
  static const minSegmentSeconds = 10, maxSegmentSeconds = 30;
  int _segmentSeconds = 20;
  int get segmentSeconds => _segmentSeconds;
  set segmentSeconds(int value) {
    _segmentSeconds = value.clamp(minSegmentSeconds, maxSegmentSeconds);
    emit();
  }
  final PoseFrameAnalyzer Function(CameraController)? analyzerFactory;
  CameraController? controller;
  List<CameraDescription> cameras = [];
  CameraDescription? selectedCamera;

  /// The camera chosen last in this browser tab, so a re-opened scan keeps a USB webcam.
  static String? rememberedClassroomCamera;

  /// Set when the open camera stopped (unplugged, taken by another app, permission revoked).
  /// Cleared by the next successful open.
  bool lost = false;
  CameraDescription? lostCamera;

  /// Browser only: how bright the picture is and whether the face detector is running.
  Lighting lighting = Lighting.unknown;
  int? light;
  bool framingAvailable = false, framingFailed = false;
  Timer? _framingTimer;
  int _endedTicks = 0;
  void Function()? _stopDeviceWatch;
  Timer? _deviceDebounce;
  bool get framesFaces => kIsWeb && !enrollmentGuidance;

  /// Browser only: ask the browser to warn before the tab is closed (unsent video is in memory).
  static void warnBeforeLeaving(bool on) {
    if (kIsWeb) web.guardWebUnload(on);
  }
  PoseFrameAnalyzer? analyzer;
  PoseGuidance? guidance;
  Timer? timer, _faceExpiry;
  final faceTracker = LiveFaceTracker();
  String? controlMessage;
  Future<void> focus(Offset point) async {
    final current = controller;
    if (current == null || busy) return;
    if (!current.value.focusPointSupported) {
      controlMessage = 'Tap-to-focus is unavailable on this camera.';
    } else {
      try {
        await current.setFocusPoint(point);
        controlMessage = null;
      } catch (_) {
        controlMessage = 'Could not adjust focus on this camera.';
      }
    }
    if (identical(controller, current)) emit();
  }

  Future<void> toggleTorch() async {
    final current = controller;
    if (current == null || busy) return;
    try {
      await current.setFlashMode(
        current.value.flashMode == FlashMode.torch
            ? FlashMode.off
            : FlashMode.torch,
      );
      controlMessage = null;
    } catch (_) {
      controlMessage = 'Torch is unavailable on this camera.';
    }
    if (identical(controller, current)) emit();
  }

  /// Student enrolment is portrait-first. Locking the capture orientation
  /// gives CameraX one stable preview/recording convention without rotating
  /// the raw frames used by ML Kit.
  Future<void> lockPortraitCapture() async {
    final current = controller;
    if (current == null || kIsWeb) return;
    try {
      await current.lockCaptureOrientation(DeviceOrientation.portraitUp);
    } catch (_) {
      controlMessage = 'Camera orientation could not be locked.';
      emit();
    }
  }

  Future<void> unlockCaptureOrientation() async {
    final current = controller;
    if (current == null || kIsWeb) return;
    try {
      await current.unlockCaptureOrientation();
    } catch (_) {
      // Disposal still releases the camera when a device rejects unlocking.
    }
  }

  Future<void> _closeAnalyzer(PoseFrameAnalyzer? old) async {
    try {
      await old?.close();
    } catch (_) {
      // A failed detector cleanup must not block recording or camera release.
    }
  }

  Future<void> _release(CameraController? old) async {
    if (old == null) return;
    if (old.value.flashMode == FlashMode.torch) {
      try {
        await old.setFlashMode(FlashMode.off);
      } catch (_) {}
    }
    try {
      await old.dispose();
    } catch (_) {
      // A controller that fails to dispose must not leave the camera dead for the next open.
    }
  }

  bool recording = false, busy = false, disposed = false, ready = false;
  /// True when the camera was open or opening when the app was paused.
  bool interrupted = false;
  bool _analysisBusy = false, _previewAnalyzing = false;
  Future<void>? _pendingAnalysis;
  Timer? _previewExpiry;
  DateTime? _lastAnalysis;
  final _recordingClock = Stopwatch();
  int elapsed = 0, epoch = 0;
  List<String> poses = [];
  XFile? clip;
  String? error;
  List<String> get missingPoses => guidance == null
      ? const []
      : guidance!.order.where((p) => !guidance!.completed.contains(p)).toList();
  void emit() {
    if (!disposed) notifyListeners();
  }

  /// Reopens the camera after the app returns from the background or a permission dialog.
  Future<void> resumeIfInterrupted() async {
    if (!interrupted || disposed) return;
    // interrupt() may still be releasing the old controller.
    for (var i = 0; busy && i < 25 && !disposed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (busy || disposed || !interrupted) return;
    interrupted = false;
    await initialize();
  }

  Future<void> initialize() async {
    if (busy || ready) return;
    interrupted = false;
    final generation = ++epoch;
    busy = true;
    error = null;
    emit();
    CameraController? next;
    try {
      if (kIsWeb && enrollmentGuidance) {
        ready = true;
        return;
      }
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera');
      this.cameras = cameras;
      if (!cameras.contains(selectedCamera)) {
        selectedCamera = preferredCamera(
          cameras,
          enrollment: enrollmentGuidance,
          remembered: enrollmentGuidance ? null : rememberedClassroomCamera,
        );
      }
      next = CameraController(
        selectedCamera!,
        ResolutionPreset.high,
        enableAudio: false,
        fps: enrollmentGuidance ? 24 : classroomFps,
        videoBitrate: enrollmentGuidance ? 4000000 : classroomBitrate,
        imageFormatGroup: analyzerFactory != null && !kIsWeb
            ? (defaultTargetPlatform == TargetPlatform.iOS
                  ? ImageFormatGroup.bgra8888
                  : ImageFormatGroup.nv21)
            : null,
      );
      await next.initialize();
      if (disposed || generation != epoch) {
        await next.dispose();
        return;
      }
      controller = next;
      ready = true;
      lost = false;
      lostCamera = null;
      next.addListener(_controllerChanged);
      if (enrollmentGuidance && !kIsWeb) await lockPortraitCapture();
      await startPreviewAnalysis();
      if (framesFaces) _startWebFraming();
    } catch (_) {
      await next?.dispose();
      if (!disposed && generation == epoch) {
        error = 'Camera unavailable. Allow camera access, close other camera apps and retry.';
        onEvent?.call('camera_failed', code: 'init');
      }
    } finally {
      if (generation == epoch) busy = false;
      emit();
    }
  }

  // ---- Browser: live framing and camera hot-plug --------------------------------------------

  void _startWebFraming() {
    _framingTimer?.cancel();
    framingAvailable = false;
    framingFailed = false;
    final generation = epoch;
    unawaited(
      web.startWebFraming().then((ok) {
        // The camera was closed or swapped while the detector loaded: not a failure to report.
        if (disposed || generation != epoch) return;
        framingAvailable = ok;
        framingFailed = !ok;
        emit();
      }),
    );
    _framingTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => _webTick());
    _stopDeviceWatch ??= web.watchWebDevices(() {
      _deviceDebounce?.cancel();
      _deviceDebounce = Timer(const Duration(milliseconds: 600), () {
        // Re-reading the list opens every camera, so only do it while one is open.
        if (ready && !disposed) unawaited(refreshCameras());
      });
    });
  }

  void _stopWebFraming({bool release = true}) {
    _framingTimer?.cancel();
    _framingTimer = null;
    // Keep the loaded detector while only swapping cameras: loading it takes about a second.
    if (framesFaces && release) {
      web.stopWebFraming();
      // The hot-plug listener belongs to an open camera. It used to live until the page was
      // disposed, so a headset plugged in while no scan was running re-opened every camera.
      _deviceDebounce?.cancel();
      _stopDeviceWatch?.call();
      _stopDeviceWatch = null;
    }
    faceTracker.clear();
    light = null;
    lighting = Lighting.unknown;
  }

  void _webTick() {
    if (disposed || !ready || busy && !recording) return;
    applyFraming(web.readWebFraming());
  }

  /// Folds one look at the browser preview into the camera state. Split from [_webTick] so the
  /// notification rules can be tested without a browser.
  @visibleForTesting
  void applyFraming(FramingReading reading) {
    if (!reading.video) {
      // The browser fires no error when a webcam is unplugged, so a picture that has ended for
      // a moment (not a single missed frame) is treated as the camera being lost.
      if (reading.ended && ++_endedTicks >= 3) _cameraLost();
      return;
    }
    _endedTicks = 0;
    // Faces are announced by [faceTracker] to the widgets that draw them. The camera itself
    // only notifies when the light advice or detector state changes: notifying on every change
    // of the face count rebuilt the whole scan page several times a second.
    final before = (lighting, framingAvailable);
    // Smooth the light reading so a passing hand does not flicker the advice.
    final value = reading.light;
    if (value != null) {
      light = light == null ? value : ((light! * 3 + value) / 4).round();
      lighting = lightingOf(light);
    }
    final faces = reading.faces;
    if (faces != null) {
      faceTracker.observeBoxes(faces, DateTime.now());
    } else {
      faceTracker.expire(DateTime.now());
    }
    if (reading.detector != framingAvailable) framingAvailable = reading.detector;
    if (before != (lighting, framingAvailable)) emit();
  }

  /// Re-reads the list of cameras after one is plugged in or removed.
  Future<void> refreshCameras() async {
    if (disposed || busy || recording || !kIsWeb) return;
    try {
      final found = await availableCameras();
      if (disposed || found.isEmpty && ready) return;
      cameras = found;
      final current = selectedCamera;
      if (current != null && ready && !found.contains(current)) _cameraLost();
      emit();
    } catch (_) {
      // Keep the list we have; the open camera reports its own problems.
    }
  }

  void _controllerChanged() {
    final current = controller;
    if (current == null || disposed || lost) return;
    if (current.value.hasError) _cameraLost();
  }

  /// The open camera is gone. A segment being recorded is kept when long enough; the page
  /// then picks another camera or asks the teacher to reconnect.
  void _cameraLost() {
    if (lost || disposed || enrollmentGuidance) return;
    lost = true;
    _endedTicks = 0;
    lostCamera = selectedCamera;
    onEvent?.call('camera_failed', code: 'lost');
    unawaited(() async {
      final wasRecording = recording;
      if (wasRecording) await stop(minimumSeconds: 4);
      final old = controller;
      _stopWebFraming();
      await _stopPreviewAnalysis(old);
      controller = null;
      ready = false;
      error = 'Camera disconnected. Reconnect it or choose another camera.';
      emit();
      await _release(old);
    }());
  }

  Future<void>? _previewStarting;

  /// Framing feedback before recording never completes challenge poses.
  Future<void> startPreviewAnalysis() {
    final starting = _startPreviewAnalysis();
    _previewStarting = starting;
    return starting.whenComplete(() {
      if (identical(_previewStarting, starting)) _previewStarting = null;
    });
  }

  Future<void> _startPreviewAnalysis() async {
    final current = controller;
    if (kIsWeb ||
        current == null ||
        analyzerFactory == null ||
        recording ||
        _previewAnalyzing ||
        disposed)
      return;
    final generation = epoch;
    try {
      guidance?.removeListener(emit);
      guidance?.dispose();
      guidance = enrollmentGuidance
          ? (PoseGuidance(order: const ['front'])..addListener(emit))
          : null;
      analyzer = analyzerFactory!(current);
      _previewAnalyzing = true;
      _lastAnalysis = null;
      await current.startImageStream(_analyzeFrame);
      if (generation != epoch || disposed) return;
      _previewExpiry?.cancel();
      _previewExpiry = Timer.periodic(const Duration(milliseconds: 500), (_) {
        guidance?.unavailable(DateTime.now());
        faceTracker.expire(DateTime.now());
      });
    } catch (_) {
      if (generation == epoch) {
        await _teardownPreviewAnalysis(current);
        guidance?.unavailable(DateTime.now());
      }
    }
  }

  /// True while the preview analysis timer runs (exposed for tests: it must never outlive the
  /// preview stream, or it leaks once per segment).
  @visibleForTesting
  bool get previewTimerActive => _previewExpiry?.isActive ?? false;

  Future<void> _stopPreviewAnalysis(CameraController? current) async {
    // A preview that is still opening its image stream must finish first. Stopping before the
    // stream existed skipped stopImageStream, so the stream then started under the recording
    // that was about to begin (blocking its frame analysis) and its expiry timer was never
    // cancelled. This is the segment-boundary path: stop() restarts the preview, the saved
    // clip triggers the next start() within the same few milliseconds.
    final starting = _previewStarting;
    if (starting != null) {
      try {
        // Bounded: a stream that never opens must not stop the camera being released.
        await starting.timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await _teardownPreviewAnalysis(current);
  }

  Future<void> _teardownPreviewAnalysis(CameraController? current) async {
    if (!_previewAnalyzing) return;
    _previewAnalyzing = false;
    _previewExpiry?.cancel();
    _previewExpiry = null;
    final old = analyzer;
    analyzer = null;
    try {
      if (current?.value.isStreamingImages == true)
        await current!.stopImageStream();
    } catch (_) {
      // The platform may already have stopped its stream on backgrounding.
    }
    await _pendingAnalysis;
    await _closeAnalyzer(old);
  }

  /// The camera a "flip" should switch to: the front camera when a rear one is in use, otherwise
  /// the main rear camera. Phones often list several rear lenses (wide, ultra-wide, zoom); a
  /// flip button must toggle front and rear, not walk through those.
  CameraDescription? get otherCamera {
    final current = selectedCamera;
    if (current == null || cameras.length < 2) return null;
    final front = current.lensDirection != CameraLensDirection.front;
    final hasBoth =
        cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
        cameras.any((c) => c.lensDirection == CameraLensDirection.back);
    if (hasBoth) {
      for (final camera in cameras) {
        if ((camera.lensDirection == CameraLensDirection.front) == front &&
            camera.lensDirection != CameraLensDirection.external) {
          return camera;
        }
      }
    }
    // Laptops and USB webcams have no front / rear: step to the next camera in the list.
    final at = cameras.indexOf(current);
    return cameras[(at + 1) % cameras.length];
  }

  bool get canSwitch => otherCamera != null;
  bool get usingFront => selectedCamera?.lensDirection == CameraLensDirection.front;

  /// A phone-style front / rear pair, as opposed to a list of webcams.
  bool get hasFrontRear =>
      cameras.any((c) => c.lensDirection == CameraLensDirection.front) &&
      cameras.any((c) => c.lensDirection == CameraLensDirection.back);

  Future<void> selectCamera(CameraDescription choice) async {
    if (busy ||
        recording ||
        clip != null ||
        !cameras.contains(choice) ||
        selectedCamera == choice)
      return;
    final old = controller;
    controller = null;
    ready = false;
    selectedCamera = choice;
    controlMessage = null;
    epoch++;
    busy = true;
    emit();
    final generation = epoch;
    try {
      _stopWebFraming(release: false);
      await _stopPreviewAnalysis(old);
      await _release(old);
    } finally {
      if (epoch == generation) busy = false;
    }
    if (epoch == generation && !disposed) await initialize();
    if (!enrollmentGuidance && ready) rememberedClassroomCamera = choice.name;
  }

  Future<void> start(List<String> order) async {
    if (busy || recording || !ready) return;
    final generation = epoch;
    busy = true;
    emit();
    try {
      await _stopPreviewAnalysis(controller);
      if (enrollmentGuidance && !kIsWeb) await lockPortraitCapture();
      await discard();
      if (disposed || generation != epoch) return;
      guidance?.removeListener(emit);
      guidance?.dispose();
      guidance = enrollmentGuidance
          ? (PoseGuidance(order: order)..addListener(emit))
          : null;
      poses = List.of(order);
      elapsed = 0;
      _lastAnalysis = null;
      faceTracker.clear();
      error = null;
      if (kIsWeb && enrollmentGuidance) {
        recording = true;
        busy = false;
        emit();
        final value = await browser.recordInBrowser(order, guidance!);
        if (disposed || generation != epoch) {
          if (value != null) await files.remove(value.path);
          return;
        }
        recording = false;
        clip = value;
        if (value == null) error = 'Recording stopped. You can try again.';
      } else {
        final activeController = controller!;
        var startedWithFrames = false;
        if (!kIsWeb && analyzerFactory != null) {
          try {
            analyzer = analyzerFactory!(activeController);
            await activeController.startVideoRecording(
              onAvailable: _analyzeFrame,
            );
            startedWithFrames = true;
          } catch (_) {
            final failed = analyzer;
            analyzer = null;
            await _closeAnalyzer(failed);
            if (!disposed && generation == epoch) {
              // Preview observations are no longer receiving frames. Do not
              // leave a recently-green guide frozen while recording continues.
              guidance?.unavailable(DateTime.now(), force: true);
            }
          }
        }
        if (disposed || generation != epoch) return;
        if (!startedWithFrames && !activeController.value.isRecordingVideo) {
          await activeController.startVideoRecording();
        }
        if (disposed || generation != epoch) {
          try {
            if (activeController.value.isRecordingVideo) {
              final abandoned = await activeController.stopVideoRecording();
              await files.remove(abandoned.path);
            }
          } catch (_) {}
          return;
        }
        recording = true;
        _recordingClock
          ..reset()
          ..start();
        timer = Timer.periodic(const Duration(milliseconds: 250), (_) {
          final seconds = _recordingClock.elapsed.inSeconds;
          if (seconds == elapsed) return;
          elapsed = seconds;
          if (elapsed >= 2) guidance?.unavailable(DateTime.now());
          emit();
          if (elapsed >= (enrollmentGuidance ? enrollmentMaximumSeconds : segmentSeconds) ||
              (enrollmentGuidance &&
                  elapsed >= enrollmentStopSeconds &&
                  (guidance?.allCaptured ?? false))) {
            timer?.cancel();
            unawaited(stop());
          }
        });
      }
    } catch (failure) {
      if (!disposed && generation == epoch) {
        final detail = failure.toString().toLowerCase();
        error =
            kIsWeb &&
                (detail.contains('notallowed') ||
                    detail.contains('permission denied'))
            ? 'Camera access was denied. Allow it in your browser settings and retry.'
            : 'Recording could not start. Check camera access and retry.';
        recording = false;
      }
    } finally {
      if (generation == epoch) busy = false;
      emit();
    }
  }

  void _analyzeFrame(CameraImage frame) {
    if ((!recording && !_previewAnalyzing) || _analysisBusy || analyzer == null)
      return;
    final now = DateTime.now();
    final active = analyzer!;
    final generation = epoch;
    if (_lastAnalysis != null &&
        now.difference(_lastAnalysis!) < const Duration(milliseconds: 200))
      return;
    _lastAnalysis = now;
    _analysisBusy = true;
    _pendingAnalysis = () async {
      try {
        final result = await active.analyze(frame);
        if (result == null ||
            (!recording && !_previewAnalyzing) ||
            epoch != generation ||
            !identical(active, analyzer))
          return;
        guidance?.observe(result, allowCompletion: recording);
        if (!enrollmentGuidance) {
          final remaining =
              const Duration(seconds: 1) -
              DateTime.now().difference(result.timestamp);
          if (remaining <= Duration.zero) return;
          faceTracker.observe(result);
          _faceExpiry?.cancel();
          _faceExpiry = Timer(remaining, faceTracker.clear);
        }
      } catch (_) {
        if ((recording || _previewAnalyzing) &&
            epoch == generation &&
            identical(active, analyzer)) {
          guidance?.unavailable(DateTime.now().add(const Duration(seconds: 3)));
        }
      } finally {
        _analysisBusy = false;
      }
    }();
    unawaited(_pendingAnalysis);
  }

  Future<void> stop({int minimumSeconds = 10}) async {
    if (!recording || busy || (kIsWeb && enrollmentGuidance)) return;
    timer?.cancel();
    _recordingClock.stop();
    elapsed = _recordingClock.elapsed.inSeconds;
    _faceExpiry?.cancel();
    faceTracker.clear();
    busy = true;
    recording = false;
    final generation = epoch;
    final oldAnalyzer = analyzer;
    analyzer = null;
    try {
      final current = controller!;
      final value = await current.stopVideoRecording();
      if (current.value.flashMode == FlashMode.torch) {
        try {
          await current.setFlashMode(FlashMode.off);
        } catch (_) {}
      }
      if (disposed ||
          generation != epoch ||
          elapsed <
              (enrollmentGuidance ? enrollmentStopSeconds : minimumSeconds)) {
        await files.remove(value.path);
        error = enrollmentGuidance
            ? 'Keep recording until the guided capture finishes automatically.'
            : 'Record for at least $minimumSeconds seconds before stopping.';
      } else {
        clip = value;
      }
    } catch (_) {
      error = 'Recording was interrupted. Please record again.';
    } finally {
      try {
        await _pendingAnalysis;
        await _closeAnalyzer(oldAnalyzer);
      } finally {
        if (generation == epoch) {
          busy = false;
          emit();
          // Keep classroom framing feedback alive while upload backpressure
          // pauses the next segment. Student challenge analysis stays stopped.
          if (!enrollmentGuidance && ready && !disposed) {
            await startPreviewAnalysis();
          }
        }
      }
    }
  }

  /// Transfer ownership to a bounded upload queue without deleting the file.
  XFile? takeClip() {
    final value = clip;
    clip = null;
    return value;
  }

  Future<void> discard() async {
    interrupted = false;
    final old = clip;
    clip = null;
    if (old != null) await files.remove(old.path);
    emit();
  }

  /// A stopped CameraX or browser recording can leave its preview on the last
  /// frame. Release that camera before opening a fresh preview for a retake.
  Future<void> retake() async {
    if (busy || recording || clip == null) return;
    await interrupt();
    await discard();
    if (!disposed) await initialize();
  }

  /// Releases the camera. Only a [lifecycle] pause (app backgrounded) asks to be reopened
  /// on return; every other caller leaves the camera closed on purpose.
  Future<void> interrupt({bool lifecycle = false}) async {
    final generation = ++epoch;
    timer?.cancel();
    _recordingClock.stop();
    _faceExpiry?.cancel();
    faceTracker.clear();
    _stopWebFraming();
    final old = controller;
    final wasRecording = recording;
    interrupted = lifecycle && !disposed && (ready || busy);
    if (lifecycle && !disposed) {
      onEvent?.call('camera_interrupted', code: wasRecording ? 'recording_lost' : 'paused');
    }
    if (lifecycle && wasRecording && !disposed) {
      error = 'The recording was interrupted when the app left the screen. Record again.';
    }
    busy = true;
    ready = false;
    recording = false;
    await _stopPreviewAnalysis(old);
    final oldAnalyzer = analyzer;
    controller = null;
    analyzer = null;
    recording = false;
    ready = false;
    busy = true;
    guidance?.removeListener(emit);
    guidance?.dispose();
    guidance = null;
    emit();
    try {
      if (kIsWeb && enrollmentGuidance) browser.cancelBrowserRecording();
      if (wasRecording && old != null) {
        try {
          final file = await old.stopVideoRecording();
          await files.remove(file.path);
        } catch (_) {}
      }
      try {
        await _pendingAnalysis;
        await _closeAnalyzer(oldAnalyzer);
      } finally {
        await _release(old);
      }
    } finally {
      if (generation == epoch) {
        busy = false;
        emit();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    timer?.cancel();
    _deviceDebounce?.cancel();
    _stopDeviceWatch?.call();
    _stopDeviceWatch = null;
    unawaited(interrupt());
    faceTracker.dispose();
    super.dispose();
  }
}
