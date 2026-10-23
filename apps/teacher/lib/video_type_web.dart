import 'dart:js_interop';

import 'package:camera/camera.dart';
import 'package:web/web.dart' as web;

Future<String> videoExtension(XFile file) async {
  final response = await web.window.fetch(file.path.toJS).toDart;
  final blob = await response.blob().toDart;
  if (blob.type.contains('mp4')) return 'mp4';
  if (blob.type.contains('webm')) return 'webm';
  throw StateError('Unsupported recording format');
}
