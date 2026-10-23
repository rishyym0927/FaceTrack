import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'browser_capture_stub.dart'
    if (dart.library.js_interop) 'browser_capture_web.dart'
    as browser;
import 'files_stub.dart'
    if (dart.library.io) 'files_io.dart'
    if (dart.library.js_interop) 'files_web.dart'
    as files;
import 'pose_analyzer.dart';
import 'pose_guidance.dart';

class GuidedCamera extends ChangeNotifier {
  GuidedCamera({this.enrollmentGuidance = false, this.analyzerFactory});

  final bool enrollmentGuidance;
  final PoseFrameAnalyzer Function(CameraController)? analyzerFactory;
  CameraController? controller;
  PoseFrameAnalyzer? analyzer;
  PoseGuidance? guidance;
  Timer? timer;
  bool recording = false, busy = false, disposed = false, ready = false;
  bool _analysisBusy = false;
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
      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      next = CameraController(
        front.isEmpty ? cameras.first : front.first,
        ResolutionPreset.high,
        enableAudio: false,
        fps: enrollmentGuidance ? 24 : null,
        videoBitrate: enrollmentGuidance ? 4000000 : null,
        imageFormatGroup: enrollmentGuidance && !kIsWeb
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
    } catch (_) {
      await next?.dispose();
      if (!disposed && generation == epoch) error = 'Camera unavailable. Allow camera access, close other camera apps and retry.';
    } finally {
      if (generation == epoch) busy = false;
      emit();
    }
  }

  Future<void> start(List<String> order) async {
    if (busy || recording || !ready) return;
    final generation = epoch;
    busy = true;
    emit();
    try {
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
        if (enrollmentGuidance && analyzerFactory != null) {
          try {
            analyzer = analyzerFactory!(activeController);
            await activeController.startVideoRecording(
              onAvailable: _analyzeFrame,
            );
            startedWithFrames = true;
          } catch (_) {
            final failed = analyzer;
            analyzer = null;
            if (failed != null) await failed.close();
            if (!disposed && generation == epoch) {
              guidance?.unavailable(DateTime.now());
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
          guidance?.unavailable(DateTime.now());
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
    if (!recording || _analysisBusy || analyzer == null) return;
    final now = DateTime.now();
    if (_lastAnalysis != null &&
        now.difference(_lastAnalysis!) < const Duration(milliseconds: 170))
      return;
    _lastAnalysis = now;
    _analysisBusy = true;
    unawaited(() async {
      try {
        final result = await analyzer!.analyze(frame);
        if (result != null && recording) guidance?.observe(result);
      } catch (_) {
        if (recording)
          guidance?.unavailable(DateTime.now().add(const Duration(seconds: 3)));
      } finally {
        _analysisBusy = false;
      }
    }());
  }

  Future<void> stop() async {
    if (!recording || busy || (kIsWeb && enrollmentGuidance)) return;
    timer?.cancel();
    busy = true;
    recording = false;
    try {
      final value = await controller!.stopVideoRecording();
      if (disposed || elapsed < 10) {
        await files.remove(value.path);
        error = 'Record the full guided video.';
      } else {
        clip = value;
      }
    } catch (_) {
      error = 'Recording was interrupted. Please record again.';
    } finally {
      final oldAnalyzer = analyzer;
      analyzer = null;
      if (oldAnalyzer != null) await oldAnalyzer.close();
      busy = false;
      emit();
    }
  }

  Future<void> discard() async {
    final old = clip;
    clip = null;
    if (old != null) await files.remove(old.path);
    emit();
  }

  Future<void> interrupt() async {
    epoch++;
    timer?.cancel();
    if (kIsWeb && enrollmentGuidance) browser.cancelBrowserRecording();
    if (recording) {
      try {
        final file = await controller?.stopVideoRecording();
        if (file != null) await files.remove(file.path);
      } catch (_) {}
    }
    recording = false;
    busy = false;
    ready = false;
    final oldAnalyzer = analyzer;
    analyzer = null;
    if (oldAnalyzer != null) await oldAnalyzer.close();
    final old = controller;
    controller = null;
    await old?.dispose();
    guidance?.removeListener(emit);
    guidance?.dispose();
    guidance = null;
    emit();
  }

  @override
  void dispose() {
    disposed = true;
    timer?.cancel();
    unawaited(interrupt());
    super.dispose();
  }
}
