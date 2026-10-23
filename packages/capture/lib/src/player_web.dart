import 'package:camera/camera.dart';
import 'package:video_player/video_player.dart';

VideoPlayerController controller(XFile file) =>
    VideoPlayerController.networkUrl(Uri.parse(file.path));
