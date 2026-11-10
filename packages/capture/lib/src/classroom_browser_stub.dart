import 'package:camera/camera.dart';

Future<void> scanClassroomInBrowser({
  required Future<void> Function(XFile) onSegment,
  required void Function() onStarted,
}) => throw UnsupportedError('Browser classroom scanning is unavailable.');

void cancelBrowserClassroomScan() {}
void updateBrowserClassroomStatus(String message) {}
