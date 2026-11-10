import 'dart:js_interop';
import 'package:camera/camera.dart';

@JS('FaceTrackClassroom.scan')
external JSPromise<JSAny?> _scan(JSFunction onSegment, JSFunction onStarted);
@JS('FaceTrackClassroom.cancel')
external void cancelBrowserClassroomScan();
@JS('FaceTrackClassroom.status')
external void _status(JSString message);

void updateBrowserClassroomStatus(String message) => _status(message.toJS);

Future<void> scanClassroomInBrowser({
  required Future<void> Function(XFile) onSegment,
  required void Function() onStarted,
}) async {
  JSPromise<JSAny?> segment(JSString path) => (() async {
    await onSegment(XFile(path.toDart, mimeType: 'video/webm'));
    return null;
  })().toJS;
  await _scan(segment.toJS, onStarted.toJS).toDart;
}
