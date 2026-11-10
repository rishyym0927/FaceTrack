import 'dart:async';

import 'package:camera/camera.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

import 'student_pose_analyzer_stub.dart'
    if (dart.library.io) 'student_pose_analyzer_io.dart'
    as pose_platform;

class StudentEnrolment extends ConsumerStatefulWidget {
  const StudentEnrolment({super.key});
  @override
  ConsumerState<StudentEnrolment> createState() => _StudentEnrolmentState();
}

class _StudentEnrolmentState extends ConsumerState<StudentEnrolment> {
  late final AppServices services;
  late final String institute, owner;
  final camera = GuidedCamera(
    enrollmentGuidance: true,
    analyzerFactory: pose_platform.createStudentAnalyzer,
  );
  final createMutation = Mutation(), consentMutation = Mutation();
  BiometricState? state;
  Json? notice;
  PendingClip? pending;
  AppFailure? error;
  bool busy = false, loading = true, accepted = false, retaining = false;
  bool replacing = false;
  double? uploadProgress;
  String? uploadStage;
  ResumableUpload? uploader;
  Timer? poll;
  AppLifecycleListener? lifecycle;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    services = ref.read(servicesProvider);
    institute = ref.read(authProvider).institute!;
    owner = services.client.auth.currentUser!.id;
    camera.addListener(cameraChanged);
    lifecycle = AppLifecycleListener(
      onPause: () => camera.interrupt(),
      onResume: () => load(),
    );
    load();
  }

  Future<void> load() async {
    final current = ++generation;
    try {
      final values = await Future.wait([
        services.api.send(
          'GET',
          '/v1/me/biometric-enrollment',
          institute: institute,
        ),
        services.api.send('GET', '/v1/privacy/notice'),
      ]);
      if (!mounted || current != generation) return;
      final next = BiometricState.fromJson(values[0]);
      await PendingClips.expire(owner: owner);
      if (!mounted || current != generation) return;
      var saved = await PendingClips.read();
      if (!mounted || current != generation) return;
      if (saved != null &&
          (saved.institute != institute ||
              saved.owner != owner ||
              saved.attempt != next.attempt?.id ||
              next.attempt?.status != 'awaiting_upload')) {
        if (!mounted || current != generation) return;
        await PendingClips.clear();
        saved = null;
      }
      if (!mounted || current != generation) return;
      setState(() {
        state = next;
        notice = values[1];
        pending = saved;
        error = null;
        loading = false;
      });
      poll?.cancel();
      if (['queued', 'processing'].contains(next.attempt?.status)) {
        poll = Timer(const Duration(seconds: 3), load);
      }
    } catch (e) {
      if (!mounted || current != generation) return;
      setState(() {
        error = e is AppFailure
            ? e
            : const AppFailure('Could not load face enrolment. Please retry.');
        loading = false;
      });
      if (['queued', 'processing'].contains(state?.attempt?.status)) {
        poll?.cancel();
        poll = Timer(const Duration(seconds: 30), load);
      }
    }
  }

  void cameraChanged() {
    if (!mounted) return;
    if (camera.clip != null && pending == null && !retaining) {
      retaining = true;
      unawaited(retainRecording());
    }
    setState(() {});
  }

  Future<void> retainRecording() async {
    final a = state!.attempt!, file = camera.clip!;
    try {
      final record = PendingClip(
        owner: owner,
        institute: institute,
        attempt: a.id,
        path: file.path,
        mime: kIsWeb ? 'video/webm' : 'video/mp4',
        completeKey: Mutation().key,
        created: a.expiresAt.subtract(const Duration(hours: 24)),
        missedGuidance: camera.missingPoses,
      );
      final saved = await PendingClips.retain(record);
      if (services.client.auth.currentUser?.id != owner) {
        await PendingClips.clear();
        return;
      }
      if (mounted) {
        setState(() {
          pending = saved;
          camera.clip = saved.file;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => error = const AppFailure(
            'Could not retain this recording privately. Please record again.',
          ),
        );
      }
    } finally {
      retaining = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> action(Future<void> Function() body) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await body();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is AppFailure
              ? e
              : const AppFailure(
                  'The action did not finish. Check your connection and retry.',
                ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          uploadProgress = null;
          uploadStage = null;
        });
      }
    }
  }

  Future<void> consent() => action(() async {
    await services.api.send(
      'POST',
      '/v1/consents',
      institute: institute,
      body: {
        'notice_version': notice!['version'],
        'notice_hash': notice!['hash'],
      },
      mutation: consentMutation,
    );
    await load();
  });
  Future<void> record() => action(() async {
    var a = state?.attempt;
    if (a == null || !a.unfinished) {
      if (state?.consentId == null) {
        throw const AppFailure('Read and accept the notice first.');
      }
      if (a != null) createMutation.reset();
      final result = await services.api.send(
        'POST',
        '/v1/biometric-enrollments',
        institute: institute,
        body: {
          'consent_id': state!.consentId,
          'mime_type': kIsWeb ? 'video/webm' : 'video/mp4',
          'expected_bytes': 25 * 1024 * 1024,
        },
        mutation: createMutation,
      );
      a = BiometricAttempt.fromJson(result);
      await load();
      if (state?.attempt?.id != a.id || error != null) {
        throw const AppFailure(
          'Could not confirm the recording session. Refresh and retry recording.',
        );
      }
    }
    if (a.status != 'awaiting_upload') return;
    await openCapture(a.poses);
  });
  Future<void> upload() => action(() async {
    final clip = pending!, a = state!.attempt!;
    setState(() => uploadStage = 'Checking your private recording…');
    final size = await clip.file.length();
    if (size > 25 * 1024 * 1024 || size == 0) {
      throw const AppFailure(
        'Video exceeds 25 MiB or is empty. Discard it and record again.',
      );
    }
    final hash = (await sha256.bind(clip.file.openRead()).first).toString();
    Future<void> commit() async {
      final mutation = Mutation()..key = clip.completeKey;
      if (mounted) setState(() => uploadStage = 'Submitting for processing…');
      await services.api.send(
        'POST',
        '/v1/biometric-enrollments/${a.id}/upload-complete',
        institute: institute,
        body: {'asset_id': a.assetId, 'byte_size': size, 'sha256': hash},
        mutation: mutation,
      );
    }

    try {
      bool committed = false;
      // A lost final PATCH/202 response must not restart an already completed non-overwriting upload.
      if (clip.uploadUrl != null) {
        try {
          await commit();
          committed = true;
        } on AppFailure catch (e) {
          if (e.code != 'MEDIA_NOT_AVAILABLE') rethrow;
        }
      }
      if (!committed) {
        if (mounted) {
          setState(() => uploadStage = 'Authorizing private upload…');
        }
        final grant = await services.api.send(
          'POST',
          '/v1/biometric-enrollments/${a.id}/upload-grant',
          institute: institute,
          body: {'mime_type': clip.mime, 'expected_bytes': size},
        );
        final currentUploader = ResumableUpload();
        uploader = currentUploader;
        if (mounted) {
          setState(() {
            uploadProgress = 0;
            uploadStage = 'Uploading your video…';
          });
        }
        await currentUploader.upload(
          clip.file,
          grant,
          services.config.publishableKey,
          resumeUrl: clip.uploadUrl,
          progress: (value) {
            if (mounted) setState(() => uploadProgress = value);
          },
          checkpoint: (url) async {
            clip.uploadUrl = url;
            final retained = await PendingClips.update(clip);
            if (!retained || services.client.auth.currentUser?.id != owner) {
              currentUploader.cancel();
              throw const AppFailure(
                'This recording is no longer available. Sign in and record again.',
                status: 401,
              );
            }
          },
        );
        await commit();
      }
      await PendingClips.clear();
      await camera.discard();
      pending = null;
      await camera.interrupt();
      await load();
    } catch (e) {
      if (e is AppFailure) {
        rethrow;
      }
      if (e is DioException) {
        final status = e.response?.statusCode;
        throw AppFailure(
          'Upload interrupted${status == null ? '' : ' (HTTP $status)'}. Check internet access and retry upload. Your recording is still saved privately.',
        );
      }
      throw const AppFailure(
        'Upload interrupted. Check your connection and retry upload to resume. Your recording remains private.',
      );
    } finally {
      uploader = null;
    }
  });
  Future<void> retake() => action(() async {
    final attempt = state?.attempt;
    if (attempt == null || attempt.status != 'awaiting_upload') return;
    if (pending?.uploadUrl != null) {
      throw const AppFailure(
        'This upload has started. Retry it or cancel this enrolment before recording a replacement.',
      );
    }
    await openCapture(
      attempt.poses,
      beforeStart: () async {
        await PendingClips.clear();
        camera.clip = null;
        if (mounted) setState(() => pending = null);
      },
    );
  });

  Future<void> openCapture(
    List<String> order, {
    Future<void> Function()? beforeStart,
  }) async {
    Future<void> start() async {
      await beforeStart?.call();
      await camera.start(order);
    }

    if (!mounted) return;
    if (kIsWeb) {
      await camera.initialize();
      if (camera.ready) await start();
      return;
    }
    try {
      await Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) =>
              _StudentCameraPage(camera: camera, order: order, start: start),
        ),
      );
    } finally {
      if (!camera.disposed) await camera.interrupt();
    }
  }

  Future<void> cancel() async {
    final a = state!.attempt!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Discard this enrolment?',
        child: const Text(
          'The unfinished recording and candidate templates will be removed. Any previous active enrolment stays active.',
        ),
        submit: (_) async {
          uploader?.cancel();
          await services.api.send(
            'POST',
            '/v1/biometric-enrollments/${a.id}/cancel',
            institute: institute,
            version: a.version,
          );
          await PendingClips.clear();
          await camera.discard();
        },
      ),
    );
    if (confirmed == true && mounted) {
      pending = null;
      createMutation.reset();
      await load();
    }
  }

  Future<void> withdraw() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => ActionDialog(
        title: 'Withdraw face-enrolment consent?',
        child: const Text(
          'Your face templates will stop being eligible immediately. Videos and template payloads will be deleted. You can continue with manual attendance.',
        ),
        submit: (_) async {
          await services.api.send(
            'DELETE',
            '/v1/consents/${state!.consentId}',
            institute: institute,
          );
          await PendingClips.clear();
          await camera.discard();
          consentMutation.reset();
        },
      ),
    );
    if (confirmed == true && mounted) {
      pending = null;
      await load();
    }
  }

  @override
  void dispose() {
    generation++;
    poll?.cancel();
    lifecycle?.dispose();
    uploader?.cancel();
    camera.removeListener(cameraChanged);
    camera.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());
    if (state == null) {
      return ContentPage(
        children: [
          ErrorView(error ?? const AppFailure('Please retry.'), retry: load),
        ],
      );
    }
    final a = state!.attempt;
    final captureVisible =
        !state!.active || replacing || (a?.unfinished ?? false);
    final step = state!.active && !replacing && !(a?.unfinished ?? false)
        ? 5
        : a?.status == 'review_required'
        ? 4
        : ['queued', 'processing'].contains(a?.status)
        ? 3
        : pending != null
        ? 2
        : state!.consentId != null
        ? 1
        : 0;
    return ContentPage(
      children: [
        PageHeader(
          title: 'Face enrolment',
          subtitle:
              'Record once, then ask your faculty to verify your identity.',
          eyebrow: 'STUDENT SPACE',
          icon: Icons.face_retouching_natural_outlined,
          action: OutlinedButton.icon(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ),
        if (error != null && pending == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: ErrorView(error!, retry: load),
          ),
        EnrolmentSteps(current: step),
        if (state!.active)
          Panel(
            accent: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const _StateIcon(
                      icon: Icons.verified_outlined,
                      color: Color(0xff176451),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Face enrolment active',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'You are ready for classroom recognition. No further recording is needed. Your faculty will review attendance before publishing it.',
                ),
                if (!captureVisible) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () => setState(() => replacing = true),
                    child: const Text('Replace recording'),
                  ),
                ],
                if (replacing)
                  const Text(
                    'Your current enrolment stays active until your faculty approves the replacement.',
                  ),
              ],
            ),
          ),
        if (state!.consentId == null && notice != null)
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Before recording',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(notice!['text']),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: accepted,
                  onChanged: busy
                      ? null
                      : (v) => setState(() => accepted = v ?? false),
                  title: const Text(
                    'I understand and voluntarily agree to face enrolment.',
                  ),
                ),
                FilledButton(
                  onPressed: !accepted || busy ? null : consent,
                  child: Text(busy ? 'Saving…' : 'Accept and continue'),
                ),
              ],
            ),
          ),
        if (a != null && a.status != 'active')
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _StateIcon.forStatus(a.status),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        state!.active &&
                                [
                                  'expired',
                                  'cancelled',
                                  'rejected',
                                  'failed',
                                ].contains(a.status)
                            ? 'Replacement ${biometricStatus(a.status).toLowerCase()}'
                            : biometricStatus(a.status),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
                if (a.reason != null) ...[
                  const SizedBox(height: 8),
                  Text(a.reason!),
                ],
                if (['expired', 'rejected', 'failed'].contains(a.status))
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'This recording cannot be retried. Start a new guided recording when you are ready; your previous active enrolment, if any, stays active until a replacement is approved.',
                    ),
                  ),
                if (['queued', 'processing'].contains(a.status))
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Processing runs on the institute Mac. This stays pending while its worker is offline.',
                    ),
                  ),
                if (a.status == 'review_required')
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'A faculty member of an approved subject can review this recording. Review must finish within 24 hours or you will need to record again.',
                    ),
                  ),
              ],
            ),
          ),
        if (captureVisible &&
            state!.consentId != null &&
            (a == null || !a.unfinished || a.status == 'awaiting_upload'))
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (pending == null && !camera.recording) ...[
                  Text(
                    'Before you record',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Use good lighting and keep only yourself in frame. Hold each prompted direction until its circle fills. Recording lasts 10–25 seconds; audio stays off.',
                  ),
                  const SizedBox(height: 16),
                ],
                if (camera.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(camera.error!),
                  ),
                if (retaining)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (pending != null && !retaining) ...[
                  ClipPlayback(
                    key: ValueKey(pending!.path),
                    file: pending!.file,
                  ),
                  const Text(
                    'Check that only you are visible and all five poses are shown. Audio is disabled.',
                  ),
                  if (pending!.missedGuidance.isNotEmpty)
                    Text(
                      'Live guidance did not capture: ${pending!.missedGuidance.join(', ')}. Review the video; you can retake it or upload for faculty review.',
                    ),
                  if (uploadProgress != null) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: uploadProgress),
                    Text('Uploading ${(uploadProgress! * 100).round()}%'),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: busy ? null : upload,
                    child: Text(
                      busy
                          ? (uploadStage ?? 'Preparing upload…')
                          : 'Upload for processing',
                    ),
                  ),
                  TextButton(
                    onPressed: busy || pending!.uploadUrl != null
                        ? null
                        : retake,
                    child: const Text('Retake video'),
                  ),
                  if (pending!.uploadUrl != null)
                    const Text(
                      'This upload has started. Retry the upload or cancel this enrolment before recording again.',
                    ),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text(
                          error!.message,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  if (uploadProgress != null)
                    TextButton(
                      onPressed: () => uploader?.cancel(),
                      child: const Text('Pause upload'),
                    ),
                ] else if (!camera.recording && !retaining)
                  FilledButton.icon(
                    onPressed: busy ? null : record,
                    icon: const Icon(Icons.videocam_outlined),
                    label: Text(busy ? 'Preparing…' : 'Record guided video'),
                  ),
                if (camera.recording)
                  OutlinedButton(
                    onPressed: () => camera.interrupt(),
                    child: const Text('Stop and retry recording'),
                  ),
              ],
            ),
          ),
        if ((a != null && a.unfinished) || state!.consentId != null) ...[
          const SectionTitle('Manage your enrolment'),
          Panel(
            padding: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (a != null && a.unfinished)
                  _ManageRow(
                    icon: Icons.delete_outline,
                    title: 'Discard this recording',
                    body: 'Removes the unfinished recording. You can record again at any time.',
                    action: OutlinedButton(
                      onPressed: busy || camera.recording ? null : cancel,
                      child: const Text('Discard unfinished enrolment'),
                    ),
                  ),
                if (a != null && a.unfinished && state!.consentId != null)
                  const Divider(height: 24),
                if (state!.consentId != null)
                  _ManageRow(
                    icon: Icons.privacy_tip_outlined,
                    title: 'Withdraw consent',
                    body:
                        'Stops face recognition for you and deletes your face data. '
                        'Your faculty can still mark your attendance manually.',
                    action: TextButton(
                      style: TextButton.styleFrom(
                        foregroundColor: Theme.of(context).colorScheme.error,
                      ),
                      onPressed: busy || camera.recording ? null : withdraw,
                      child: const Text('Withdraw face-enrolment consent'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _StateIcon extends StatelessWidget {
  const _StateIcon({required this.icon, required this.color});
  final IconData icon;
  final Color color;

  factory _StateIcon.forStatus(String status) => switch (status) {
    'review_required' => const _StateIcon(
      icon: Icons.manage_search,
      color: Color(0xff1f5fa8),
    ),
    'queued' || 'processing' => const _StateIcon(
      icon: Icons.hourglass_top,
      color: Color(0xff9a6a00),
    ),
    'awaiting_upload' => const _StateIcon(
      icon: Icons.cloud_upload_outlined,
      color: Color(0xff9a6a00),
    ),
    'expired' ||
    'rejected' ||
    'failed' => const _StateIcon(icon: Icons.replay, color: Color(0xffa22f2f)),
    _ => const _StateIcon(icon: Icons.info_outline, color: Color(0xff465650)),
  };

  @override
  Widget build(BuildContext context) => Container(
    width: 44,
    height: 44,
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Icon(icon, color: color),
  );
}

class _ManageRow extends StatelessWidget {
  const _ManageRow({
    required this.icon,
    required this.title,
    required this.body,
    required this.action,
  });
  final IconData icon;
  final String title, body;
  final Widget action;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(body, style: TextStyle(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(left: 36, top: 6),
          child: action,
        ),
      ],
    );
  }
}

class _StudentCameraPage extends StatefulWidget {
  const _StudentCameraPage({
    required this.camera,
    required this.order,
    required this.start,
  });
  final GuidedCamera camera;
  final List<String> order;
  final Future<void> Function() start;
  @override
  State<_StudentCameraPage> createState() => _StudentCameraPageState();
}

class _StudentCameraPageState extends State<_StudentCameraPage> {
  bool starting = false, attempted = false;
  GuidedCamera get camera => widget.camera;

  @override
  void initState() {
    super.initState();
    camera.addListener(_finished);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(camera.initialize());
    });
  }

  void _finished() {
    if (attempted &&
        camera.clip != null &&
        !camera.busy &&
        mounted &&
        ModalRoute.of(context)?.isCurrent == true) {
      attempted = false;
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    camera.removeListener(_finished);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Record your face'),
      leading: IconButton(
        tooltip: 'Cancel recording',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(Icons.close),
      ),
    ),
    backgroundColor: Colors.black,
    body: SafeArea(
      child: ListenableBuilder(
        listenable: camera,
        builder: (context, _) {
          final guidance = camera.guidance;
          final controller = camera.controller;
          final timed = guidance?.analysisUnavailable ?? false;
          final index = (camera.elapsed ~/ 5).clamp(0, widget.order.length - 1);
          final pose = timed
              ? widget.order[index]
              : guidance?.current ?? widget.order.first;
          final preview = controller == null
              ? Center(
                  child: camera.busy
                      ? const CircularProgressIndicator()
                      : const SizedBox.shrink(),
                )
              : LiveCameraPreview(
                  camera: controller,
                  showGuide: true,
                  guideAligned: guidance?.poseAligned == true,
                  faces: guidance?.faceBounds == null
                      ? const []
                      : [
                          (
                            bounds: guidance!.faceBounds!,
                            framed: guidance.faceFramed,
                          ),
                        ],
                );
          final controls = Material(
            color: Theme.of(context).colorScheme.surface,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      guidance?.allCaptured == true
                          ? 'All directions captured'
                          : pose == 'front'
                          ? 'Look straight at the camera'
                          : 'Look $pose',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  Text(
                    camera.error ??
                        (timed
                            ? 'Live guidance unavailable. Follow the timed directions.'
                            : guidance?.hint ??
                                  'Center your face in the guide.'),
                  ),
                  if (!kIsWeb && guidance?.faceBounds != null)
                    const Text(
                      'Green box: face is centered. Hold each direction until it is marked complete.',
                    ),
                  if (camera.recording)
                    Text('${camera.elapsed} / 25 seconds · audio off'),
                  Wrap(
                    spacing: 10,
                    children: [
                      for (final direction in widget.order)
                        Text(
                          '${guidance?.completed.contains(direction) == true ? '✓' : '○'} $direction',
                        ),
                    ],
                  ),
                  Wrap(
                    spacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('Cancel recording'),
                      ),
                      if (!camera.recording && !camera.busy)
                        FilledButton(
                          onPressed: starting
                              ? null
                              : () async {
                                  if (!camera.ready) {
                                    await camera.initialize();
                                    return;
                                  }
                                  setState(() {
                                    starting = true;
                                    attempted = true;
                                  });
                                  try {
                                    await widget.start();
                                  } catch (_) {
                                    if (context.mounted) {
                                      showMessage(
                                        context,
                                        'Could not start recording. Please retry.',
                                      );
                                    }
                                  } finally {
                                    if (mounted) {
                                      setState(() => starting = false);
                                    }
                                  }
                                },
                          child: Text(
                            camera.ready ? 'Start recording' : 'Open camera',
                          ),
                        ),
                    ],
                  ),
                  if (!camera.recording &&
                      camera.cameras.length > 1 &&
                      camera.clip == null)
                    DropdownButton<CameraDescription>(
                      value: camera.selectedCamera,
                      isExpanded: true,
                      onChanged: camera.busy
                          ? null
                          : (choice) {
                              if (choice != null) {
                                unawaited(camera.selectCamera(choice));
                              }
                            },
                      items: [
                        for (final device in camera.cameras)
                          DropdownMenuItem(
                            value: device,
                            child: Text(
                              '${device.lensDirection.name} · ${device.name}',
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          );
          return LayoutBuilder(
            builder: (context, constraints) {
              if (kIsWeb) {
                final isWide = constraints.maxWidth >= 760;
                return Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1000),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: isWide
                          ? Row(
                              children: [
                                Expanded(
                                  child: Center(
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxHeight: 620,
                                      ),
                                      child: preview,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                SizedBox(width: 330, child: controls),
                              ],
                            )
                          : Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxHeight: 620,
                                    ),
                                    child: preview,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: constraints.maxHeight * .48,
                                  ),
                                  child: controls,
                                ),
                              ],
                            ),
                    ),
                  ),
                );
              }
              if (constraints.maxWidth > constraints.maxHeight * 1.35) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: preview),
                    Expanded(flex: 2, child: Center(child: controls)),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: preview),
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .55,
                    ),
                    child: controls,
                  ),
                ],
              );
            },
          );
        },
      ),
    ),
  );
}

class EnrolmentSteps extends StatelessWidget {
  const EnrolmentSteps({super.key, required this.current});
  final int current;
  static const labels = [
    'Consent',
    'Record',
    'Upload',
    'Processing',
    'Faculty review',
    'Active',
  ];
  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            'Step ${current + 1} of 6 · ${labels[current]}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(100),
          child: LinearProgressIndicator(
            value: (current + 1) / labels.length,
            minHeight: 7,
            semanticsLabel: 'Face enrolment progress',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: List.generate(
            labels.length,
            (i) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              decoration: BoxDecoration(
                color: i == current
                    ? Theme.of(context).colorScheme.primary
                          .withValues(alpha: .10)
                    : Theme.of(context).colorScheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(100),
              ),
              child: Text(
                '${i < current ? '✓' : '${i + 1}.'} ${labels[i]}',
                style: TextStyle(
                  color: i == current
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: i == current ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
