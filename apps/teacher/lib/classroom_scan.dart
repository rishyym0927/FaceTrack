import 'dart:async';

import 'package:camera/camera.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter/material.dart';

/// At most two complete segments are retained, including the active upload.
/// Camera capture pauses under backpressure; it never grows an unbounded queue.
class ClassroomScan extends ChangeNotifier {
  ClassroomScan(this.camera, this.upload) {
    camera.addListener(_cameraChanged);
  }
  final GuidedCamera camera;
  final Future<void> Function(XFile) upload;
  final List<XFile> _queue = [];
  bool scanning = false, sending = false, collecting = false, closed = false;
  String? error;
  int submitted = 0;
  int get pending => _queue.length;
  bool get finishing =>
      !scanning && (camera.recording || pending > 0 || sending);
  bool get canLeave =>
      !scanning && !camera.recording && pending == 0 && !sending;
  void _emit() {
    if (!closed) notifyListeners();
  }

  Future<void> start() async {
    if (closed || scanning || camera.busy || error != null) return;
    scanning = true;
    _emit();
    await camera.initialize();
    if (!camera.ready) {
      scanning = false;
      error = camera.error ?? 'Camera unavailable. Please retry.';
      _emit();
      return;
    }
    await _next();
  }

  Future<void> _next() async {
    if (closed ||
        !scanning ||
        error != null ||
        pending >= 2 ||
        camera.recording ||
        camera.busy) {
      return;
    }
    await camera.start(const []);
    if (!camera.recording && camera.clip == null && camera.error != null) {
      scanning = false;
      error = camera.error;
    }
    _emit();
  }

  void _cameraChanged() {
    if (closed) return;
    if (camera.clip != null && !camera.busy && !collecting) {
      unawaited(_collect());
    }
    _emit();
  }

  Future<void> _collect() async {
    collecting = true;
    final file = camera.takeClip();
    if (file != null) _queue.add(file);
    collecting = false;
    _emit();
    unawaited(_send());
    await _next();
  }

  Future<void> _send() async {
    if (sending || closed || error != null || _queue.isEmpty) return;
    sending = true;
    _emit();
    try {
      while (_queue.isNotEmpty && !closed) {
        final file = _queue.first;
        await upload(file);
        _queue.removeAt(0);
        submitted++;
        try {
          await removeOwnedClip(file.path);
        } catch (_) {
          /* Uploaded private media cleanup can retry on OS cache eviction. */
        }
        _emit();
        await _next();
      }
    } catch (_) {
      error = 'Upload paused. Your captured segment is kept here. Check your connection and retry.';
      scanning = false;
      // Keep an active capture until its normal boundary so it is not lost.
    } finally {
      sending = false;
      _emit();
    }
  }

  Future<void> stop() async {
    scanning = false;
    _emit();
    // Finish a short segment at the normal boundary; existing decoder minimum
    // and temporal corroboration are preserved.
    if (camera.recording && camera.elapsed >= 10) await camera.stop();
  }

  Future<void> retry() async {
    error = null;
    _emit();
    await _send();
  }

  Future<void> discardPending() async {
    if (sending) return;
    scanning = false;
    await camera.interrupt();
    final remaining = [..._queue];
    _queue.clear();
    for (final file in remaining) {
      await removeOwnedClip(file.path);
    }
    await camera.discard();
    error = null;
    _emit();
  }

  @override
  void dispose() {
    closed = true;
    camera.removeListener(_cameraChanged);
    super.dispose();
  }
}

class ClassroomScanPage extends StatefulWidget {
  const ClassroomScanPage({
    super.key,
    required this.scan,
    required this.suggestions,
  });
  final ClassroomScan scan;
  final Future<List<String>> Function() suggestions;
  @override
  State<ClassroomScanPage> createState() => _ClassroomScanPageState();
}

class _ClassroomScanPageState extends State<ClassroomScanPage> {
  Timer? poll;
  List<String> names = [];
  AppLifecycleListener? lifecycle;
  bool fetching = false;
  ClassroomScan get scan => widget.scan;
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(
      onPause: () async {
        scan.scanning = false;
        await scan.camera.interrupt();
      },
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => scan.camera.initialize(),
    );
    unawaited(_refresh());
    poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (fetching) return;
    fetching = true;
    try {
      final value = await widget.suggestions();
      if (mounted) setState(() => names = value);
    } catch (_) {
      /* Keep the last confirmed server suggestions. */
    } finally {
      fetching = false;
    }
  }

  Future<void> _close() async {
    if (!scan.canLeave) {
      await scan.stop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Finishing the scan and uploading captured segments.',
            ),
          ),
        );
      }
      return;
    }
    await scan.camera.interrupt();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    poll?.cancel();
    lifecycle?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: scan,
    builder: (context, _) {
      final camera = scan.camera;
      return PopScope(
        canPop: scan.canLeave,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (camera.controller != null)
                  ListenableBuilder(
                    listenable: camera.faceTracker,
                    builder: (context, _) => LiveCameraPreview(
                      camera: camera.controller!,
                      faces: camera.faceTracker.faces,
                      onFocus: (point) => camera.focus(point),
                    ),
                  ),
                Align(
                  alignment: Alignment.topCenter,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.black.withValues(alpha: .7),
                    child: Row(
                      children: [
                        IconButton(
                          onPressed: _close,
                          tooltip: 'Close camera',
                          icon: const Icon(Icons.close, color: Colors.white),
                        ),
                        const Expanded(
                          child: Text(
                            'Scan classroom',
                            style: TextStyle(color: Colors.white, fontSize: 22),
                          ),
                        ),
                        IconButton(
                          onPressed: camera.busy ? null : camera.toggleTorch,
                          tooltip: 'Toggle torch',
                          icon: const Icon(
                            Icons.flashlight_on,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * .45,
                    ),
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                    decoration: BoxDecoration(
                      color: const Color(0xff102e28).withValues(alpha: .94),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(28),
                      ),
                      border: Border(
                        top: BorderSide(
                          color: Colors.white.withValues(alpha: .12),
                        ),
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 42,
                            height: 4,
                            margin: const EdgeInsets.only(bottom: 14),
                            decoration: BoxDecoration(
                              color: Colors.white38,
                              borderRadius: BorderRadius.circular(20),
                            ),
                          ),
                          Text(
                            names.isEmpty
                                ? scan.scanning
                                      ? 'Scanning the room'
                                      : 'Ready to scan your classroom'
                                : '${names.length} students suggested',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (names.isNotEmpty)
                            Text(
                              names.join(', '),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white),
                            ),
                          const Text(
                            'Move across the room, then tap Stop scan. Green boxes mean well framed. Student suggestions appear after each short segment is processed; review them before publishing.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white70),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _ScanStatusPill(
                                icon: camera.recording
                                    ? Icons.videocam_outlined
                                    : Icons.videocam_off_outlined,
                                label: camera.recording
                                    ? 'Recording · ${camera.elapsed} / 15 sec segment'
                                    : scan.scanning
                                    ? 'Waiting for uploads'
                                    : scan.finishing
                                    ? 'Finishing segment'
                                    : 'Camera ready',
                              ),
                              _ScanStatusPill(
                                icon: Icons.cloud_upload_outlined,
                                label: scan.pending == 0
                                    ? 'No queued uploads'
                                    : '${scan.pending} segment${scan.pending == 1 ? '' : 's'} waiting',
                              ),
                            ],
                          ),
                          if (scan.pending > 0)
                            Text(
                              '${scan.pending} segments uploading or waiting',
                              style: const TextStyle(color: Colors.white70),
                            ),
                          if (scan.finishing)
                            const Text(
                              'Finishing scan… Keep this page open.',
                              style: TextStyle(color: Colors.white),
                            ),
                          if (scan.error != null)
                            Text(
                              scan.error!,
                              style: const TextStyle(color: Colors.amber),
                            ),
                          if (camera.controlMessage != null)
                            Text(
                              camera.controlMessage!,
                              style: const TextStyle(color: Colors.white70),
                            ),
                          if (camera.error != null)
                            Text(
                              camera.error!,
                              style: const TextStyle(color: Colors.amber),
                            ),
                          if (!scan.scanning &&
                              !scan.finishing &&
                              camera.cameras.length > 1)
                            DropdownButton<CameraDescription>(
                              value: camera.selectedCamera,
                              dropdownColor: Colors.black,
                              items: [
                                for (final c in camera.cameras)
                                  DropdownMenuItem(
                                    value: c,
                                    child: Text(
                                      '${c.lensDirection.name} camera',
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                              onChanged: camera.busy
                                  ? null
                                  : (c) {
                                      if (c != null) camera.selectCamera(c);
                                    },
                            ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 12,
                            children: [
                              if (scan.error != null) ...[
                                FilledButton(
                                  onPressed: scan.sending ? null : scan.retry,
                                  child: const Text('Retry upload'),
                                ),
                                TextButton(
                                  onPressed: scan.sending
                                      ? null
                                      : () async {
                                          final discard =
                                              await showDialog<bool>(
                                                context: context,
                                                builder: (c) => AlertDialog(
                                                  title: const Text(
                                                    'Discard unsent recording?',
                                                  ),
                                                  content: const Text(
                                                    'Already uploaded segments remain available for review.',
                                                  ),
                                                  actions: [
                                                    TextButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            c,
                                                            false,
                                                          ),
                                                      child: const Text('Keep'),
                                                    ),
                                                    FilledButton(
                                                      onPressed: () =>
                                                          Navigator.pop(
                                                            c,
                                                            true,
                                                          ),
                                                      child: const Text(
                                                        'Discard',
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              );
                                          if (discard == true) {
                                            await scan.discardPending();
                                          }
                                        },
                                  child: const Text('Discard unsent'),
                                ),
                              ] else if (scan.scanning)
                                FilledButton.icon(
                                  onPressed: scan.stop,
                                  icon: const Icon(Icons.stop),
                                  label: const Text('Stop scan'),
                                )
                              else if (!scan.finishing)
                                FilledButton.icon(
                                  onPressed: camera.busy ? null : scan.start,
                                  icon: const Icon(Icons.videocam),
                                  label: const Text('Start scan'),
                                ),
                              if (scan.canLeave)
                                TextButton(
                                  onPressed: _close,
                                  child: const Text('Done'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ScanStatusPill extends StatelessWidget {
  const _ScanStatusPill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(100),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.white),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    ),
  );
}
