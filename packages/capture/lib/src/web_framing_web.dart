import 'dart:convert';
import 'dart:js_interop';

import 'framing.dart';

@JS('FaceTrackClassroom.startDetector')
external JSPromise<JSBoolean> _start();
@JS('FaceTrackClassroom.stopDetector')
external void _stop();
@JS('FaceTrackClassroom.detect')
external JSString _detect();
@JS('FaceTrackClassroom.guardUnload')
external void _guard(JSBoolean on);
@JS('FaceTrackClassroom.onDeviceChange')
external JSFunction _watch(JSFunction callback);

/// Loads the browser face detector. False when it cannot load: the scan still works, only
/// the live boxes are missing.
Future<bool> startWebFraming() async {
  try {
    return (await _start().toDart).toDart;
  } catch (_) {
    return false;
  }
}

void stopWebFraming() {
  try {
    _stop();
  } catch (_) {}
}

FramingReading readWebFraming() {
  try {
    return FramingReading.fromJson(
      jsonDecode(_detect().toDart) as Map<String, dynamic>,
    );
  } catch (_) {
    return const FramingReading();
  }
}

/// Warns before the tab is closed while unsent video is held in memory.
void guardWebUnload(bool on) {
  try {
    _guard(on.toJS);
  } catch (_) {}
}

/// Calls [onChange] when a camera is plugged in or removed. Returns the function that stops it.
void Function() watchWebDevices(void Function() onChange) {
  try {
    final stop = _watch(onChange.toJS);
    return () {
      try {
        stop.callAsFunction();
      } catch (_) {}
    };
  } catch (_) {
    return () {};
  }
}
