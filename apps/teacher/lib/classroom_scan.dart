import 'dart:async';

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'keep_awake.dart';
import 'processing_progress.dart';
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
/// Diagnostic hook: a fixed event name plus a few bounded numbers. Never file names or text.
typedef ScanEvent =
    void Function(
      String name, {
      String? code,
      int? attempt,
      int? bytes,
      int? count,
      int? durationMs,
    });

/// One segment the server can never accept (empty, or over the 25 MiB limit). Unlike the other
/// terminal failures this says nothing about the rest of the scan, so only that segment is
/// skipped.
bool isUnusableSegment(Object error) => error is AppFailure && error.code == 'CAPTURE_SIZE';

String _codeOf(Object error) =>
    error is AppFailure && error.code != null
    ? error.code!
    : error.runtimeType.toString();

class ClassroomScan extends ChangeNotifier {
  ClassroomScan(this.camera, this.upload, {
    Future<XFile> Function(XFile)? retain,
    Future<void> Function(XFile)? remove,
    List<XFile> recovered = const [],
    this.maxQueued = 4,
    this.maxUploadRetries = 12,
    Future<void> Function(Duration)? wait,
    this.onEvent,
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
  final ScanEvent? onEvent;
  final Future<void> Function(Duration) wait;
  final Future<void> Function(XFile) upload;
  final Future<XFile> Function(XFile) retain;
  final Future<void> Function(XFile) remove;
  static Future<XFile> _unchanged(XFile file) async => file;
  static Future<void> _removeOwned(XFile file) => removeOwnedClip(file.path);
  final List<XFile> _queue = [];
  bool scanning = false, sending = false, collecting = false, closed = false;
  bool ended = false, releasing = false;

  /// True while the front/rear camera is being swapped. Recording resumes on its own.
  bool switching = false;
  bool _paused = false;
  String? error, cameraError;
  bool retryable = true;
  double? uploadProgress;
  String? uploadStatus;
  int submitted = 0, recorded = 0;

  /// Segments dropped because they were empty or too large to upload.
  int skipped = 0;
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
    if (closed) return;
    GuidedCamera.warnBeforeLeaving(!canLeave);
    notifyListeners();
  }

  Future<void> start() async {
    if (closed || ended || scanning || camera.busy || error != null) return;
    cameraError = null;
    scanning = true;
    onEvent?.call('scan_started');
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
        _paused ||
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
    if (camera.lost && !camera.ready && !camera.busy && scanning && !ended) {
      unawaited(_recoverCamera());
    }
    _emit();
  }

  /// Flips between the front and rear camera, also while recording.
  ///
  /// A segment in progress is ended first (kept when at least [switchMinimumSeconds] long),
  /// then the camera is swapped and recording continues on its own. If the other camera cannot
  /// open, the previous one is restored so the teacher is never left without a camera.
  static const switchMinimumSeconds = 4;
  Future<void> switchCamera({CameraDescription? to}) async {
    if (closed || ended || switching || releasing) return;
    final target = to ?? camera.otherCamera;
    if (target == null || target == camera.selectedCamera) return;
    final previous = camera.selectedCamera;
    final wasScanning = scanning;
    switching = true;
    _paused = true; // _collect must not start the next segment on the old camera
    cameraError = null;
    _emit();
    try {
      await _quiesce();
      if (closed) return;
      await camera.selectCamera(target);
      if (!camera.ready && previous != null && !closed) {
        onEvent?.call('camera_failed', code: 'switch');
        await camera.selectCamera(previous);
        cameraError = 'Could not switch cameras. Went back to the previous one.';
      } else if (camera.selectedCamera != target) {
        // The camera was still busy and refused the swap: say so rather than claim success.
        cameraError = 'Could not switch cameras right now. Try again.';
      } else {
        onEvent?.call(
          'camera_switched',
          code: camera.hasFrontRear ? (camera.usingFront ? 'front' : 'rear') : 'other',
        );
      }
    } finally {
      _paused = false;
      switching = false;
      _emit();
    }
    if (!closed && !ended && wasScanning && camera.ready) await _next();
  }

  /// Brings the camera to rest before it is swapped: waits for an operation in flight (a segment
  /// that is starting or stopping, a clip being saved), then ends a segment that is recording.
  /// A press on "flip" that lands while the next segment is still starting (every segment
  /// boundary) used to find the camera busy, so the swap was refused yet reported as done.
  Future<void> _quiesce() async {
    for (var i = 0; i < 100 && !closed; i++) {
      if (camera.busy || collecting || camera.clip != null) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      } else if (camera.recording) {
        await camera.stop(minimumSeconds: switchMinimumSeconds);
      } else {
        return;
      }
    }
  }

  /// The open camera disappeared (a USB webcam was unplugged, or another app took it). Keep
  /// uploading what was recorded, move to another camera when there is one and carry on; when
  /// there is none, stop recording and say so. Pressing Start again reopens a camera.
  bool recovering = false;
  Future<void> _recoverCamera() async {
    if (recovering || closed || ended || switching || releasing) return;
    recovering = true;
    _paused = true;
    final lostCamera = camera.lostCamera;
    final wasScanning = scanning;
    _emit();
    try {
      for (var i = 0; i < 50 && (collecting || camera.clip != null || camera.busy); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (closed) return;
      await camera.refreshCameras();
      final others = [for (final c in camera.cameras) if (c != lostCamera) c];
      if (others.isNotEmpty && wasScanning) {
        await camera.selectCamera(others.first);
        if (camera.ready) {
          cameraError = 'The camera was disconnected. Continuing on ${describeCamera(others.first, camera.cameras)}.';
          onEvent?.call('camera_recovered', code: 'switched');
        }
      }
      if (!camera.ready) {
        scanning = false;
        cameraError = 'The camera was disconnected. Reconnect it, then press Start to continue.';
      }
    } finally {
      _paused = false;
      recovering = false;
      _emit();
    }
    if (!closed && !ended && wasScanning && camera.ready) await _next();
  }

  Future<void> _collect() async {
    collecting = true;
    final file = camera.takeClip();
    if (file != null) {
      try {
        final saved = await retain(file);
        _queue.add(saved);
        recorded++;
        onEvent?.call('segment_recorded', count: recorded, bytes: await _size(saved));
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
    // A segment that finished while this one was still being saved was ignored by
    // _cameraChanged (collecting was set). Take it now: starting the next segment would
    // otherwise discard it.
    if (camera.clip != null && !camera.busy) unawaited(_collect());
    if (ended) await _finishCamera();
    unawaited(_send());
    await _next();
  }

  static Future<int?> _size(XFile file) async {
    try {
      return await file.length();
    } catch (_) {
      return null;
    }
  }

  Future<void> _send() async {
    if (sending || closed || error != null || _queue.isEmpty) return;
    sending = true;
    _emit();
    var failures = 0;
    try {
      while (_queue.isNotEmpty && !closed) {
        final file = _queue.first;
        final began = DateTime.now();
        try {
          reportUpload('Preparing upload…');
          await upload(file);
          onEvent?.call(
            'upload_done',
            count: submitted + 1,
            attempt: failures,
            durationMs: DateTime.now().difference(began).inMilliseconds,
          );
          failures = 0;
          reconnecting = false;
        } catch (failure) {
          if (closed) return;
          if (isUnusableSegment(failure)) {
            // Retrying cannot help, and it must not cost the other segments: a single oversize
            // segment (a busy minute at a high bitrate) used to stop the whole scan and force
            // the teacher to discard everything still waiting.
            onEvent?.call('upload_failed', code: 'CAPTURE_SIZE', attempt: failures);
            _queue.removeAt(0);
            skipped++;
            failures = 0;
            reconnecting = false;
            await _remove(file);
            _emit();
            unawaited(_next());
            continue;
          }
          final terminalMessage = terminalClassroomUploadMessage(failure);
          if (terminalMessage != null) {
            onEvent?.call('upload_failed', code: _codeOf(failure), attempt: failures);
            retryable = false;
            error = terminalMessage;
            reconnecting = false;
            await stop();
            return;
          }
          failures++;
          if (failures > maxUploadRetries) {
            onEvent?.call('upload_failed', code: 'retries_exhausted', attempt: failures);
            retryable = true;
            reconnecting = false;
            error =
                'Upload paused. Your captured segments are kept here. Check your connection and retry.';
            await stop();
            return;
          }
          // Transient: keep the camera recording and try the same segment again.
          onEvent?.call('upload_retry', code: _codeOf(failure), attempt: failures);
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
        // Resume recording in the background: waiting for the camera to start would leave the
        // link idle between two uploads for as long as the camera takes to open a segment.
        unawaited(_next());
      }
    } finally {
      sending = false;
      _emit();
    }
  }

  Future<void> stop() async {
    if (!ended) onEvent?.call('scan_stopped', count: submitted);
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

  String? _shownStatus;
  double? _shownProgress;

  /// Upload progress arrives about once per KiB written (6 000+ times for one 6 MiB chunk), and
  /// every notification rebuilds the whole scan page. The latest value is always kept, but the
  /// page is only told when the text changes or the bar has moved by a whole percent.
  void reportUpload(String status, [double? progress]) {
    uploadStatus = status;
    uploadProgress = progress;
    final shown = _shownProgress;
    final moved = status != _shownStatus ||
        (progress == null) != (shown == null) ||
        (progress != null &&
            shown != null &&
            ((progress >= 1 && shown < 1) || (progress - shown).abs() >= .01));
    if (!moved) return;
    _shownStatus = status;
    _shownProgress = progress;
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
    GuidedCamera.warnBeforeLeaving(false);
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
    this.reference,
  });
  final ClassroomScan scan;
  final Future<RecognitionSnapshot> Function() results;

  /// Short session id shown with problems, so the administrator can find them in the logs.
  final String? reference;
  @override
  State<ClassroomScanPage> createState() => _ClassroomScanPageState();
}

const _ink = Color(0xff102e28);
List<(IconData, String)> get _tips => [
  (Icons.light_mode_outlined, 'Make sure light falls on students’ faces, not from a window behind them.'),
  (Icons.social_distance_outlined, 'Move closer if faces look small or blurry. Grey boxes are fine; amber means move closer.'),
  (Icons.timer_outlined, 'Sweep slowly and pause about 3 seconds on each group.'),
  (Icons.cloud_upload_outlined, 'Segments upload in the background. Keep this page open until they are sent.'),
  if (kIsWeb)
    (Icons.videocam_outlined, 'Using a USB webcam? Plug it in, then pick it from the camera menu. You can switch cameras at any time.')
  else
    (Icons.flip_camera_android, 'You can switch between the front and rear camera at any time.'),
  if (kIsWeb) (Icons.keyboard_outlined, 'Press Space to start or stop the scan.'),
];

class _ClassroomScanPageState extends State<ClassroomScanPage> {
  Timer? poll;
  final results = ValueNotifier<RecognitionSnapshot>(const RecognitionSnapshot([]));
  AppLifecycleListener? lifecycle;
  bool fetching = false;
  ClassroomScan get scan => widget.scan;
  RecognitionSnapshot get snapshot => results.value;

  @override
  void initState() {
    super.initState();
    unawaited(keepScreenAwake(true));
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
      if (mounted) results.value = value;
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
            content: Text('Finishing the scan and uploading captured segments.'),
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
    unawaited(keepScreenAwake(false));
    poll?.cancel();
    lifecycle?.dispose();
    results.dispose();
    super.dispose();
  }

  List<BoardEntry> get _entries => boardEntries(
    snapshot.rows,
    processing: snapshot.processing || scan.pending > 0 || scan.sending,
  );

  Future<void> _discardDialog(String title) async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: const Text('Already uploaded segments remain available for review.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
        ],
      ),
    );
    if (discard == true) await scan.discardPending();
  }

  void _showTips() => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Scanning tips'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (icon, text) in _tips)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 20),
                    const SizedBox(width: 12),
                    Expanded(child: Text(text)),
                  ],
                ),
              ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Got it'))],
    ),
  );

  void _showStudents() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: _ink,
    constraints: const BoxConstraints(maxWidth: 720),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheet) => _StudentsSheet(
      listenable: Listenable.merge([scan, results]),
      entries: () => _entries,
    ),
  );

  Widget _preview(GuidedCamera camera) {
    final controller = camera.controller;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (controller != null)
            ListenableBuilder(
              listenable: camera.faceTracker,
              builder: (context, _) => LiveCameraPreview(
                camera: controller,
                faces: camera.faceTracker.faces,
                onFocus: (point) => camera.focus(point),
              ),
            )
          else
            _cameraState(camera),
          if (controller != null && !scan.scanning && scan.recorded == 0 && !scan.switching)
            const IgnorePointer(child: _FrameGuide()),
          if (scan.switching)
            const ColoredBox(
              color: Color(0x99000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text('Switching camera…', style: TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// What shows where the picture will be: opening, a permission problem, or any other camera
  /// failure, each with the next step.
  Widget _cameraState(GuidedCamera camera) {
    final message = scan.cameraError ?? camera.error;
    if (message == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: Colors.white70),
              SizedBox(height: 14),
              Text('Opening camera…', style: TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      );
    }
    final permission = message.contains('Allow camera access');
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(32, 96, 32, 200),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            key: const ValueKey('camera-state'),
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: const BoxDecoration(color: Colors.white10, shape: BoxShape.circle),
                child: Icon(
                  permission ? Icons.no_photography_outlined : Icons.videocam_off_outlined,
                  size: 32,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                permission ? 'Camera access needed' : 'Camera unavailable',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, height: 1.4),
              ),
              if (permission) ...[
                const SizedBox(height: 12),
                Text(
                  kIsWeb
                      ? 'Choose Allow in the browser prompt, or open the camera icon in the address bar and allow it for this site.'
                      : 'Allow the camera in your phone settings for this app, then try again.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white54, fontSize: 13, height: 1.4),
                ),
              ],
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const ValueKey('camera-retry'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white38),
                  minimumSize: const Size(48, 48),
                ),
                onPressed: camera.busy
                    ? null
                    : () => unawaited(scan.cameraError != null ? scan.start() : camera.initialize()),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusPill(GuidedCamera camera) {
    final (Color dot, String label) = camera.recording
        ? (
            Colors.redAccent,
            '${_clock(camera.elapsed)} / ${_clock(camera.segmentSeconds)} · Segment ${scan.recorded + 1}',
          )
        : scan.finishing
        ? (Colors.amber, 'Finishing…')
        : scan.scanning
        ? (Colors.amber, scan.pending >= scan.maxQueued ? 'Waiting for uploads' : 'Starting segment…')
        : (Colors.white70, 'Ready to scan');
    return Container(
      key: const ValueKey('scan-status'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 10, color: dot),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  static String _clock(int seconds) =>
      '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';

  Widget _topBar(GuidedCamera camera) => LayoutBuilder(
    builder: (context, box) {
      // Narrow phones: the status pill gets a row of its own so it keeps its text.
      final compact = box.maxWidth < 460;
      final size = box.maxWidth < 400 ? 44.0 : 48.0;
      final pill = _statusPill(camera);
      return Container(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xb3000000), Color(0x00000000)],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                _RoundButton(icon: Icons.close, tooltip: 'Close camera', size: size, onPressed: _close),
                if (compact)
                  const Spacer()
                else ...[
                  const SizedBox(width: 8),
                  Expanded(child: Align(alignment: Alignment.centerLeft, child: pill)),
                ],
                if (_showPicker(camera)) _cameraMenu(camera, size),
                if (camera.canSwitch)
                  _RoundButton(
                    key: const ValueKey('flip-camera'),
                    icon: camera.hasFrontRear ? Icons.flip_camera_android : Icons.cameraswitch_outlined,
                    tooltip: camera.hasFrontRear
                        ? (camera.usingFront ? 'Switch to rear camera' : 'Switch to front camera')
                        : 'Switch to the next camera',
                    size: size,
                    busy: scan.switching,
                    onPressed: scan.switching || scan.releasing || scan.ended ? null : () => scan.switchCamera(),
                  ),
                if (!kIsWeb && !camera.usingFront)
                  _RoundButton(
                    icon: Icons.flashlight_on_outlined,
                    tooltip: 'Toggle torch',
                    size: size,
                    onPressed: camera.busy ? null : camera.toggleTorch,
                  ),
                _RoundButton(icon: Icons.help_outline, tooltip: 'Scanning tips', size: size, onPressed: _showTips),
              ],
            ),
            if (compact)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Align(alignment: Alignment.centerLeft, child: pill),
              ),
            // Faces change several times a second; only this line listens to them.
            ListenableBuilder(
              listenable: camera.faceTracker,
              builder: (context, _) => Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: _hint(camera) ?? const SizedBox.shrink(),
                ),
              ),
            ),
            if (camera.recording)
              Padding(
                padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    key: const ValueKey('segment-progress'),
                    value: (camera.elapsed / camera.segmentSeconds).clamp(0, 1).toDouble(),
                    minHeight: 4,
                    backgroundColor: Colors.white24,
                    color: Colors.redAccent,
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  /// A list of cameras to choose from: needed for several webcams, or more than a front / rear pair.
  bool _showPicker(GuidedCamera camera) =>
      camera.cameras.length > 1 && (kIsWeb || camera.cameras.length > 2);

  Widget _cameraMenu(GuidedCamera camera, double size) => PopupMenuButton<CameraDescription>(
    key: const ValueKey('camera-menu'),
    tooltip: 'Choose camera',
    enabled: !scan.switching && !scan.releasing && !scan.ended,
    position: PopupMenuPosition.under,
    onSelected: (choice) => unawaited(scan.switchCamera(to: choice)),
    itemBuilder: (_) => [
      for (final c in camera.cameras)
        CheckedPopupMenuItem(
          value: c,
          checked: c == camera.selectedCamera,
          child: Text(describeCamera(c, camera.cameras), overflow: TextOverflow.ellipsis),
        ),
    ],
    child: Padding(
      padding: const EdgeInsets.only(left: 6),
      child: DecoratedBox(
        decoration: const BoxDecoration(color: Color(0x80000000), shape: BoxShape.circle),
        child: SizedBox.square(
          dimension: size,
          child: const Icon(Icons.videocam_outlined, color: Colors.white, size: 22),
        ),
      ),
    ),
  );

  /// What the picture looks like right now: faces in view and, in the browser, the light.
  /// One short line, so the teacher can fix the framing before recording starts.
  Widget? _hint(GuidedCamera camera) {
    if (!camera.ready || scan.switching) return null;
    final (IconData icon, Color color, String text)? line;
    if (camera.lighting == Lighting.tooDark) {
      line = (Icons.light_mode_outlined, Colors.amber, 'Too dark. Turn on the lights so faces are clear.');
    } else if (camera.lighting == Lighting.tooBright) {
      line = (Icons.wb_sunny_outlined, Colors.amber, 'Too bright. Avoid windows or lamps behind the students.');
    } else if (camera.faceTracker.available || camera.framingAvailable) {
      final faces = camera.faceTracker.faces;
      final close = faces.where((f) => !f.framed).length;
      line = faces.isEmpty
          ? (Icons.face_retouching_off, Colors.white70, 'No faces in view. Aim toward the class.')
          : close > 0
          ? (Icons.zoom_in_map, Colors.amber, '${faces.length} in view · $close too small or cut off. Move closer.')
          : (Icons.face_outlined, Colors.white70, '${faces.length} face${faces.length == 1 ? '' : 's'} in view');
    } else {
      line = null;
    }
    if (line == null) return null;
    return Container(
      key: const ValueKey('framing-hint'),
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .55),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(line.$1, size: 16, color: line.$2),
          const SizedBox(width: 6),
          Flexible(
            child: Text(line.$3, style: TextStyle(color: line.$2 == Colors.white70 ? Colors.white : line.$2, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _recordButton(GuidedCamera camera, {bool caption = false}) {
    final scanning = scan.scanning;
    final disabled = !scanning && (camera.busy || scan.finishing || scan.switching);
    final button = Semantics(
      button: true,
      label: scanning ? 'Stop scan' : 'Start scan',
      child: GestureDetector(
        key: const ValueKey('record-button'),
        onTap: disabled ? null : (scanning ? scan.stop : scan.start),
        child: SizedBox.square(
          dimension: 76,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox.square(
                dimension: 76,
                child: CircularProgressIndicator(
                  value: scanning && camera.recording
                      ? (camera.elapsed / camera.segmentSeconds).clamp(0, 1).toDouble()
                      : 1,
                  strokeWidth: 4,
                  backgroundColor: Colors.white24,
                  color: scanning ? Colors.redAccent : Colors.white,
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: scanning ? 30 : 58,
                height: scanning ? 30 : 58,
                decoration: BoxDecoration(
                  color: disabled ? Colors.white24 : Colors.redAccent,
                  borderRadius: BorderRadius.circular(scanning ? 8 : 40),
                ),
                child: scanning ? null : const Icon(Icons.videocam, color: Colors.white, size: 26),
              ),
            ],
          ),
        ),
      ),
    );
    if (!caption) return button;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        button,
        const SizedBox(height: 4),
        ExcludeSemantics(
          child: Text(
            scanning ? 'Stop scan' : 'Start scan',
            maxLines: 1,
            style: TextStyle(
              color: disabled ? Colors.white38 : Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  Widget _studentsChip() => ValueListenableBuilder(
    valueListenable: results,
    builder: (context, _, _) {
      final entries = _entries;
      final done = entries.where((e) => e.state == RecognitionState.recognized).length;
      return _SideChip(
        key: const ValueKey('students-chip'),
        icon: Icons.groups_2_outlined,
        iconColor: done > 0 ? Colors.greenAccent : Colors.white70,
        label: entries.isEmpty ? 'Students' : '$done / ${entries.length}',
        caption: entries.isEmpty ? 'list' : 'recognised',
        onTap: _showStudents,
      );
    },
  );

  Widget _rightChip(GuidedCamera camera) {
    if (!scan.scanning && !scan.finishing && scan.recorded == 0) {
      return PopupMenuButton<int>(
        key: const ValueKey('segment-length'),
        tooltip: 'Segment length',
        initialValue: camera.segmentSeconds,
        onSelected: (v) => camera.segmentSeconds = v,
        itemBuilder: (_) => [
          for (final seconds in const [15, 20, 30])
            PopupMenuItem(value: seconds, child: Text('$seconds second segments')),
        ],
        child: _SideChip(
          icon: Icons.timer_outlined,
          label: '${camera.segmentSeconds} s',
          caption: 'segments',
        ),
      );
    }
    return _SideChip(
      key: const ValueKey('upload-chip'),
      icon: scan.reconnecting ? Icons.cloud_off_outlined : Icons.cloud_upload_outlined,
      iconColor: scan.reconnecting ? Colors.amber : Colors.white70,
      label: scan.reconnecting
          ? 'Retrying'
          : scan.pending == 0
          ? 'All sent'
          : '${scan.pending} waiting',
      caption: '${scan.submitted} sent',
    );
  }

  /// Short messages above the controls, at most two, most important first.
  List<Widget> _banners(GuidedCamera camera) {
    final banners = <Widget>[];
    if (scan.error != null) {
      banners.add(
        _Banner(
          icon: Icons.warning_amber_rounded,
          color: Colors.amber,
          text: scan.error!,
          actions: [
            if (scan.retryable)
              TextButton(onPressed: scan.sending ? null : scan.retry, child: const Text('Retry')),
            TextButton(
              onPressed: scan.sending ? null : () => _discardDialog('Discard unsent recording?'),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
    }
    if (scan.skipped > 0) {
      banners.add(
        _Banner(
          key: const ValueKey('scan-skipped'),
          icon: Icons.info_outline,
          color: Colors.amber,
          text: '${scan.skipped} segment${scan.skipped == 1 ? ' was' : 's were'} too large to upload and '
              '${scan.skipped == 1 ? 'was' : 'were'} skipped. Choose a shorter segment length.',
        ),
      );
    }
    final cameraProblem = scan.cameraError ?? (camera.controller == null ? null : camera.error);
    if (cameraProblem != null && camera.controller != null) {
      banners.add(
        _Banner(
          icon: Icons.videocam_off_outlined,
          color: Colors.amber,
          text: cameraProblem,
          actions: [
            if (!scan.scanning)
              TextButton(
                onPressed: camera.busy ? null : scan.start,
                child: const Text('Try again'),
              ),
          ],
        ),
      );
    }
    if (scan.reconnecting && scan.uploadStatus != null) {
      banners.add(
        _Banner(
          key: const ValueKey('scan-reconnecting'),
          icon: Icons.wifi_off_rounded,
          color: Colors.amber,
          text: '${scan.uploadStatus!} Your segments are saved.',
        ),
      );
    }
    final info = snapshot.info;
    final summary = processingSummary(info, uploading: 0);
    if (summary.isNotEmpty) {
      final problem = info.stalled || info.failed > 0;
      banners.add(
        _Banner(
          key: const ValueKey('processing-banner'),
          icon: problem ? Icons.warning_amber_rounded : Icons.autorenew_rounded,
          color: problem ? Colors.amber : Colors.lightBlueAccent,
          text: problem ? (processingProblem(info) ?? summary) : summary,
        ),
      );
    }
    if (camera.framesFaces && camera.framingFailed && banners.length < 2) {
      banners.add(
        const _Banner(
          icon: Icons.info_outline,
          color: Colors.white70,
          text: 'Live face boxes are unavailable in this browser. Recording and recognition still work.',
        ),
      );
    }
    if (camera.controlMessage != null) {
      banners.add(_Banner(icon: Icons.info_outline, color: Colors.white70, text: camera.controlMessage!));
    }
    if (banners.isEmpty && !scan.scanning && !scan.finishing && scan.recorded == 0) {
      banners.add(
        const _Banner(
          icon: Icons.touch_app_outlined,
          color: Colors.white70,
          text: kIsWeb
              ? 'Put the camera where it sees the whole class, then pan slowly and pause about 3 seconds on each group.'
              : 'Hold the phone steady, then sweep slowly and pause about 3 seconds on each group.',
        ),
      );
    }
    return banners.take(2).toList();
  }

  Widget _controls(GuidedCamera camera, {required bool vertical}) {
    final children = <Widget>[_studentsChip(), _recordButton(camera, caption: !vertical), _rightChip(camera)];
    final box = Container(
      padding: vertical
          ? const EdgeInsets.symmetric(vertical: 12, horizontal: 8)
          : const EdgeInsets.fromLTRB(16, 10, 16, 12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .58),
        borderRadius: vertical
            ? const BorderRadius.horizontal(left: Radius.circular(24))
            : const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: vertical
          ? MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: children,
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [for (final c in children) Expanded(child: Center(child: c))],
            ),
    );
    return box;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([scan, results]),
    builder: (context, _) {
      final camera = scan.camera;
      if (scan.ended) return _finishPage(context);
      return PopScope(
        canPop: scan.canLeave,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_close());
        },
        child: CallbackShortcuts(
          bindings: {
            if (kIsWeb)
              const SingleActivator(LogicalKeyboardKey.space): () {
                if (scan.scanning) {
                  unawaited(scan.stop());
                } else if (!camera.busy && !scan.finishing && !scan.switching) {
                  unawaited(scan.start());
                }
              },
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            top: false,
            bottom: false,
            child: LayoutBuilder(
              builder: (context, box) {
                final landscape = box.maxWidth > box.maxHeight;
                final padding = MediaQuery.paddingOf(context);
                final banners = _banners(camera);
                final bannerColumn = Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final b in banners)
                      Padding(padding: const EdgeInsets.only(top: 6), child: b),
                  ],
                );
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    _preview(camera),
                    Positioned(
                      top: 0,
                      left: 0,
                      right: landscape ? 132 : 0,
                      child: SafeArea(bottom: false, right: false, child: _topBar(camera)),
                    ),
                    if (landscape) ...[
                      Positioned(
                        top: padding.top + 12,
                        bottom: padding.bottom + 12,
                        right: 0,
                        width: 124,
                        child: _controls(camera, vertical: true),
                      ),
                      Positioned(
                        left: 12 + padding.left,
                        right: 136,
                        bottom: 12 + padding.bottom,
                        child: bannerColumn,
                      ),
                    ] else
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                              child: bannerColumn,
                            ),
                            Padding(
                              padding: EdgeInsets.only(bottom: padding.bottom),
                              child: _controls(camera, vertical: false),
                            ),
                          ],
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
          ),
        ),
      );
    },
  );

  Widget _finishPage(BuildContext context) {
    final theme = Theme.of(context);
    final waiting = !scan.canLeave && scan.error == null;
    final (IconData icon, Color color) = scan.releasing || scan.camera.busy || waiting
        ? (Icons.cloud_upload_outlined, theme.colorScheme.primary)
        : scan.error != null
        ? (Icons.warning_amber_rounded, Colors.amber.shade800)
        : scan.submitted > 0
        ? (Icons.check_circle_outline, Colors.green.shade700)
        : (Icons.info_outline, theme.colorScheme.onSurfaceVariant);
    final title = scan.releasing || scan.camera.busy
        ? 'Closing camera…'
        : scan.error != null
        ? (scan.retryable ? 'Upload paused' : 'Recording needs attention')
        : scan.canLeave
        ? 'Scan complete'
        : 'Uploading recording';
    final message = scan.error ??
        (scan.canLeave
            ? scan.submitted == 0
                  ? (scan.skipped > 0
                        ? 'Nothing was uploaded: the recorded segments were too large. Choose a shorter segment length.'
                        : 'No clip was saved. Record at least 10 seconds per segment.')
                  : '${scan.submitted} segment${scan.submitted == 1 ? '' : 's'} uploaded. Results appear below as they are processed.'
                      '${scan.skipped > 0 ? ' ${scan.skipped} too large to upload ${scan.skipped == 1 ? 'was' : 'were'} skipped.' : ''}'
            : scan.uploadStatus ?? 'Saving the last segment…');
    return PopScope(
      canPop: scan.canLeave,
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: scan.canLeave,
          title: const Text('Classroom scan'),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: ListView(
                      padding: const EdgeInsets.all(20),
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: color.withValues(alpha: .12),
                                borderRadius: BorderRadius.circular(AppRadius.lg),
                              ),
                              child: Icon(icon, size: 30, color: color),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(title, style: theme.textTheme.titleLarge),
                                  const SizedBox(height: 4),
                                  Text(message, style: theme.textTheme.bodyMedium),
                                ],
                              ),
                            ),
                          ],
                        ),
                        if (waiting) ...[
                          const SizedBox(height: 16),
                          LinearProgressIndicator(
                            value: scan.uploadProgress,
                            semanticsLabel: 'Recording upload progress',
                          ),
                          if (scan.uploadProgress case final value?)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text('${(value * 100).round()}% uploaded'),
                            ),
                        ],
                        if (scan.submitted > 0 || scan.pending > 0 || scan.skipped > 0)
                          Padding(
                            key: const ValueKey('finish-counts'),
                            padding: const EdgeInsets.only(top: 14),
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                TonePill(
                                  '${scan.submitted} uploaded',
                                  tone: AppTone.success,
                                  icon: Icons.cloud_done_outlined,
                                ),
                                if (scan.pending > 0)
                                  TonePill(
                                    '${scan.pending} remaining',
                                    tone: AppTone.warning,
                                    icon: Icons.hourglass_top,
                                  ),
                                if (scan.skipped > 0)
                                  TonePill(
                                    '${scan.skipped} skipped',
                                    tone: AppTone.danger,
                                    icon: Icons.block,
                                  ),
                              ],
                            ),
                          ),
                        if (progressSteps(snapshot.info, uploading: scan.pending).isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: ProcessingProgress(
                                info: snapshot.info,
                                uploading: scan.pending,
                                reference: widget.reference,
                              ),
                            ),
                          ),
                        ],
                        if (snapshot.rows.isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: RecognitionBoard(
                                onDark: false,
                                maxHeight: 360,
                                entries: _entries,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (scan.error != null && !scan.sending) ...[
                        if (scan.retryable)
                          FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                            onPressed: scan.retry,
                            child: const Text('Retry upload'),
                          ),
                        TextButton(
                          onPressed: () => _discardDialog('Discard unsent segments?'),
                          child: const Text('Discard unsent segments'),
                        ),
                      ],
                      if (scan.canLeave)
                        FilledButton(
                          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text('Back to session'),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The per-student recognition list over the camera: summary, search, a "needs attention"
/// filter and the list. Padded for the keyboard so the search field is never covered.
class _StudentsSheet extends StatefulWidget {
  const _StudentsSheet({required this.listenable, required this.entries});
  final Listenable listenable;
  final List<BoardEntry> Function() entries;
  @override
  State<_StudentsSheet> createState() => _StudentsSheetState();
}

class _StudentsSheetState extends State<_StudentsSheet> {
  final _search = TextEditingController();
  bool _attention = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final room = media.size.height - media.viewInsets.bottom - media.padding.vertical;
    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: ListenableBuilder(
            listenable: widget.listenable,
            builder: (context, _) {
              final entries = widget.entries();
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  if (entries.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text(
                        'No students to show yet. The list appears once this session\'s roster has loaded.',
                        key: ValueKey('students-empty'),
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70, height: 1.4),
                      ),
                    )
                  else ...[
                    TextField(
                      key: const ValueKey('students-search'),
                      controller: _search,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(color: Colors.white),
                      cursorColor: Colors.white,
                      decoration: InputDecoration(
                        hintText: 'Search name or enrolment',
                        hintStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(Icons.search, color: Colors.white54),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close, color: Colors.white54),
                                onPressed: () => setState(_search.clear),
                              ),
                        filled: true,
                        fillColor: Colors.white12,
                        contentPadding: const EdgeInsets.symmetric(vertical: 12),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Semantics(
                        button: true,
                        selected: _attention,
                        label: 'Needs attention',
                        child: Material(
                          key: const ValueKey('students-attention'),
                          color: _attention ? Colors.white30 : Colors.white12,
                          shape: const StadiumBorder(side: BorderSide(color: Colors.white24)),
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: () => setState(() => _attention = !_attention),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(minHeight: 44),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 14),
                                child: ExcludeSemantics(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        _attention ? Icons.check : Icons.filter_list,
                                        size: 18,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 8),
                                      const Flexible(
                                        child: Text(
                                          'Needs attention',
                                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    RecognitionBoard(
                      entries: entries,
                      query: _search.text,
                      attentionOnly: _attention,
                      maxHeight: (room * .42).clamp(120.0, 420.0),
                    ),
                  ],
                  const SizedBox(height: 10),
                  const Text(
                    'Green means the server recognised the student. Boxes on the camera only show detected faces.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
    this.size = 48,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;
  final double size;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Material(
      color: Colors.black.withValues(alpha: .55),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        icon: busy
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
              )
            : Icon(icon, color: onPressed == null ? Colors.white38 : Colors.white, size: 22),
      ),
    ),
  );
}

class _SideChip extends StatelessWidget {
  const _SideChip({
    super.key,
    required this.icon,
    required this.label,
    required this.caption,
    this.iconColor = Colors.white70,
    this.onTap,
  });
  final IconData icon;
  final Color iconColor;
  final String label, caption;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: '$label $caption',
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                ),
              ),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
        ),
        ),
      ),
    ),
  );
}

class _Banner extends StatelessWidget {
  const _Banner({
    super.key,
    required this.icon,
    required this.color,
    required this.text,
    this.actions = const [],
  });
  final IconData icon;
  final Color color;
  final String text;
  final List<Widget> actions;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: .62),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: .5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.3),
            ),
          ),
          ...actions,
        ],
      ),
    ),
  );
}

/// Faint corner brackets and thirds before the first recording: where to put the class.
class _FrameGuide extends StatelessWidget {
  const _FrameGuide();
  @override
  Widget build(BuildContext context) => CustomPaint(
    key: const ValueKey('frame-guide'),
    painter: _GuidePainter(),
    child: const SizedBox.expand(),
  );
}

class _GuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final inset = size.shortestSide * .12;
    final r = Rect.fromLTRB(inset, inset * 2.2, size.width - inset, size.height - inset * 2.4);
    final bracket = Paint()
      ..color = Colors.white.withValues(alpha: .7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final len = size.shortestSide * .08;
    for (final (corner, dx, dy) in [
      (r.topLeft, 1.0, 1.0),
      (r.topRight, -1.0, 1.0),
      (r.bottomLeft, 1.0, -1.0),
      (r.bottomRight, -1.0, -1.0),
    ]) {
      canvas.drawLine(corner, corner.translate(len * dx, 0), bracket);
      canvas.drawLine(corner, corner.translate(0, len * dy), bracket);
    }
    final thirds = Paint()
      ..color = Colors.white.withValues(alpha: .14)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      canvas.drawLine(Offset(r.left + r.width * i / 3, r.top), Offset(r.left + r.width * i / 3, r.bottom), thirds);
      canvas.drawLine(Offset(r.left, r.top + r.height * i / 3), Offset(r.right, r.top + r.height * i / 3), thirds);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
