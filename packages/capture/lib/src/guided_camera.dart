import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'files_stub.dart'
    if (dart.library.io) 'files_io.dart'
    if (dart.library.js_interop) 'files_web.dart'
    as files;

class GuidedCamera extends ChangeNotifier {
  CameraController? controller;
  Timer? timer;
  bool recording = false, busy = false, disposed = false;
  int elapsed = 0, epoch = 0;
  List<String> poses = [];
  XFile? clip;
  String? error;
  void emit() {
    if (!disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (busy || controller != null) return;
    final generation = ++epoch;
    busy = true;
    error = null;
    emit();
    CameraController? next;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('No camera');
      final front = cameras.where(
        (c) => c.lensDirection == CameraLensDirection.front,
      );
      next = CameraController(
        front.isEmpty ? cameras.first : front.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await next.initialize();
      if (disposed || generation != epoch) {
        await next.dispose();
        return;
      }
      controller = next;
    } catch (_) {
      await next?.dispose();
      if (!disposed && generation == epoch) error = 'Camera unavailable. Allow camera access, close other camera apps and retry.';
    } finally {
      if (generation == epoch) busy = false;
      emit();
    }
  }

  Future<void> start(List<String> order) async {
    if (busy || recording || controller == null) return;
    await discard();
    poses = List.of(order);
    elapsed = 0;
    busy = true;
    emit();
    try {
      await controller!.startVideoRecording();
      if (disposed) return;
      recording = true;
      timer = Timer.periodic(const Duration(seconds: 1), (_) {
        elapsed++;
        emit();
        if (elapsed >= 15) {
          timer?.cancel();
          unawaited(stop());
        }
      });
    } catch (_) {
      error = 'Recording could not start. Retry camera access.';
    } finally {
      busy = false;
      emit();
    }
  }

  Future<void> stop() async {
    if (!recording || busy) return;
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
    if (recording) {
      try {
        final file = await controller?.stopVideoRecording();
        if (file != null) await files.remove(file.path);
      } catch (_) {}
    }
    recording = false;
    busy = false;
    final old = controller;
    controller = null;
    await old?.dispose();
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
