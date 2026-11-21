import 'dart:async';

import 'package:camera/camera.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter/material.dart';

import 'recognition_board.dart';

String? terminalClassroomUploadMessage(Object error) {
  if (error is! AppFailure) return null;
  if (const {
    'UPLOAD_EXPIRED',
    'INSUFFICIENT_TEMPLATES',
    'CAPTURE_TIME',
    'SESSION_STATE',
    'CAPTURE_SIZE',
    'MEDIA_MISMATCH',
  }.contains(error.code)) {
    return error.message;
  }
  return null;
}

/// Recording is continuous: the camera stays open while finished segments upload in the
/// background. At most [maxQueued] complete segments are retained, including the active
/// upload; capture pauses (camera still open) only when that many are waiting, so the queue
/// never grows without bound. A flaky connection is retried automatically with a growing
/// delay and never closes the camera.
class ClassroomScan extends ChangeNotifier {
  ClassroomScan(this.camera, this.upload, {
    Future<XFile> Function(XFile)? retain,
    Future<void> Function(XFile)? remove,
    List<XFile> recovered = const [],
    this.maxQueued = 4,
    this.maxUploadRetries = 12,
    Future<void> Function(Duration)? wait,
  }) : retain = retain ?? _unchanged,
       remove = remove ?? _removeOwned,
       wait = wait ?? Future.delayed {
    camera.addListener(_cameraChanged);
    if (recovered.isNotEmpty) {
      _queue.addAll(recovered);
      ended = true;
      error = 'Unsent recording recovered. Retry upload or discard it.';
    }
  }
  final GuidedCamera camera;
  final int maxQueued, maxUploadRetries;
  final Future<void> Function(Duration) wait;
  final Future<void> Function(XFile) upload;
  final Future<XFile> Function(XFile) retain;
  final Future<void> Function(XFile) remove;
  static Future<XFile> _unchanged(XFile file) async => file;
  static Future<void> _removeOwned(XFile file) => removeOwnedClip(file.path);
  final List<XFile> _queue = [];
  bool scanning = false, sending = false, collecting = false, closed = false;
  bool ended = false, releasing = false;
  String? error, cameraError;
  bool retryable = true;
  double? uploadProgress;
  String? uploadStatus;
  int submitted = 0, recorded = 0;
  bool reconnecting = false;
  static int backoffSeconds(int failures) =>
      const [2, 4, 8, 15, 30][(failures - 1).clamp(0, 4)];
  int get pending => _queue.length;
  bool get finishing => ended && !canLeave;
  bool get canLeave =>
      !scanning &&
      !camera.busy &&
      !camera.recording &&
      !releasing &&
      pending == 0 &&
      !sending;
  void _emit() {
    if (!closed) notifyListeners();
  }

  Future<void> start() async {
    if (closed || ended || scanning || camera.busy || error != null) return;
    cameraError = null;
    scanning = true;
    _emit();
    await camera.initialize();
    if (closed || ended) return;
    if (!camera.ready) {
      scanning = false;
      cameraError = camera.error ?? 'Camera unavailable. Please retry.';
      _emit();
      return;
    }
    await _next();
  }

  Future<void> _next() async {
    if (closed ||
        !scanning ||
        error != null ||
        pending >= maxQueued ||
        camera.recording ||
        camera.busy) {
      return;
    }
    await camera.start(const []);
    if (!ended &&
        !camera.recording &&
        camera.clip == null &&
        camera.error != null) {
      scanning = false;
      cameraError = camera.error;
    }
    if (ended) await _finishCamera();
    _emit();
  }

  void _cameraChanged() {
    if (closed) return;
    if (camera.clip != null && !camera.busy && !collecting) {
      unawaited(_collect());
    }
    if (ended && !camera.busy && !camera.recording) {
      unawaited(_finishCamera());
    }
    _emit();
  }

  Future<void> _collect() async {
    collecting = true;
    final file = camera.takeClip();
    if (file != null) {
      try {
        final saved = await retain(file);
        _queue.add(saved);
        recorded++;
        if (saved.path != file.path) await removeOwnedClip(file.path);
      } catch (_) {
        _queue.add(file);
        error = 'Could not save this recording for recovery. Keep this page open and retry upload.';
        scanning = false;
        ended = true;
      }
    }
    collecting = false;
    _emit();
    if (ended) await _finishCamera();
    unawaited(_send());
    await _next();
  }

  Future<void> _send() async {
    if (sending || closed || error != null || _queue.isEmpty) return;
    sending = true;
    _emit();
    var failures = 0;
    try {
      while (_queue.isNotEmpty && !closed) {
        final file = _queue.first;
        try {
          reportUpload('Preparing upload…');
          await upload(file);
          failures = 0;
          reconnecting = false;
        } catch (failure) {
          if (closed) return;
          final terminalMessage = terminalClassroomUploadMessage(failure);
          if (terminalMessage != null) {
            retryable = false;
            error = terminalMessage;
            reconnecting = false;
            await stop();
            return;
          }
          failures++;
          if (failures > maxUploadRetries) {
            retryable = true;
            reconnecting = false;
            error =
                'Upload paused. Your captured segments are kept here. Check your connection and retry.';
            await stop();
            return;
          }
          // Transient: keep the camera recording and try the same segment again.
          reconnecting = true;
          final seconds = backoffSeconds(failures);
          reportUpload('Connection problem. Retrying in $seconds s…');
          await wait(Duration(seconds: seconds));
          continue;
        }
        if (closed) return;
        _queue.removeAt(0);
        submitted++;
        await _remove(file);
        _emit();
        await _next();
      }
    } finally {
      sending = false;
      _emit();
    }
  }

  Future<void> stop() async {
    scanning = false;
    ended = true;
    _emit();
    await _finishCamera();
  }

  Future<void> _finishCamera() async {
    if (closed ||
        releasing ||
        camera.busy ||
        (!camera.ready && !camera.recording && camera.controller == null)) {
      return;
    }
    releasing = true;
    try {
      if (camera.recording) await camera.stop();
      await camera.interrupt();
    } finally {
      releasing = false;
      _emit();
    }
  }

  void reportUpload(String status, [double? progress]) {
    uploadStatus = status;
    uploadProgress = progress;
    _emit();
  }

  Future<void> retry() async {
    if (!retryable || closed) return;
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
      await _remove(file);
    }
    await camera.discard();
    error = null;
    _emit();
  }

  Future<void> _remove(XFile file) async {
    try {
      await remove(file);
      await removeOwnedClip(file.path);
    } catch (_) {
      // The OS can still evict an app-owned cache file.
    }
  }

  @override
  void dispose() {
    closed = true;
    camera.removeListener(_cameraChanged);
    // Pending clips belong to the recovery store until confirmed or discarded.
    _queue.clear();
    super.dispose();
  }
}

class ClassroomScanPage extends StatefulWidget {
  const ClassroomScanPage({
    super.key,
    required this.scan,
    required this.results,
  });
  final ClassroomScan scan;
  final Future<RecognitionSnapshot> Function() results;
  @override
  State<ClassroomScanPage> createState() => _ClassroomScanPageState();
}

class _ClassroomScanPageState extends State<ClassroomScanPage> {
  Timer? poll;
  RecognitionSnapshot snapshot = const RecognitionSnapshot([]);
  AppLifecycleListener? lifecycle;
  bool fetching = false;
  ClassroomScan get scan => widget.scan;
  @override
  void initState() {
    super.initState();
    lifecycle = AppLifecycleListener(onPause: () => unawaited(scan.stop()));
    if (!scan.ended) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => scan.camera.initialize(),
      );
    }
    unawaited(_refresh());
    poll = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (fetching) return;
    fetching = true;
    try {
      final value = await widget.results();
      if (mounted) setState(() => snapshot = value);
    } catch (_) {
      /* Keep the last confirmed server results. */
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
      if (scan.ended) return _uploadPage(context);
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
                            scan.scanning
                                ? 'Scanning the room'
                                : 'Ready to scan your classroom',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 21,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 6),
                          RecognitionBoard(
                            entries: boardEntries(
                              snapshot.rows,
                              processing:
                                  snapshot.processing ||
                                  scan.pending > 0 ||
                                  scan.sending,
                            ),
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            'Move slowly and pause on each group. Grey boxes are detected faces and amber means move closer. A student turns green on the list only after the server recognises them. When you finish, tap Stop scan and wait for uploads.',
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
                                    ? 'Recording · ${camera.elapsed} / ${camera.segmentSeconds} sec segment'
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
                          if (scan.recorded > 0 || camera.recording)
                            Text(
                              'Segment ${scan.recorded + (camera.recording ? 1 : 0)} · '
                              '${scan.submitted} uploaded · ${scan.pending} waiting '
                              '(room for ${scan.maxQueued - scan.pending} more)',
                              key: const ValueKey('scan-progress'),
                              style: const TextStyle(color: Colors.white70),
                            ),
                          if (scan.reconnecting && scan.uploadStatus != null)
                            Text(
                              scan.uploadStatus!,
                              key: const ValueKey('scan-reconnecting'),
                              style: const TextStyle(color: Colors.amber),
                            ),
                          if (!scan.scanning && !scan.finishing && scan.recorded == 0)
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              children: [
                                for (final seconds in const [15, 20, 30])
                                  ChoiceChip(
                                    key: ValueKey('segment-$seconds'),
                                    label: Text('$seconds s segments'),
                                    selected: camera.segmentSeconds == seconds,
                                    onSelected: (_) =>
                                        camera.segmentSeconds = seconds,
                                  ),
                              ],
                            ),
                          if (!scan.scanning && scan.recorded == 0)
                            const Text(
                              'Starting point: about 6 to 8 students per segment, about 3 seconds on each group. Not yet field-tested.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white54),
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
                          if (scan.cameraError != null || camera.error != null)
                            Text(
                              scan.cameraError ?? camera.error!,
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
                                if (scan.retryable)
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

  Widget _uploadPage(BuildContext context) => PopScope(
    canPop: scan.canLeave,
    child: Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: scan.canLeave,
        title: const Text('Classroom scan'),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    scan.releasing || scan.camera.busy
                        ? 'Closing camera…'
                        : scan.error != null
                        ? (scan.retryable
                              ? 'Upload paused'
                              : 'Recording needs attention')
                        : scan.canLeave
                        ? 'Scan complete'
                        : 'Uploading recording',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  if (!scan.canLeave && scan.error == null) ...[
                    LinearProgressIndicator(
                      value: scan.uploadProgress,
                      semanticsLabel: 'Recording upload progress',
                    ),
                    if (scan.uploadProgress case final value?)
                      Text('${(value * 100).round()}% uploaded'),
                  ],
                  Text(
                    scan.error ??
                        (scan.canLeave
                            ? scan.submitted == 0
                                  ? 'No clip was saved. Record at least 10 seconds per segment.'
                                  : '${scan.submitted} uploaded. Processing results will appear in the session.'
                            : scan.uploadStatus ?? 'Saving the last segment…'),
                  ),
                  if (scan.pending > 0)
                    Text(
                      '${scan.submitted} uploaded · ${scan.pending} remaining',
                    ),
                  if (snapshot.rows.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    RecognitionBoard(
                      onDark: false,
                      maxHeight: 320,
                      entries: boardEntries(
                        snapshot.rows,
                        processing:
                            snapshot.processing ||
                            scan.pending > 0 ||
                            scan.sending,
                      ),
                    ),
                  ],
                  if (scan.error != null && !scan.sending) ...[
                    if (scan.retryable)
                      FilledButton(
                        onPressed: scan.retry,
                        child: const Text('Retry upload'),
                      ),
                    TextButton(
                      onPressed: () async {
                        final discard = await showDialog<bool>(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text('Discard unsent segments?'),
                            content: const Text(
                              'Uploaded segments stay in the session.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(context, false),
                                child: const Text('Keep'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(context, true),
                                child: const Text('Discard'),
                              ),
                            ],
                          ),
                        );
                        if (discard == true) await scan.discardPending();
                      },
                      child: const Text('Discard unsent segments'),
                    ),
                  ],
                  if (scan.canLeave)
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Back to session'),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
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
