import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:facetrack_capture/facetrack_capture.dart';
import 'package:facetrack_core/facetrack_core.dart';
import 'package:facetrack_models/facetrack_models.dart';

class StudentEnrolment extends ConsumerStatefulWidget {
  const StudentEnrolment({super.key});
  @override
  ConsumerState<StudentEnrolment> createState() => _StudentEnrolmentState();
}

class _StudentEnrolmentState extends ConsumerState<StudentEnrolment> {
  late final AppServices services;
  late final String institute, owner;
  final camera = GuidedCamera();
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
      final next = BiometricState.fromJson(values[0]);
      await PendingClips.expire(owner: owner);
      var saved = await PendingClips.read();
      if (saved != null &&
          (saved.institute != institute ||
              saved.owner != owner ||
              saved.attempt != next.attempt?.id ||
              next.attempt?.status != 'awaiting_upload')) {
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
    await camera.initialize();
    if (camera.controller != null) await camera.start(a.poses);
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
            await PendingClips.save(clip);
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
              'Record once, then ask your teacher to verify your identity.',
          action: OutlinedButton.icon(
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: ErrorView(error!, retry: load),
          ),
        EnrolmentSteps(current: step),
        if (state!.active)
          Panel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Face enrolment active',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'You are ready for classroom recognition. No further recording is needed. Your teacher will review attendance before publishing it.',
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
                    'Your current enrolment stays active until your teacher approves the replacement.',
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
                Text(
                  biometricStatus(a.status),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (a.reason != null) ...[
                  const SizedBox(height: 8),
                  Text(a.reason!),
                ],
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
                      'A teacher of an approved class can review this recording. Review must finish within 24 hours or you will need to record again.',
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
                    'Use good lighting, keep only yourself in frame and make sure your face is clear. Follow each prompt for the full 15 seconds. Audio stays off.',
                  ),
                  const SizedBox(height: 16),
                ],
                if (camera.controller != null && pending == null)
                  AspectRatio(
                    aspectRatio: camera.controller!.value.aspectRatio,
                    child: camera.controller!.buildPreview(),
                  ),
                if (camera.recording) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Look ${camera.poses[(camera.elapsed ~/ 3).clamp(0, 4)]}',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  Text('${camera.elapsed} / 15 seconds · audio off'),
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
        if (a != null && a.unfinished)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: OutlinedButton(
              onPressed: busy || camera.recording ? null : cancel,
              child: const Text('Discard unfinished enrolment'),
            ),
          ),
        if (state!.consentId != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextButton(
              onPressed: busy || camera.recording ? null : withdraw,
              child: const Text('Withdraw face-enrolment consent'),
            ),
          ),
      ],
    );
  }
}

class EnrolmentSteps extends StatelessWidget {
  const EnrolmentSteps({super.key, required this.current});
  final int current;
  static const labels = [
    'Consent',
    'Record',
    'Upload',
    'Processing',
    'Teacher review',
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
        LinearProgressIndicator(
          value: (current + 1) / labels.length,
          semanticsLabel: 'Face enrolment progress',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: List.generate(
            labels.length,
            (i) => Text(
              '${i < current ? '✓' : '${i + 1}.'} ${labels[i]}',
              style: TextStyle(
                fontWeight: i == current ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
