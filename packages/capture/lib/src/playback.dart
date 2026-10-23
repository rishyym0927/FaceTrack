import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'player_web.dart' if (dart.library.io) 'player_io.dart' as platform;

class ClipPlayback extends StatefulWidget {
  const ClipPlayback({super.key, this.file, this.url});
  final XFile? file;
  final String? url;
  @override
  State<ClipPlayback> createState() => _ClipPlaybackState();
}

class _ClipPlaybackState extends State<ClipPlayback> {
  VideoPlayerController? player;
  bool failed = false;
  @override
  void initState() {
    super.initState();
    initialize();
  }

  Future<void> initialize() async {
    final p = widget.url != null
        ? VideoPlayerController.networkUrl(Uri.parse(widget.url!))
        : platform.controller(widget.file!);
    player = p;
    try {
      await p.initialize();
      if (mounted) setState(() {});
    } catch (_) {
      if (mounted) setState(() => failed = true);
    }
  }

  @override
  void dispose() {
    player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = player;
    if (failed)
      return const Text(
        'Video could not load. Close and reopen review to refresh access.',
      );
    if (p == null || !p.value.isInitialized)
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    return Column(
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 380),
          child: AspectRatio(
            aspectRatio: p.value.aspectRatio,
            child: VideoPlayer(p),
          ),
        ),
        IconButton(
          tooltip: 'Play or pause video',
          onPressed: () async {
            p.value.isPlaying ? await p.pause() : await p.play();
            if (mounted) setState(() {});
          },
          icon: Icon(p.value.isPlaying ? Icons.pause : Icons.play_arrow),
        ),
      ],
    );
  }
}
