import 'package:camera/camera.dart';

Future<String> videoExtension(XFile file) async =>
    file.mimeType?.contains('mp4') == true ? 'mp4' : 'webm';
