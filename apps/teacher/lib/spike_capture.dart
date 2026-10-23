import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

export 'video_type_stub.dart'
    if (dart.library.js_interop) 'video_type_web.dart';

abstract class CameraGateway {
  Future<void> initialize();
  Future<void> start();
  Future<XFile> stop();
  Future<void> release();
  Widget preview();
}

class PluginCameraGateway implements CameraGateway {
  CameraController? _controller;
  @override
  Future<void> initialize() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw CameraException('NoCamera', 'No camera is available.');
    }
    final next = CameraController(
      cameras.first,
      ResolutionPreset.high,
      enableAudio: false,
    );
    _controller = next;
    await next.initialize();
  }

  @override
  Future<void> start() => _controller!.startVideoRecording();
  @override
  Future<XFile> stop() => _controller!.stopVideoRecording();
  @override
  Widget preview() => CameraPreview(_controller!);
  @override
  Future<void> release() async {
    final previous = _controller;
    _controller = null;
    await previous?.dispose();
  }
}

class CaptureSession extends ChangeNotifier {
  CaptureSession(this.gateway, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;
  final CameraGateway gateway;
  final DateTime Function() clock;
  bool ready = false, busy = false, recording = false, consent = false;
  bool _disposed = false;
  int _epoch = 0;
  String mode = 'enrollment';
  String? error;
  XFile? clip;
  String clipMode = 'enrollment', captureId = '';
  int elapsed = 0, recordedSeconds = 0;
  List<String> poses = [], recordedPoses = [];
  DateTime? _started;
  Timer? _timer;
  String get prompt => mode == 'classroom'
      ? 'Everyone face the camera'
      : poses.isEmpty
      ? 'Look forward'
      : 'Look ${poses[min(elapsed ~/ 3, 4)]}';
  void emit() {
    if (!_disposed) notifyListeners();
  }

  void setConsent(bool? value) {
    consent = value ?? false;
    emit();
  }

  void changeMode(String value) {
    if (recording || busy || !{'enrollment', 'classroom'}.contains(value)) {
      return;
    }
    mode = value;
    emit();
  }

  Future<void> initialize() async {
    if (busy || ready) return;
    busy = true;
    error = null;
    final epoch = ++_epoch;
    emit();
    try {
      await gateway.initialize();
      if (!_disposed && epoch == _epoch) {
        ready = true;
      } else {
        await gateway.release();
      }
    } catch (_) {
      await gateway.release();
      if (epoch == _epoch) error = 'Camera unavailable. Check browser permission and close other camera apps.';
    } finally {
      if (epoch == _epoch) busy = false;
      emit();
    }
  }

  Future<void> start() async {
    if (!ready || busy || recording || !consent) return;
    busy = true;
    error = null;
    clip = null;
    final epoch = _epoch;
    emit();
    try {
      await gateway.start();
      if (_disposed || epoch != _epoch) return;
      poses = [
        'front',
        ...(['up', 'down', 'left', 'right']..shuffle(Random.secure())),
      ];
      elapsed = 0;
      _started = clock();
      recording = true;
      captureId = _started!.toUtc().millisecondsSinceEpoch.toString();
      _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
        elapsed = max(0, clock().difference(_started!).inSeconds);
        if (elapsed >= (mode == 'enrollment' ? 15 : 10)) unawaited(stop());
        emit();
      });
    } catch (_) {
      error = 'Could not start recording. Re-enable the camera and try again.';
    } finally {
      if (epoch == _epoch) busy = false;
      emit();
    }
  }

  Future<void> stop() async {
    if (!recording || busy) return;
    final epoch = _epoch;
    busy = true;
    recording = false;
    _timer?.cancel();
    recordedSeconds = clock().difference(_started!).inSeconds;
    emit();
    try {
      final result = await gateway.stop();
      if (_disposed || epoch != _epoch) return;
      if (recordedSeconds < (mode == 'enrollment' ? 15 : 5)) {
        error = 'Recording too short. Re-record the full guided sequence.';
      } else {
        clip = result;
        clipMode = mode;
        recordedPoses = mode == 'enrollment' ? List.of(poses) : [];
      }
    } catch (_) {
      if (epoch == _epoch) error = 'Recording interrupted. Please re-record.';
    } finally {
      if (epoch == _epoch) busy = false;
      emit();
    }
  }

  void clearClip() {
    clip = null;
    emit();
  }

  Future<void> close({bool interrupted = false}) async {
    ++_epoch;
    _timer?.cancel();
    recording = false;
    ready = false;
    busy = false;
    if (interrupted) {
      clip = null;
      error = 'Recording interrupted. Please re-record.';
    }
    await gateway.release();
    emit();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    unawaited(gateway.release());
    super.dispose();
  }
}
