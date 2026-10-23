import 'dart:io';

import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';

VideoPlayerController controller(XFile file) =>
    VideoPlayerController.file(File(file.path));
