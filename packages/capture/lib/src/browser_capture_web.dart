import 'dart:convert';
import 'dart:js_interop';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'pose_guidance.dart';

@JS('FaceTrackCapture.record')
external JSPromise<JSString?> _record(
  JSArray<JSString> order,
  JSFunction onFrame,
);

@JS('FaceTrackCapture.cancel')
external void _cancel();

void cancelBrowserRecording() => _cancel();

Future<XFile?> recordInBrowser(
  List<String> order,
  PoseGuidance guidance,
) async {
  JSString onFrame(JSString encoded) {
    final data = jsonDecode(encoded.toDart) as Map<String, dynamic>;
    final bounds = data['bounds'] as List<dynamic>?;
    guidance.observe(
      PoseObservation(
        timestamp: DateTime.now(),
        faceCount: (data['faceCount'] as num?)?.toInt() ?? 0,
        bounds: bounds == null
            ? null
            : Rect.fromLTRB(
                (bounds[0] as num).toDouble(),
                (bounds[1] as num).toDouble(),
                (bounds[2] as num).toDouble(),
                (bounds[3] as num).toDouble(),
              ),
        yaw: (data['yaw'] as num?)?.toDouble(),
        pitch: (data['pitch'] as num?)?.toDouble(),
        luminance: (data['luminance'] as num?)?.toDouble(),
      ),
    );
    return jsonEncode({
      'hint': guidance.hint,
      'current': guidance.current,
      'completed': guidance.completed.toList(),
      'allCaptured': guidance.allCaptured,
      'bounds': guidance.faceBounds == null ? null : [
        guidance.faceBounds!.left, guidance.faceBounds!.top,
        guidance.faceBounds!.right, guidance.faceBounds!.bottom,
      ],
    }).toJS;
  }

  final result = await _record(
    order.map((p) => p.toJS).toList().toJS,
    onFrame.toJS,
  ).toDart;
  return result == null ? null : XFile(result.toDart, mimeType: 'video/webm');
}
