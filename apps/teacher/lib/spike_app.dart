import 'dart:async';
import 'dart:convert';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'spike_capture.dart';

void main() => runApp(const FaceTrackCaptureApp());

class FaceTrackCaptureApp extends StatelessWidget {
  const FaceTrackCaptureApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FaceTrack · Local capture',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176451)),
      scaffoldBackgroundColor: const Color(0xfff4f6f3),
    ),
    home: const CapturePage(),
  );
}

class CapturePage extends StatefulWidget {
  const CapturePage({super.key, this.session});
  final CaptureSession? session;
  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  late final session = widget.session ?? CaptureSession(PluginCameraGateway());
  final participant = TextEditingController(text: 'p01');
  String dataset = 'calibration';
  bool saving = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        (state == AppLifecycleState.inactive && session.recording)) {
      unawaited(session.close(interrupted: session.recording));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    participant.dispose();
    if (widget.session == null) session.dispose();
    super.dispose();
  }

  Future<void> save({required bool metadata}) async {
    if (!RegExp(r'^p[0-9]{2,4}$').hasMatch(participant.text)) {
      message('Use a pseudonymous ID such as p01.');
      return;
    }
    setState(() => saving = true);
    try {
      final clip = session.clip!;
      final extension = await videoExtension(clip);
      final split = session.clipMode == 'enrollment' ? 'reference' : dataset;
      final stem =
          '${session.clipMode}-${participant.text}-$split-${session.captureId}';
      if (metadata) {
        final data = {
          'schema_version': 1,
          'capture_id': session.captureId,
          'mode': session.clipMode,
          'participant_id': participant.text,
          'dataset': split,
          'duration_seconds': session.recordedSeconds,
          'pose_prompts': session.recordedPoses,
          'audio_enabled': false,
          'consent_confirmed': true,
          'pose_verification': 'human_review_required',
        };
        await XFile.fromData(
          utf8.encode(jsonEncode(data)),
          mimeType: 'application/json',
        ).saveTo('$stem.json');
      } else {
        final bytes = await clip.readAsBytes();
        final limit =
            (session.clipMode == 'enrollment' ? 25 : 50) * 1024 * 1024;
        if (bytes.length > limit) throw StateError('Clip too large');
        await XFile.fromData(
          bytes,
          mimeType: 'video/$extension',
        ).saveTo('$stem.$extension');
      }
      message(
        'Save to .local/spike/media. Delete any Downloads copies within 24 hours.',
      );
    } catch (_) {
      message('Could not save. Check browser downloads or re-record.');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  void message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1000),
          child: ListenableBuilder(
            listenable: session,
            builder: (context, _) => ListView(
              padding: const EdgeInsets.all(28),
              children: [
                const Text(
                  'FACETRACK / PHASE 01',
                  style: TextStyle(
                    letterSpacing: 2,
                    fontWeight: FontWeight.bold,
                    color: Color(0xff176451),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'A clear face. A better first test.',
                  style: Theme.of(context).textTheme.headlineLarge,
                ),
                const SizedBox(height: 10),
                const Text('Local capture · No audio · No cloud upload'),
                const SizedBox(height: 24),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(
                              value: 'enrollment',
                              label: Text('Face enrolment'),
                              icon: Icon(Icons.face),
                            ),
                            ButtonSegment(
                              value: 'classroom',
                              label: Text('Classroom test'),
                              icon: Icon(Icons.groups),
                            ),
                          ],
                          selected: {session.mode},
                          onSelectionChanged: session.recording || session.busy
                              ? null
                              : (values) => session.changeMode(values.first),
                        ),
                        const SizedBox(height: 16),
                        AspectRatio(
                          aspectRatio: 16 / 9,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: ColoredBox(
                              color: const Color(0xff172d27),
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (session.ready)
                                    session.gateway.preview()
                                  else
                                    const Center(
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.videocam_off_outlined,
                                            size: 48,
                                            color: Colors.white70,
                                          ),
                                          SizedBox(height: 12),
                                          Text(
                                            'Enable the camera when everyone is ready.',
                                            style: TextStyle(
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  if (session.recording)
                                    Align(
                                      alignment: Alignment.bottomCenter,
                                      child: Container(
                                        margin: const EdgeInsets.all(16),
                                        padding: const EdgeInsets.all(12),
                                        color: Colors.black87,
                                        child: Text(
                                          '${session.prompt} · ${session.elapsed}s',
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 22,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'Everyone recorded explicitly consents to this local test.',
                          ),
                          subtitle: const Text(
                            'Use pseudonymous IDs. This is not verified liveness.',
                          ),
                          value: session.consent,
                          onChanged: session.recording
                              ? null
                              : session.setConsent,
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                        if (session.error != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              session.error!,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            FilledButton.icon(
                              onPressed: session.busy
                                  ? null
                                  : !session.ready
                                  ? session.initialize
                                  : session.recording
                                  ? session.stop
                                  : !session.consent
                                  ? null
                                  : session.start,
                              icon: Icon(
                                session.recording
                                    ? Icons.stop
                                    : Icons.videocam_outlined,
                              ),
                              label: Text(
                                session.busy
                                    ? 'Please wait…'
                                    : session.recording
                                    ? 'Stop recording'
                                    : session.ready
                                    ? 'Start recording'
                                    : 'Enable camera',
                              ),
                            ),
                            if (session.ready)
                              OutlinedButton(
                                onPressed: session.busy
                                    ? null
                                    : () => session.close(
                                        interrupted: session.recording,
                                      ),
                                child: const Text('Turn camera off'),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          session.mode == 'enrollment'
                              ? '15 seconds: front, then four guided poses. Keep one face visible.'
                              : '10 seconds: keep all faces visible, look forward, and move slowly.',
                        ),
                      ],
                    ),
                  ),
                ),
                if (session.clip != null) ...[
                  const SizedBox(height: 20),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Review your recording',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 12),
                          ClipPlayback(file: session.clip!),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 16,
                            runSpacing: 12,
                            children: [
                              SizedBox(
                                width: 160,
                                child: TextField(
                                  controller: participant,
                                  decoration: const InputDecoration(
                                    labelText: 'Participant ID',
                                  ),
                                ),
                              ),
                              if (session.clipMode == 'classroom')
                                SizedBox(
                                  width: 190,
                                  child: DropdownButtonFormField<String>(
                                    initialValue: dataset,
                                    decoration: const InputDecoration(
                                      labelText: 'Keep data split',
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: 'calibration',
                                        child: Text('Calibration'),
                                      ),
                                      DropdownMenuItem(
                                        value: 'test',
                                        child: Text('Held-out test'),
                                      ),
                                    ],
                                    onChanged: (value) =>
                                        setState(() => dataset = value!),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              FilledButton.icon(
                                onPressed: saving
                                    ? null
                                    : () => save(metadata: false),
                                icon: const Icon(Icons.download),
                                label: const Text('Save video'),
                              ),
                              OutlinedButton(
                                onPressed: saving
                                    ? null
                                    : () => save(metadata: true),
                                child: const Text('Save metadata'),
                              ),
                              TextButton(
                                onPressed: saving ? null : session.clearClip,
                                child: const Text('Discard'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Save both files to .local/spike/media. Delete raw recordings within 24 hours.',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                const Text(
                  'Next: run scripts/spike on your saved clips. Actual recognition needs verified model permissions and a frozen experimental profile.',
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class ClipPlayback extends StatefulWidget {
  const ClipPlayback({super.key, required this.file});
  final XFile file;
  @override
  State<ClipPlayback> createState() => _ClipPlaybackState();
}

class _ClipPlaybackState extends State<ClipPlayback> {
  VideoPlayerController? player;
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  @override
  void didUpdateWidget(ClipPlayback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path) unawaited(load());
  }

  Future<void> load() async {
    final old = player;
    final next = VideoPlayerController.networkUrl(Uri.parse(widget.file.path));
    player = next;
    await old?.dispose();
    try {
      await next.initialize();
      if (mounted && player == next) setState(() => error = null);
    } catch (_) {
      if (mounted && player == next) {
        setState(
          () => error = 'Playback unavailable; review the saved file locally.',
        );
      }
    }
  }

  @override
  void dispose() {
    unawaited(player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = player;
    if (error != null) return Text(error!);
    if (current == null || !current.value.isInitialized) {
      return const Text('Loading playback…');
    }
    return Column(
      children: [
        SizedBox(
          height: 220,
          child: AspectRatio(
            aspectRatio: current.value.aspectRatio,
            child: VideoPlayer(current),
          ),
        ),
        IconButton(
          tooltip: 'Play or pause',
          icon: const Icon(Icons.play_arrow),
          onPressed: () =>
              current.value.isPlaying ? current.pause() : current.play(),
        ),
      ],
    );
  }
}
