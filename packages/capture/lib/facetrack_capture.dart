export 'package:camera/camera.dart' show XFile;

export 'src/guided_camera.dart';
export 'src/pose_guidance.dart';
export 'src/pose_analyzer.dart';
export 'src/playback.dart';
export 'src/pending.dart';
export 'src/upload.dart';
export 'src/orientation.dart';
export 'src/device_face_analyzer_stub.dart'
    if (dart.library.io) 'src/device_face_analyzer_io.dart';
export 'src/live_preview.dart';
export 'src/classroom_browser_stub.dart'
    if (dart.library.js_interop) 'src/classroom_browser_web.dart';

export 'src/owned_clip.dart';
