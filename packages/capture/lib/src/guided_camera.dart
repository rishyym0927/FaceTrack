import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'browser_capture_stub.dart'
    if (dart.library.js_interop) 'browser_capture_web.dart'
    as browser;
import 'files_stub.dart'
    if (dart.library.io) 'files_io.dart'
    if (dart.library.js_interop) 'files_web.dart'
    as files;
import 'pose_analyzer.dart';
import 'pose_guidance.dart';

CameraDescription preferredCamera(
  List<CameraDescription> cameras, {
  required bool enrollment,
}) => cameras.firstWhere(
  (camera) =>
      camera.lensDirection ==
      (enrollment ? CameraLensDirection.front : CameraLensDirection.back),
  orElse: () => cameras.first,
);

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

  final bool enrollmentGuidance;
  final PoseFrameAnalyzer Function(CameraController)? analyzerFactory;
  CameraController? controller;
  List<CameraDescription> cameras = [];
  CameraDescription? selectedCamera;
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
    await old.dispose();
  }

  bool recording = false, busy = false, disposed = false, ready = false;
  bool _analysisBusy = false, _previewAnalyzing = false;
  Future<void>? _pendingAnalysis;
  Timer? _previewExpiry;
  DateTime? _lastAnalysis;
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

  Future<void> initialize() async {
    if (busy || ready) return;
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
        );
      }
      next = CameraController(
        selectedCamera!,
        ResolutionPreset.high,
        enableAudio: false,
        fps: enrollmentGuidance ? 24 : null,
        videoBitrate: enrollmentGuidance ? 4000000 : null,
        imageFormatGroup: analyzerFactory != null && !kIsWeb
            ? ImageFormatGroup.nv21
            : null,
      );
      await next.initialize();
      if (disposed || generation != epoch) {
        await next.dispose();
        return;
      }
      controller = next;
      ready = true;
      if (enrollmentGuidance && !kIsWeb) await lockPortraitCapture();
      await startPreviewAnalysis();
    } catch (_) {
      await next?.dispose();
      if (!disposed && generation == epoch) error = 'Camera unavailable. Allow camera access, close other camera apps and retry.';
    } finally {
      if (generation == epoch) busy = false;
      emit();
    }
  }

  /// Framing feedback before recording never completes challenge poses.
  Future<void> startPreviewAnalysis() async {
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
      _previewExpiry = Timer.periodic(const Duration(milliseconds: 500), (_) {
        guidance?.unavailable(DateTime.now());
        faceTracker.expire(DateTime.now());
      });
    } catch (_) {
      if (generation == epoch) {
        await _stopPreviewAnalysis(current);
        guidance?.unavailable(DateTime.now());
      }
    }
  }

  Future<void> _stopPreviewAnalysis(CameraController? current) async {
    if (!_previewAnalyzing) return;
    _previewAnalyzing = false;
    _previewExpiry?.cancel();
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
      await _stopPreviewAnalysis(old);
      await _release(old);
    } finally {
      if (epoch == generation) busy = false;
    }
    if (epoch == generation && !disposed) await initialize();
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
        timer = Timer.periodic(const Duration(seconds: 1), (_) {
          elapsed++;
          if (elapsed >= 2) guidance?.unavailable(DateTime.now());
          emit();
          if (elapsed >= (enrollmentGuidance ? 25 : 15) ||
              (enrollmentGuidance &&
                  elapsed >= 10 &&
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
      if (disposed || generation != epoch || elapsed < minimumSeconds) {
        await files.remove(value.path);
        error = 'Record the full guided video.';
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

  Future<void> interrupt() async {
    final generation = ++epoch;
    timer?.cancel();
    _faceExpiry?.cancel();
    faceTracker.clear();
    final old = controller;
    final wasRecording = recording;
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
    unawaited(interrupt());
    faceTracker.dispose();
    super.dispose();
  }
}
