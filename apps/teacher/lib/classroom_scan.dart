import 'dart:async';

import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:flutter/material.dart';

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
    _emit();
  }

  /// Flips between the front and rear camera, also while recording.
  ///
  /// A segment in progress is ended first (kept when at least [switchMinimumSeconds] long),
  /// then the camera is swapped and recording continues on its own. If the other camera cannot
  /// open, the previous one is restored so the teacher is never left without a camera.
  static const switchMinimumSeconds = 4;
  Future<void> switchCamera() async {
    if (closed || ended || switching || releasing || !camera.canSwitch) return;
    final target = camera.otherCamera!;
    final previous = camera.selectedCamera;
    final wasScanning = scanning;
    switching = true;
    _paused = true; // _collect must not start the next segment on the old camera
    cameraError = null;
    _emit();
    try {
      if (camera.recording) await camera.stop(minimumSeconds: switchMinimumSeconds);
      // Wait until the finished segment has been taken into the queue.
      for (var i = 0; i < 50 && (collecting || camera.clip != null || camera.busy); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (closed) return;
      await camera.selectCamera(target);
      if (!camera.ready && previous != null && !closed) {
        onEvent?.call('camera_failed', code: 'switch');
        await camera.selectCamera(previous);
        cameraError = 'Could not switch cameras. Went back to the previous one.';
      } else {
        onEvent?.call('camera_switched', code: camera.usingFront ? 'front' : 'rear');
      }
    } finally {
      _paused = false;
      switching = false;
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
        await _next();
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
const _tips = [
  (Icons.light_mode_outlined, 'Make sure light falls on students’ faces.'),
  (Icons.social_distance_outlined, 'Move closer if faces look small or blurry.'),
  (Icons.timer_outlined, 'Sweep slowly and pause about 3 seconds on each group.'),
  (Icons.cloud_upload_outlined, 'Segments upload in the background. Keep this page open until they are sent.'),
  (Icons.flip_camera_android, 'You can switch between the front and rear camera at any time.'),
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
    backgroundColor: _ink,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: ListenableBuilder(
          listenable: Listenable.merge([scan, results]),
          builder: (context, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RecognitionBoard(
                entries: _entries,
                maxHeight: MediaQuery.sizeOf(context).height * .5,
              ),
              const SizedBox(height: 10),
              const Text(
                'Green means the server recognised the student. Boxes on the camera only show detected faces.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
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
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (camera.error == null && scan.cameraError == null)
                      const CircularProgressIndicator(color: Colors.white70)
                    else
                      const Icon(Icons.videocam_off_outlined, size: 40, color: Colors.white54),
                    const SizedBox(height: 14),
                    Text(
                      scan.cameraError ?? camera.error ?? 'Opening camera…',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
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

  Widget _topBar(GuidedCamera camera) => Container(
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
            _RoundButton(icon: Icons.close, tooltip: 'Close camera', onPressed: _close),
            const SizedBox(width: 8),
            Expanded(child: Align(alignment: Alignment.centerLeft, child: _statusPill(camera))),
            if (camera.canSwitch)
              _RoundButton(
                key: const ValueKey('flip-camera'),
                icon: Icons.flip_camera_android,
                tooltip: camera.usingFront ? 'Switch to rear camera' : 'Switch to front camera',
                busy: scan.switching,
                onPressed: scan.switching || scan.releasing || scan.ended ? null : scan.switchCamera,
              ),
            if (!camera.usingFront)
              _RoundButton(
                icon: Icons.flashlight_on_outlined,
                tooltip: 'Toggle torch',
                onPressed: camera.busy ? null : camera.toggleTorch,
              ),
            _RoundButton(icon: Icons.help_outline, tooltip: 'Scanning tips', onPressed: _showTips),
          ],
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

  Widget _recordButton(GuidedCamera camera) {
    final scanning = scan.scanning;
    final disabled = !scanning && (camera.busy || scan.finishing || scan.switching);
    return Semantics(
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
    final cameraProblem = scan.cameraError ?? (camera.controller == null ? null : camera.error);
    if (cameraProblem != null) {
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
    if (camera.controlMessage != null) {
      banners.add(_Banner(icon: Icons.info_outline, color: Colors.white70, text: camera.controlMessage!));
    }
    if (banners.isEmpty && !scan.scanning && !scan.finishing && scan.recorded == 0) {
      banners.add(
        const _Banner(
          icon: Icons.touch_app_outlined,
          color: Colors.white70,
          text: 'Hold the phone steady, then sweep slowly and pause about 3 seconds on each group.',
        ),
      );
    }
    return banners.take(2).toList();
  }

  Widget _controls(GuidedCamera camera, {required bool vertical}) {
    final children = <Widget>[_studentsChip(), _recordButton(camera), _rightChip(camera)];
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
          ? Column(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: children,
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
                  ? 'No clip was saved. Record at least 10 seconds per segment.'
                  : '${scan.submitted} segment${scan.submitted == 1 ? '' : 's'} uploaded. Results appear below as they are processed.'
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
                            Icon(icon, size: 34, color: color),
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
                        if (scan.pending > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('${scan.submitted} uploaded · ${scan.pending} remaining'),
                          ),
                        if (progressSteps(snapshot.info, uploading: scan.pending).isNotEmpty) ...[
                          const SizedBox(height: 18),
                          Card(
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

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.busy = false,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool busy;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 6),
    child: Material(
      color: Colors.black.withValues(alpha: .5),
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        constraints: const BoxConstraints.tightFor(width: 44, height: 44),
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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: ExcludeSemantics(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
              ),
              Text(
                caption,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ],
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
