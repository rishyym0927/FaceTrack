import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A local, advisory observation. It is never sent to the enrolment API.
@immutable
class PoseObservation {
  const PoseObservation({
    required this.timestamp,
    required this.faceCount,
    this.bounds,
    this.yaw,
    this.pitch,
    this.luminance,
    this.trackedFaces = const [],
  });

  final List<({int? id, Rect bounds, bool framed})> trackedFaces;
  final DateTime timestamp;
  final int faceCount;
  final Rect? bounds; // Normalized, unmirrored camera coordinates.
  final double? yaw; // Degrees, positive toward the subject's right.
  final double? pitch; // Degrees, positive upward.
  final double? luminance; // 0..255 approximate frame brightness.
}

class PoseGuidance extends ChangeNotifier {
  PoseGuidance({required List<String> order})
    : order = List.unmodifiable(order);

  final List<String> order;
  final Set<String> completed = {};
  String hint = 'Position your face inside the guide';
  Rect? faceBounds;
  bool faceFramed = false;
  DateTime? _holdStarted;
  DateTime? _lastObservation;
  int _acceptedFrames = 0;

  String? get current =>
      completed.length < order.length ? order[completed.length] : null;
  bool get analysisUnavailable => hint.startsWith('Live guidance unavailable');
  bool get poseAligned => hint == 'Hold still…';
  bool get allCaptured => completed.length == order.length;

  void observe(PoseObservation value) {
    _lastObservation = value.timestamp;
    faceBounds = value.faceCount == 1 ? value.bounds : null;
    final bounds = faceBounds;
    faceFramed =
        bounds != null &&
        bounds.width >= .20 &&
        bounds.center.dx >= .23 &&
        bounds.center.dx <= .77 &&
        bounds.center.dy >= .20 &&
        bounds.center.dy <= .80 &&
        (value.luminance == null || value.luminance! >= 45);
    String nextHint;
    if (value.faceCount == 0) {
      nextHint = 'Move your face into view';
    } else if (value.faceCount > 1) {
      nextHint = 'Only one person should be visible';
    } else if (bounds == null ||
        bounds.width < .20 ||
        bounds.center.dx < .23 ||
        bounds.center.dx > .77 ||
        bounds.center.dy < .20 ||
        bounds.center.dy > .80) {
      nextHint = 'Move closer and center your face';
    } else if (value.luminance != null && value.luminance! < 45) {
      nextHint = 'Improve lighting on your face';
    } else if (current == null) {
      nextHint = 'All directions captured';
    } else if (value.yaw == null || value.pitch == null) {
      nextHint = 'Keep your face visible';
    } else if (!_matches(current!, value.yaw!, value.pitch!)) {
      nextHint = 'Look $current';
    } else {
      nextHint = 'Hold still…';
    }

    if (nextHint == 'Hold still…') {
      if (_holdStarted == null ||
          value.timestamp.difference(_holdStarted!) >
              const Duration(seconds: 2)) {
        _holdStarted = value.timestamp;
        _acceptedFrames = 0;
      }
      _acceptedFrames++;
      if (_acceptedFrames >= 2 &&
          value.timestamp.difference(_holdStarted!) >=
              const Duration(milliseconds: 450)) {
        completed.add(current!);
        _holdStarted = null;
        _acceptedFrames = 0;
        nextHint = current == null
            ? 'All directions captured'
            : 'Pose captured. Look $current';
      }
    } else {
      _holdStarted = null;
      _acceptedFrames = 0;
    }
    hint = nextHint;
    notifyListeners();
  }

  void unavailable(DateTime now) {
    if (_lastObservation == null ||
        now.difference(_lastObservation!) > const Duration(seconds: 2)) {
      if (analysisUnavailable) return;
      _holdStarted = null;
      _acceptedFrames = 0;
      faceBounds = null;
      faceFramed = false;
      hint =
          'Live guidance unavailable; follow the prompts and review your video';
      notifyListeners();
    }
  }

  bool _matches(String pose, double yaw, double pitch) {
    if (!yaw.isFinite || !pitch.isFinite) return false;
    switch (pose) {
      case 'front':
        return yaw.abs() <= 13 && pitch.abs() <= 13;
      case 'left':
        return yaw <= -18 && yaw >= -55 && pitch.abs() <= 30;
      case 'right':
        return yaw >= 18 && yaw <= 55 && pitch.abs() <= 30;
      case 'up':
        return pitch >= 13 && pitch <= 45 && yaw.abs() <= 30;
      case 'down':
        return pitch <= -13 && pitch >= -45 && yaw.abs() <= 30;
      default:
        return false;
    }
  }

  double get progress =>
      order.isEmpty ? 0 : math.min(1, completed.length / order.length);
}
